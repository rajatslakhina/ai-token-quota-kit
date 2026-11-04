import Foundation

/// What the device can do when the cloud says no.
public struct OnDeviceCapability: Sendable, Equatable {
    /// Whether this device has an on-device model (e.g. Foundation Models on Apple Intelligence hardware).
    public var available: Bool
    /// The largest job the on-device model handles acceptably; bigger jobs wait for the cloud.
    public var maxTokens: Int64

    public init(available: Bool, maxTokens: Int64) {
        self.available = available
        self.maxTokens = maxTokens
    }
}

public struct ClientPolicy: Sendable, Equatable {
    /// Attempts per action, clamped to `1...10`.
    public var maxAttempts: Int
    /// Backoff between transport-failure retries: full jitter over `base × 2^(attempt−1)`, capped.
    public var retryBaseDelayMs: Millis
    public var retryMaxDelayMs: Millis
    /// Cooldown when a transient denial carries no `Retry-After`, and after every attempt failed.
    public var defaultCooldownMs: Millis
    /// Upper bound on any server-provided `Retry-After`, so one bad header can't disable cloud AI for days.
    public var maxCooldownMs: Millis
    /// How long a remaining-budget snapshot is trusted for the local pre-check.
    public var snapshotFreshnessMs: Millis
    public var onDevice: OnDeviceCapability

    public init(maxAttempts: Int = 3,
                retryBaseDelayMs: Millis = 200,
                retryMaxDelayMs: Millis = 2 * Time.second,
                defaultCooldownMs: Millis = 30 * Time.second,
                maxCooldownMs: Millis = 15 * Time.minute,
                snapshotFreshnessMs: Millis = 10 * Time.second,
                onDevice: OnDeviceCapability = OnDeviceCapability(available: true, maxTokens: 4_000)) {
        self.maxAttempts = maxAttempts
        self.retryBaseDelayMs = retryBaseDelayMs
        self.retryMaxDelayMs = retryMaxDelayMs
        self.defaultCooldownMs = defaultCooldownMs
        self.maxCooldownMs = maxCooldownMs
        self.snapshotFreshnessMs = snapshotFreshnessMs
        self.onDevice = onDevice
    }
}

public enum FallbackReason: Sendable, Equatable {
    case limited(DenialReason)
    /// A previous `Retry-After` is still running: decided locally, no network call made.
    case cooldown
    /// The last known remaining budget can't cover this job: decided locally, no network call made.
    case budgetPrecheck
    case transportFailed

    public var label: String {
        switch self {
        case .limited(let reason): return reason.rawValue
        case .cooldown: return "cooldown"
        case .budgetPrecheck: return "budget pre-check"
        case .transportFailed: return "transport failed"
        }
    }
}

public enum Route: Sendable, Equatable {
    case cloud(Grant)
    case onDevice(FallbackReason)
    case tryLater(untilMs: Millis, FallbackReason)
    /// The cloud refused *this request* for good (too large, unknown feature, ID already spent):
    /// retrying it won't help, so don't. A new user action gets a new route.
    case unavailable(DenialReason)
    /// The calling task was cancelled; nothing more was attempted.
    case cancelled

    public var isCloud: Bool {
        if case .cloud = self { return true }
        return false
    }
}

