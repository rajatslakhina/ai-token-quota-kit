/// Pricing/limit tier. The key includes the tier, so an upgrade starts a fresh bucket under the new policy.
public enum Tier: String, Sendable, CaseIterable, Hashable, Codable {
    case free, pro, enterprise
}

/// The unit of enforcement: one user, one AI feature, one tier.
///
/// **Trust boundary:** the backend builds this. `userID` comes from the authenticated session,
/// `tier` from your entitlement service, and `feature` must be one of a fixed set
/// (`LedgerConfiguration.features`). Never take any of them from the app's request body: users
/// would pick their own limits, or multiply them by inventing feature names.
public struct QuotaKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public let userID: String
    public let feature: String
    public let tier: Tier

    public init(userID: String, feature: String, tier: Tier) {
        self.userID = userID
        self.feature = feature
        self.tier = tier
    }

    public var description: String { "\(userID)/\(feature)/\(tier.rawValue)" }
}

/// Idempotency key. The client mints one per user action and reuses it on every retry.
public struct RequestID: Hashable, Sendable, Comparable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }
    public static func < (lhs: RequestID, rhs: RequestID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What the backend knows *before* the call: input tokens from `count_tokens`, plus the request's
/// `max_tokens`. Reserving the worst case is what makes the pre-authorisation safe to settle later.
/// The backend computes it itself; an estimate sent by the app is a hint at most.
public struct Estimate: Sendable, Equatable, Codable {
    public let inputTokens: Int64
    public let maxOutputTokens: Int64

    public init(inputTokens: Int64, maxOutputTokens: Int64) {
        self.inputTokens = inputTokens
        self.maxOutputTokens = maxOutputTokens
    }

    public var total: Int64 { Sat.add(inputTokens, maxOutputTokens) }
    public var isValid: Bool { inputTokens >= 0 && maxOutputTokens >= 0 && total > 0 }
}

/// The response's `usage` block: uncached input plus output. Cache reads and writes are priced
/// separately by the provider and are deliberately out of scope (see `AnalyticsRow`).
public struct Usage: Sendable, Equatable, Codable {
    public let inputTokens: Int64
    public let outputTokens: Int64

    public init(inputTokens: Int64, outputTokens: Int64) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }

    public var total: Int64 { Sat.add(inputTokens, outputTokens) }
    public var isValid: Bool { inputTokens >= 0 && outputTokens >= 0 }

    /// What to settle when the provider call failed before billing anything (a 5xx, a 529, a timeout
    /// before the first token). Settling it refunds the whole reservation and spends the request ID.
    public static let zero = Usage(inputTokens: 0, outputTokens: 0)
}

/// Burst limit: `capacity` tokens, refilled continuously at `refillPerSecond`.
public struct BucketLimit: Sendable, Equatable, Codable {
    public let capacity: Int64
    public let refillPerSecond: Int64

    public init(capacity: Int64, refillPerSecond: Int64) {
        self.capacity = capacity
        self.refillPerSecond = refillPerSecond
    }
}

/// What a tier gets when the counter store is unreachable.
public enum OutagePolicy: Sendable, Equatable {
    /// Deny everything. Cheapest tier, where an outage must not become free inference.
    case failClosed
    /// Keep serving, but only up to `allowanceTokens` per key per outage.
    /// The allowance lives in this backend instance's memory: with N replicas the effective
    /// allowance is up to N times larger, so divide it by your replica count.
    case failOpenBounded(allowanceTokens: Int64)
}

public struct TierPolicy: Sendable, Equatable {
    public let burst: BucketLimit
    /// Sustained limit: tokens per key per UTC day.
    public let dailyBudget: Int64
    public let maxSingleRequest: Int64
    public let outage: OutagePolicy
    /// Open reservations one key may hold at once. Without it, one user can fill the global
    /// hold table with tiny reservations and lock every other tenant out.
    public let maxInFlight: Int

    public init(burst: BucketLimit, dailyBudget: Int64, maxSingleRequest: Int64, outage: OutagePolicy,
                maxInFlight: Int = 8) {
        self.burst = burst
        self.dailyBudget = dailyBudget
        self.maxSingleRequest = maxSingleRequest
        self.outage = outage
        self.maxInFlight = maxInFlight
    }

    /// A request larger than the bucket or the day could never be granted; rejecting it outright
    /// (instead of returning a `Retry-After` that can never come true) keeps clients out of a retry loop.
    public var effectiveMaxSingleRequest: Int64 { min(maxSingleRequest, burst.capacity, dailyBudget) }
}

/// Prices in micro-dollars per million tokens. Integer micro-dollars keep spend exact and comparable.
public struct PriceTable: Sendable, Equatable {
    public let inputMicroUSDPerMTok: Int64
    public let outputMicroUSDPerMTok: Int64

    public init(inputMicroUSDPerMTok: Int64, outputMicroUSDPerMTok: Int64) {
        self.inputMicroUSDPerMTok = inputMicroUSDPerMTok
        self.outputMicroUSDPerMTok = outputMicroUSDPerMTok
    }

    public func cost(inputTokens: Int64, outputTokens: Int64) -> Int64 {
        let input = Sat.mul(max(0, inputTokens), inputMicroUSDPerMTok)
        let output = Sat.mul(max(0, outputTokens), outputMicroUSDPerMTok)
        return Sat.div(Sat.add(input, output), 1_000_000)
    }

