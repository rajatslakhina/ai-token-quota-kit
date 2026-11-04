import Foundation

/// One authorisation request, as the **backend** sees it.
///
/// Trust boundary: every field except `requestID` is derived by the backend, never copied from the
/// app's request body. `key.userID` comes from the authenticated session, `key.tier` from your
/// entitlement service, `key.feature` from a fixed allowlist (`LedgerConfiguration.features`),
/// `apiKey` from the backend's own configuration (the provider's key *ID*, never the secret), and
/// `estimate` from the backend's own `count_tokens` call plus the `max_tokens` it will send.
/// `promptDigest` is the backend's hash of that exact request, which `claim` checks again. If a
/// backend forwarded the app's values, users could choose their own tier, limits and reservation size.
///
/// On the device, `QuotaClient` builds the same shape so its local cooldown and pre-check can reason
/// about it; an HTTPS `QuotaTransport` sends only `requestID`, `key.feature` and `payload` (the prompt).
/// The ledger never reads `payload`.
public struct AuthorizeRequest: Sendable, Equatable, Codable {
    public let requestID: RequestID
    public let key: QuotaKey
    public let apiKey: String
    public let estimate: Estimate
    public let promptDigest: String?
    /// Opaque to the ledger: the prompt the app's transport sends to the backend.
    public let payload: Data?

    public init(requestID: RequestID, key: QuotaKey, apiKey: String, estimate: Estimate,
                promptDigest: String? = nil, payload: Data? = nil) {
        self.requestID = requestID
        self.key = key
        self.apiKey = apiKey
        self.estimate = estimate
        self.promptDigest = promptDigest
        self.payload = payload
    }
}

/// How the client reaches the metering backend. A real app implements this over HTTPS: decode the
/// JSON body into a `Decision` (both are `Codable`), so the app keeps the denial *reason* and can tell
/// a limit (429, transient) from a request that can never succeed (4xx, permanent).
/// Tests and the demo use `QuotaGateway` in-process.
public protocol QuotaTransport: Sendable {
    func authorize(_ request: AuthorizeRequest) async throws -> Decision
}

public enum TransportError: Error, Equatable, Sendable {
    /// The request never reached the backend.
    case unreachable
    /// The backend applied the request, but the response was lost on the way back.
    case responseLost
}

/// The backend-for-frontend's metering service: a `QuotaLedger` behind an actor.
///
/// No method contains an `await`, so no call can interleave with another — each is as atomic as
/// the Redis Lua script or Postgres transaction it stands in for. That is a deliberate constraint:
/// the moment a suspension point appears in here, check-all-then-commit stops being true.
public actor QuotaGateway: QuotaTransport {
    private var ledger: QuotaLedger
    private let clock: any QuotaClock

    public init(configuration: LedgerConfiguration, clock: any QuotaClock) {
        self.ledger = QuotaLedger(configuration: configuration)
        self.clock = clock
    }

    public func authorize(_ request: AuthorizeRequest) -> Decision {
        ledger.authorize(request.requestID, key: request.key, apiKey: request.apiKey,
                         estimate: request.estimate, promptDigest: request.promptDigest, now: clock.nowMillis())
    }

    /// The completion handler calls this right before calling the model; see `QuotaLedger.claim`.
    public func claim(_ id: RequestID, key: QuotaKey, apiKey: String, promptDigest: String? = nil) -> ClaimResult {
        ledger.claim(id, key: key, apiKey: apiKey, promptDigest: promptDigest, now: clock.nowMillis())
    }

    public func settle(_ id: RequestID, key: QuotaKey, apiKey: String, usage: Usage) -> SettleOutcome {
        ledger.settle(id, key: key, apiKey: apiKey, usage: usage, now: clock.nowMillis())
    }

    @discardableResult
    public func setStoreAvailable(_ available: Bool) -> Int {
        ledger.setStoreAvailable(available, now: clock.nowMillis())
    }

    public func sweep() { ledger.sweep(now: clock.nowMillis()) }

    public func resetBreaker(overrideMicroUSD: Int64 = 0) {
        ledger.resetBreaker(overrideMicroUSD: overrideMicroUSD, now: clock.nowMillis())
    }

    public func reconcile(report: [AnalyticsRow], dataRefreshedAt: Millis? = nil,
                          policy: ReconciliationPolicy = ReconciliationPolicy()) -> [DriftFinding] {
        Reconciler.reconcile(ledger: ledger.attribution, report: report, dataRefreshedAt: dataRefreshedAt,
                             now: clock.nowMillis(), policy: policy)
    }

    /// A consistent copy of the whole ledger, for dashboards and tests.
    public func snapshot() -> QuotaLedger { ledger }
}

/// Wraps a transport and injects failures from a script, one per call. Used by the tests and the
/// demo's "lost response" scenario to prove retries are idempotent end to end.
public actor FaultInjectingTransport: QuotaTransport {
    public enum Fault: Sendable, Equatable {
        case none
        case unreachable
        case responseLost
    }

    private let upstream: any QuotaTransport
    private var plan: [Fault]
    public private(set) var attempts = 0
    /// Calls that actually reached the upstream.
    public private(set) var delivered = 0

    public init(upstream: any QuotaTransport, plan: [Fault]) {
        self.upstream = upstream
        self.plan = plan
    }

    public func authorize(_ request: AuthorizeRequest) async throws -> Decision {
        attempts = attempts == .max ? .max : attempts + 1
        let fault = plan.isEmpty ? Fault.none : plan.removeFirst()
        switch fault {
        case .unreachable:
            throw TransportError.unreachable
        case .none:
            delivered = delivered == .max ? .max : delivered + 1
            return try await upstream.authorize(request)
        case .responseLost:
            delivered = delivered == .max ? .max : delivered + 1
            _ = try await upstream.authorize(request)
            throw TransportError.responseLost
        }
    }
}