/// The app-side half: decides, per AI action, whether to call the cloud, run on device, or wait.
///
/// * It never calls the network while a `Retry-After` is running — checked before the first
///   attempt *and after every suspension*, because other routes run while this one waits — or when
///   its last budget snapshot says the job can't fit. A looping agent stops costing round trips
///   the moment it is limited.
/// * It mints **one** request ID per action and reuses it across retries, so a lost response can't
///   turn into a second reservation at the ledger.
/// * Transport failures are retried with capped, fully-jittered exponential backoff; when every
///   attempt fails the feature cools down, so a dead backend isn't hammered by every loop iteration.
public actor QuotaClient {
    public struct BudgetSnapshot: Sendable, Equatable {
        public let dailyRemaining: Int64
        public let burstRemaining: Int64
        public let observedAtMs: Millis
    }

    private let transport: any QuotaTransport
    private let clock: any QuotaClock
    private let policy: ClientPolicy
    private let makeRequestID: @Sendable () -> RequestID
    private let sleep: @Sendable (Millis) async -> Void
    private let jitter: @Sendable (Millis) -> Millis

    // Both dictionaries are keyed by the app's own features/keys, a small fixed set: bounded.
    private var cooldownUntil: [String: Millis] = [:]
    private var budget: [QuotaKey: BudgetSnapshot] = [:]

    public private(set) var networkAttempts = 0
    public private(set) var localDecisions = 0

    /// - Parameters:
    ///   - sleep: waits the given milliseconds (injected so tests and scenarios don't really sleep).
    ///   - jitter: returns a value in `0...upperBound` (injected for deterministic tests).
    public init(transport: any QuotaTransport,
                clock: any QuotaClock,
                policy: ClientPolicy = ClientPolicy(),
                makeRequestID: @escaping @Sendable () -> RequestID = { RequestID(UUID().uuidString) },
                sleep: @escaping @Sendable (Millis) async -> Void = QuotaClient.taskSleep,
                jitter: @escaping @Sendable (Millis) -> Millis = QuotaClient.fullJitter) {
        self.transport = transport
        self.clock = clock
        self.policy = policy
        self.makeRequestID = makeRequestID
        self.sleep = sleep
        self.jitter = jitter
    }

    public static let taskSleep: @Sendable (Millis) async -> Void = { milliseconds in
        let bounded = Sat.clamp(milliseconds, 0, Time.minute)   // ≤ 6e10 ns: fits UInt64 trivially
        try? await Task.sleep(nanoseconds: UInt64(bounded) * 1_000_000)
    }

    public static let fullJitter: @Sendable (Millis) -> Millis = { upperBound in
        upperBound > 0 ? Millis.random(in: 0...upperBound) : 0
    }

    /// - Parameters:
    ///   - key: this user, feature and tier, as the app knows them. They drive the *local* cooldown and
    ///     pre-check; the backend derives its own (see the trust boundary on `AuthorizeRequest`).
    ///   - apiKey: only meaningful for an in-process transport (tests, the demo). An HTTPS transport
    ///     ignores it, because the backend owns its API key.
    ///   - estimate: the app's estimate, used for the local pre-check and the on-device fallback.
    ///   - payload: opaque to the library — the prompt the transport sends, so the backend can count
    ///     and hash the exact request it will run.
    public func route(key: QuotaKey, apiKey: String = "", estimate: Estimate, payload: Data? = nil) async -> Route {
        if Task.isCancelled { return .cancelled }
        let now = clock.nowMillis()
        if let local = localDecision(for: key, estimate: estimate, now: now) { return local }

        // One ID for every attempt: retries are idempotent at the ledger.
        let request = AuthorizeRequest(requestID: makeRequestID(), key: key, apiKey: apiKey, estimate: estimate,
                                       payload: payload)
        let attempts = min(max(1, policy.maxAttempts), 10)
        for attempt in 0..<attempts {
            if attempt > 0 {
                await sleep(backoffDelay(forRetry: attempt))
                if Task.isCancelled { return .cancelled }
                // Other routes ran while this one was suspended: one of them may have hit a limit.
                if let until = cooldownUntil[key.feature], until > clock.nowMillis() {
                    localDecisions = localDecisions == .max ? .max : localDecisions + 1
                    return fallback(.cooldown, estimate: estimate, until: until)
                }
            }
            networkAttempts = networkAttempts == .max ? .max : networkAttempts + 1
            let decision: Decision
            do {
                decision = try await transport.authorize(request)
            } catch is CancellationError {
                return .cancelled
            } catch {
                // A cancelled URLSession task throws URLError(.cancelled), not CancellationError.
                if Task.isCancelled { return .cancelled }
                continue
            }
            // Re-read the clock and the actor's state: other routes ran while this one was suspended.
            let after = clock.nowMillis()
            switch decision {
            case .granted(let grant):
                record(grant, for: key, at: after)
                return .cloud(grant)
            case .denied(let denial):
                guard denial.reason.isTransient else { return .unavailable(denial.reason) }
                let wait = Sat.clamp(denial.retryAfterMs ?? policy.defaultCooldownMs, 0, max(0, policy.maxCooldownMs))
                return fallback(.limited(denial.reason), estimate: estimate,
                                until: extendCooldown(for: key.feature, to: Sat.add(after, wait)))
            }
        }
        // Every attempt failed: cool the feature down so a looping caller stops hammering a dead backend.
        let failedUntil = extendCooldown(for: key.feature, to: Sat.add(clock.nowMillis(), policy.defaultCooldownMs))
        return fallback(.transportFailed, estimate: estimate, until: failedUntil)
    }

    public func cooldown(for feature: String) -> Millis? { cooldownUntil[feature] }
    public func snapshot(for key: QuotaKey) -> BudgetSnapshot? { budget[key] }

    private func localDecision(for key: QuotaKey, estimate: Estimate, now: Millis) -> Route? {
        if let until = cooldownUntil[key.feature], until > now {
            localDecisions = localDecisions == .max ? .max : localDecisions + 1
            return fallback(.cooldown, estimate: estimate, until: until)
        }
        if let snapshot = budget[key],
           Sat.sub(now, snapshot.observedAtMs) <= policy.snapshotFreshnessMs,
           snapshot.dailyRemaining < estimate.total {
            localDecisions = localDecisions == .max ? .max : localDecisions + 1
            // Honest deadline: once the snapshot goes stale the client asks the backend again.
            let staleAt = Sat.add(Sat.add(snapshot.observedAtMs, policy.snapshotFreshnessMs), 1)
            return fallback(.budgetPrecheck, estimate: estimate, until: staleAt)
        }
        return nil
    }

    /// Keeps the later deadline: a concurrent route may already have set a longer one.
    private func extendCooldown(for feature: String, to until: Millis) -> Millis {
        let deadline = max(cooldownUntil[feature] ?? Millis.min, until)
        cooldownUntil[feature] = deadline
        return deadline
    }

    private func backoffDelay(forRetry attempt: Int) -> Millis {
        let exponent = Int64(min(max(0, attempt - 1), 30))
        let ceiling = Sat.mul(max(0, policy.retryBaseDelayMs), Int64(1) << exponent)
        return Sat.clamp(jitter(min(ceiling, max(0, policy.retryMaxDelayMs))), 0, max(0, policy.retryMaxDelayMs))
    }

    private func record(_ grant: Grant, for key: QuotaKey, at instant: Millis) {
        // Outage grants report the outage allowance, not the daily budget: don't pre-check against them.
        guard !grant.degraded else { return }
        if let existing = budget[key], existing.observedAtMs > instant { return }
        budget[key] = BudgetSnapshot(dailyRemaining: grant.dailyRemaining,
                                     burstRemaining: grant.burstRemaining, observedAtMs: instant)
    }

    private func fallback(_ reason: FallbackReason, estimate: Estimate, until: Millis) -> Route {
        if policy.onDevice.available, estimate.total <= policy.onDevice.maxTokens {
            return .onDevice(reason)
        }
        return .tryLater(untilMs: until, reason)
    }
}