    public func cost(_ estimate: Estimate) -> Int64 {
        cost(inputTokens: estimate.inputTokens, outputTokens: estimate.maxOutputTokens)
    }

    public func cost(_ usage: Usage) -> Int64 {
        cost(inputTokens: usage.inputTokens, outputTokens: usage.outputTokens)
    }
}

public struct Grant: Sendable, Equatable, Codable {
    public let requestID: RequestID
    public let reservedTokens: Int64
    public let burstRemaining: Int64
    public let dailyRemaining: Int64
    /// Granted from the outage allowance while the counter store was down.
    public let degraded: Bool

    public init(requestID: RequestID, reservedTokens: Int64, burstRemaining: Int64,
                dailyRemaining: Int64, degraded: Bool) {
        self.requestID = requestID
        self.reservedTokens = reservedTokens
        self.burstRemaining = burstRemaining
        self.dailyRemaining = dailyRemaining
        self.degraded = degraded
    }
}

public enum DenialReason: String, Sendable, CaseIterable, Codable {
    case invalidEstimate, unknownTier, unknownFeature, requestTooLarge
    /// Bigger than the whole outage allowance: it can't be served until the store is back. Permanent
    /// for this request, so the client doesn't retry it every few seconds for the length of the outage.
    case exceedsOutageAllowance
    /// The request ID already finished. Serve the cached response; mint a new ID for a new action.
    case alreadySettled
    /// A model call for this request ID already started (and may still be running).
    case alreadyClaimed
    /// The request ID was used before by a different user, key or estimate.
    case requestIDReused
    case tooManyInFlight, orgSpendBreakerOpen, orgBudgetWouldExceed
    case dailyBudgetExhausted, burstExhausted
    case storeUnavailable, outageAllowanceExhausted

    /// Transient denials clear with time; permanent ones never will for the same request,
    /// so a client must not put the whole feature into cooldown for them.
    public var isTransient: Bool {
        switch self {
        case .invalidEstimate, .unknownTier, .unknownFeature, .requestTooLarge, .exceedsOutageAllowance,
             .alreadySettled, .alreadyClaimed, .requestIDReused:
            return false
        default:
            return true
        }
    }

    /// The HTTP status a backend should answer with. Send the reason in the body too, so the app
    /// can tell a limit (429) from an outage (503) from a request that can never succeed (4xx).
    public var httpStatus: Int {
        switch self {
        case .invalidEstimate, .unknownTier, .unknownFeature: return 422
        case .requestTooLarge, .exceedsOutageAllowance: return 413
        case .alreadySettled, .alreadyClaimed, .requestIDReused: return 409
        case .storeUnavailable: return 503
        case .tooManyInFlight, .orgSpendBreakerOpen, .orgBudgetWouldExceed,
             .dailyBudgetExhausted, .burstExhausted, .outageAllowanceExhausted: return 429
        }
    }
}

public struct Denial: Sendable, Equatable, Codable {
    public let reason: DenialReason
    /// When retrying can succeed (the HTTP `Retry-After`), if the ledger can know it.
    public let retryAfterMs: Millis?

    public init(reason: DenialReason, retryAfterMs: Millis?) {
        self.reason = reason
        self.retryAfterMs = retryAfterMs
    }
}

public enum Decision: Sendable, Equatable, Codable {
    case granted(Grant)
    case denied(Denial)

    public var grant: Grant? {
        if case .granted(let grant) = self { return grant }
        return nil
    }

    public var denial: Denial? {
        if case .denied(let denial) = self { return denial }
        return nil
    }
}

public enum ClaimResult: Sendable, Equatable, Codable {
    /// Call the model. At most one claim per request ID ever returns this.
    case claimed(Grant)
    /// A call for this ID already started: serve that call's response, never call the model again.
    case alreadyClaimed
    /// The call already finished and was charged.
    case alreadySettled
    /// No open hold: never authorised here, expired before anyone claimed it, or forgotten.
    /// Authorise again first.
    case noHold
    /// The claim doesn't match what was authorised under this ID: a different user, API key or
    /// request content. Nothing was claimed.
    case mismatch
}

/// Where a settlement's accounting went.
public enum Persistence: String, Sendable, Equatable, Codable {
    /// Written to the counters and attribution now.
    case applied
    /// The store is down: buffered in the outage journal, replayed in order on recovery.
    case journaled
    /// The store is down and the journal is full: lost, and counted in `LedgerStats`.
    case dropped
}

public enum SettleOutcome: Sendable, Equatable {
    /// Normal path: the hold is replaced by the actual usage (`adjustment` = actual − reserved).
    case settled(charged: Int64, adjustment: Int64, persistence: Persistence)
    /// The hold had already expired. If it expired unclaimed it was refunded, and the usage is
    /// charged in full; if it expired mid-call its reservation was kept, and this trues it up.
    case lateSettled(charged: Int64, persistence: Persistence)
    /// No record of this request (never authorised here, or forgotten after the retention window).
    /// Charged in full: the ledger fails toward counting usage, never toward losing it.
    case unknownSettled(charged: Int64, persistence: Persistence)
    case duplicate
    case invalidUsage
}
