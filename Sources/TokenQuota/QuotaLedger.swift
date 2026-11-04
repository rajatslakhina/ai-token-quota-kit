/// Which UTC day settled usage is attributed to, for reconciliation.
///
/// The provider's usage report buckets by UTC time, but its docs don't say whether a request
/// counts at its start or its end. That only matters for calls that cross midnight, so it is a
/// setting: pick the one that matches what you observe.
public enum AttributionDay: Sendable, Equatable {
    /// The day the model call started: its claim, or its reservation if it was never claimed.
    case callStart
    /// The day the settlement arrived.
    case settlement
}

/// Configuration for one ledger (one backend-for-frontend deployment).
public struct LedgerConfiguration: Sendable, Equatable {
    public var policies: [Tier: TierPolicy]
    /// The features this backend meters. `nil` accepts any name, which is only safe if the backend
    /// never puts a feature name it didn't choose into a `QuotaKey`.
    public var features: Set<String>?
    public var price: PriceTable
    public var orgSpendLimitMicroUSD: Int64
    public var orgSpendWindowMs: Millis
    /// Spend over the trailing `orgVelocityWindowMs` that trips the org breaker below the cap. `nil` = off.
    public var orgVelocityTripMicroUSD: Int64?
    public var orgVelocityWindowMs: Millis
    /// How long a tripped breaker stays open unless an operator resets it.
    public var orgBreakerCooldownMs: Millis
    /// An *unclaimed* hold older than this is refunded: the client never followed through.
    public var holdTTLMs: Millis
    /// A *claimed* hold (a model call is running) lives this long after its claim: the longest
    /// call you allow, streaming included. If it still hasn't settled by then, its reservation is
    /// kept as a provisional charge and its request ID stays spent.
    public var claimedHoldTTLMs: Millis
    /// Global cap on open holds. Each tier also has a per-key cap (`TierPolicy.maxInFlight`).
    public var maxOutstandingHolds: Int
    /// Finished request IDs are remembered at least this long, which should cover the client's
    /// retries and the settlement queue's redelivery.
    public var idempotencyRetentionMs: Millis
    /// Hard memory cap on remembered IDs. Size it at peak finished requests per second × retention;
    /// an ID forgotten early because of this cap is counted in `LedgerStats.idempotencyEvictions`.
    public var idempotencyCapacity: Int
    /// How long a call that outlived its claimed TTL stays remembered, so a late settlement trues up
    /// its provisional charge instead of being charged on top of it.
    public var provisionalRetentionMs: Millis
    public var provisionalCapacity: Int
    /// How many settlements can be buffered while the counter store is down.
    public var journalCapacity: Int
    /// Days of per-API-key attribution kept for reconciliation.
    public var attributionRetentionDays: Int64
    public var attributeUsageTo: AttributionDay

    public init(policies: [Tier: TierPolicy],
                features: Set<String>? = nil,
                price: PriceTable,
                orgSpendLimitMicroUSD: Int64,
                orgSpendWindowMs: Millis = Time.hour,
                orgVelocityTripMicroUSD: Int64? = nil,
                orgVelocityWindowMs: Millis = 5 * Time.minute,
                orgBreakerCooldownMs: Millis = 15 * Time.minute,
                holdTTLMs: Millis = 2 * Time.minute,
                claimedHoldTTLMs: Millis = 15 * Time.minute,
                maxOutstandingHolds: Int = 10_000,
                idempotencyRetentionMs: Millis = Time.hour,
                idempotencyCapacity: Int = 100_000,
                provisionalRetentionMs: Millis = Time.day,
                provisionalCapacity: Int = 10_000,
                journalCapacity: Int = 10_000,
                attributionRetentionDays: Int64 = 45,
                attributeUsageTo: AttributionDay = .callStart) {
        self.policies = policies
        self.features = features
        self.price = price
        self.orgSpendLimitMicroUSD = orgSpendLimitMicroUSD
        self.orgSpendWindowMs = orgSpendWindowMs
        self.orgVelocityTripMicroUSD = orgVelocityTripMicroUSD
        self.orgVelocityWindowMs = orgVelocityWindowMs
        self.orgBreakerCooldownMs = orgBreakerCooldownMs
        self.holdTTLMs = holdTTLMs
        self.claimedHoldTTLMs = claimedHoldTTLMs
        self.maxOutstandingHolds = maxOutstandingHolds
        self.idempotencyRetentionMs = idempotencyRetentionMs
        self.idempotencyCapacity = idempotencyCapacity
        self.provisionalRetentionMs = provisionalRetentionMs
        self.provisionalCapacity = provisionalCapacity
        self.journalCapacity = journalCapacity
        self.attributionRetentionDays = attributionRetentionDays
        self.attributeUsageTo = attributeUsageTo
    }
}

/// Per-API-key, per-UTC-day settled tokens: the ledger side of reconciliation.
///
/// `apiKey` must be the provider's key **ID** (the Console's `api_key_id`, e.g. `apikey_…`) so it
/// joins the usage report's `api_key_id` group. Never the secret key itself: this value is logged,
/// shown in findings and kept for weeks.
public struct AttributionKey: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let apiKey: String
    public let dayIndex: Int64

    public init(apiKey: String, dayIndex: Int64) {
        self.apiKey = apiKey
        self.dayIndex = dayIndex
    }

    public static func < (lhs: AttributionKey, rhs: AttributionKey) -> Bool {
        (lhs.dayIndex, lhs.apiKey) < (rhs.dayIndex, rhs.apiKey)
    }

    public var description: String { "\(apiKey)@day\(dayIndex)" }
}

public struct LedgerStats: Sendable, Equatable {
    public var granted: Int64 = 0
    public var degradedGrants: Int64 = 0
    public var denied: [DenialReason: Int64] = [:]
    public var replays: Int64 = 0
    public var requestIDReuses: Int64 = 0
    public var claims: Int64 = 0
    public var duplicateClaims: Int64 = 0
    public var claimMismatches: Int64 = 0
    public var settled: Int64 = 0
    public var duplicateSettles: Int64 = 0
    public var lateSettles: Int64 = 0
    public var unknownSettles: Int64 = 0
    public var expiredHolds: Int64 = 0
    /// Claimed holds that expired before settling: their reservations were kept as provisional charges.
    public var expiredMidCall: Int64 = 0
    public var journalReplayed: Int64 = 0
    public var refundsReplayed: Int64 = 0
    public var journalDroppedEntries: Int64 = 0
    /// Usage tokens lost with dropped journal entries; reconciliation shows them as `ledgerUnder`.
    public var journalDroppedTokens: Int64 = 0
    /// Counter-only charges lost with dropped entries (the provisional charge of an outage grant
    /// that outlived its call). Not usage, so invisible to reconciliation: watch this one directly.
    public var journalDroppedChargeTokens: Int64 = 0
    /// Request IDs forgotten by the capacity cap before their retention ended.
    public var idempotencyEvictions: Int64 = 0
    /// Mid-call expiries forgotten by the capacity cap before their retention ended.
    public var provisionalEvictions: Int64 = 0

    public var totalDenied: Int64 { denied.values.reduce(0) { Sat.add($0, $1) } }
}

/// The metering core: **reserve → claim → settle** accounting over a burst bucket, a daily
/// budget and an org spend breaker, with idempotent requests and an outage journal.
///
/// * `authorize` reserves the worst case (`count_tokens` input + `max_tokens` output).
/// * `claim` is called by the completion handler right before it calls the model. It succeeds at
///   most once per request ID, and only for the same user, API key and request content, so a
///   retried, raced or replayed completion can never buy a second model call.
/// * `settle` replaces the reservation with the response's actual `usage` — `Usage.zero` when the
///   provider call failed before billing anything.
///
/// It is a value type with no I/O and no `await`: every method is a pure state transition, so it is
/// exhaustively testable with a manual clock, and wrapping it in an actor (`QuotaGateway`) gives the
/// same atomicity a Redis Lua script gives the real deployment — each call is one indivisible step.
///
/// Invariants (each has a test, and the scripted mutations in `scripts/mutation-check.sh` break them):
/// 1. **Check-all-then-commit.** A denied request changes no counter and holds no spend.
/// 2. **At most one reservation per request ID** while its hold is open, however often it is retried.
/// 3. **At most one model call per request ID** inside the idempotency window: `claim` is
///    single-use, a settled ID is spent, and a hold that expires mid-call keeps the ID spent.
/// 4. **At most one charge per request ID** inside the idempotency window.
/// 5. **Usage is never silently lost.** Late, unknown and outage-time settlements are charged or
///    journaled; the only loss path (journal overflow) is counted and shows up in reconciliation.
public struct QuotaLedger: Sendable {
    public let configuration: LedgerConfiguration
    public private(set) var storeAvailable = true
    public private(set) var breaker: OrgSpendBreaker
    public private(set) var attribution: [AttributionKey: Int64] = [:]
    private var counters = LedgerStats()

    private var buckets: [QuotaKey: TokenBucket] = [:]
    private var daily: [QuotaKey: DailyUsage] = [:]
    private var holds: [RequestID: Hold] = [:]
    /// Open holds per key: bounded by `maxInFlight`, and a key with none has no entry.
    private var holdIDs: [QuotaKey: Set<RequestID>] = [:]
    private var lastGlobalExpiryMs: Millis?
    private var records: BoundedMap<RequestID, Record>
    private var provisional: BoundedMap<RequestID, Provisional>
    private var outageEpoch: Int64 = 0
    private var outageUsed: [QuotaKey: Int64] = [:]
    private var journal: [JournalEntry] = []
    /// Refunds of holds that expired while the store was down. Only holds created while the store
    /// was up debit it, so this never exceeds the holds open when the outage began.
    private var pendingRefunds: [JournalEntry] = []

    struct Hold: Sendable {
        let key: QuotaKey
        let apiKey: String
        let estimate: Estimate
        let promptDigest: String?
        let grant: Grant
        let createdMs: Millis
        /// The daily window the reservation was charged to. Not always `dayIndex(createdMs)`: after a
        /// clock step back across midnight, the debited window is the later one.
        let windowDay: Int64
        /// False for outage grants, which never touched the (unreachable) counters.
        let debitedCounters: Bool
        let estimatedCost: Int64
        /// The outage a degraded hold's allowance belongs to (0 for normal holds).
        let outageEpoch: Int64
        /// Set by `claim`: a model call for this request has started.
        var claimedAtMs: Millis?

        var startedAtMs: Millis { claimedAtMs ?? createdMs }

        func expiresAt(_ configuration: LedgerConfiguration) -> Millis {
            if let claimedAtMs { return Sat.add(claimedAtMs, configuration.claimedHoldTTLMs) }
            return Sat.add(createdMs, configuration.holdTTLMs)
        }

        func matches(key other: QuotaKey, apiKey otherAPIKey: String, estimate otherEstimate: Estimate,
                     promptDigest otherDigest: String?) -> Bool {
            key == other && apiKey == otherAPIKey && estimate == otherEstimate && promptDigest == otherDigest
        }

        func matchesClaim(key other: QuotaKey, apiKey otherAPIKey: String, promptDigest otherDigest: String?) -> Bool {
            key == other && apiKey == otherAPIKey && promptDigest == otherDigest
        }
    }

    struct Record: Sendable {
        enum Terminal: Sendable, Equatable {
            case settled
            /// Expired before anyone claimed it; refunded. The ID may be authorised afresh.
            case expiredUnclaimed
        }
        let grant: Grant?
        let key: QuotaKey
        let apiKey: String
        /// `nil` when the ledger never saw the authorisation (an unknown settlement).
        let estimate: Estimate?
        let promptDigest: String?
        let startedAtMs: Millis
        var terminal: Terminal
        var finishedAtMs: Millis

        init(_ hold: Hold, terminal: Terminal, finishedAtMs: Millis) {
            grant = hold.grant
            key = hold.key
            apiKey = hold.apiKey
            estimate = hold.estimate
            promptDigest = hold.promptDigest
            startedAtMs = hold.startedAtMs
            self.terminal = terminal
            self.finishedAtMs = finishedAtMs
        }

        init(unknown key: QuotaKey, apiKey: String, at instant: Millis) {
            grant = nil
            self.key = key
            self.apiKey = apiKey
            estimate = nil
            promptDigest = nil
            startedAtMs = instant
            terminal = .settled
            finishedAtMs = instant
        }

        func matches(key other: QuotaKey, apiKey otherAPIKey: String, estimate otherEstimate: Estimate,
                     promptDigest otherDigest: String?) -> Bool {
            guard key == other, apiKey == otherAPIKey else { return false }
            guard let estimate else { return true }   // unknown settlement: nothing more to compare
            return estimate == otherEstimate && promptDigest == otherDigest
        }
    }

    /// A claimed hold that expired before settling: its reservation stays as a provisional charge.
    struct Provisional: Sendable {
        let hold: Hold
        /// What is currently charged for it (0 if writing an outage grant's charge was dropped).
        let provisionalTokens: Int64
        let expiredAtMs: Millis
    }

    /// A signed counter adjustment plus attributed usage, applied now or replayed after an outage.
    struct JournalEntry: Sendable {
        let key: QuotaKey
        let apiKey: String
        /// The daily window the adjustment belongs to (the hold's day, not the settle's).
        let windowDay: Int64
        let counterAdjust: Int64
        let attributionDay: Int64
        let attributedTokens: Int64
    }

    public init(configuration: LedgerConfiguration) {
        self.configuration = configuration
        self.breaker = OrgSpendBreaker(limitMicroUSD: configuration.orgSpendLimitMicroUSD,
                                       windowMs: configuration.orgSpendWindowMs,
                                       velocityTripMicroUSD: configuration.orgVelocityTripMicroUSD,
                                       velocityWindowMs: configuration.orgVelocityWindowMs,
                                       cooldownMs: configuration.orgBreakerCooldownMs)
        self.records = BoundedMap(capacity: configuration.idempotencyCapacity)
        self.provisional = BoundedMap(capacity: configuration.provisionalCapacity)
    }

    public var stats: LedgerStats {
        var snapshot = counters
        snapshot.idempotencyEvictions = records.evictions
        snapshot.provisionalEvictions = provisional.evictions
        return snapshot
    }

    // MARK: Reserve

    /// - Parameter promptDigest: a hash of the exact request the backend counted (model, messages,
    ///   `max_tokens`). `claim` must present the same digest, so a completion can't run a different,
    ///   larger prompt than the one that was admitted.
    public mutating func authorize(_ id: RequestID, key: QuotaKey, apiKey: String, estimate: Estimate,
                                   promptDigest: String? = nil, now: Millis) -> Decision {
        // Idempotent replay: a retry of an open request gets the same grant and no new hold —
        // but only if it really is the same request.
        if let hold = holds[id] {
            guard hold.matches(key: key, apiKey: apiKey, estimate: estimate, promptDigest: promptDigest) else {
                return rejectReuse()
            }
            counters.replays = Sat.add(counters.replays, 1)
            return .granted(hold.grant)
        }
        if let parked = provisional[id] {
            guard parked.hold.matches(key: key, apiKey: apiKey, estimate: estimate, promptDigest: promptDigest) else {
                return rejectReuse()
            }
            return deny(.alreadyClaimed, retryAfter: nil)
        }
        if let record = records[id] {
            guard record.matches(key: key, apiKey: apiKey, estimate: estimate, promptDigest: promptDigest) else {
                return rejectReuse()
            }
            switch record.terminal {
            case .settled:
                // The ID is spent. Re-granting it could let a retry call the model again for free.
                return deny(.alreadySettled, retryAfter: nil)
            case .expiredUnclaimed:
                break   // the hold lapsed unused and was refunded: evaluate it afresh
            }
        }

        guard estimate.isValid else { return deny(.invalidEstimate, retryAfter: nil) }
        if let features = configuration.features, !features.contains(key.feature) {
            return deny(.unknownFeature, retryAfter: nil)
        }
        guard let policy = configuration.policies[key.tier] else { return deny(.unknownTier, retryAfter: nil) }
        guard estimate.total <= policy.effectiveMaxSingleRequest else { return deny(.requestTooLarge, retryAfter: nil) }
        if inFlight(for: key) >= max(1, policy.maxInFlight) {
            expireHolds(Array(holdIDs[key] ?? []), now: now)   // lazy, and O(maxInFlight)
            guard inFlight(for: key) < max(1, policy.maxInFlight) else {
                return deny(.tooManyInFlight, retryAfter: Time.second)
            }
        }
        if holds.count >= max(1, configuration.maxOutstandingHolds) {
            // Lazy expiry: a late sweep must not turn into a global outage. It scans every hold,
            // so it runs at most once a second.
            if lastGlobalExpiryMs.map({ Sat.sub(now, $0) >= Time.second }) ?? true {
                lastGlobalExpiryMs = now
                expireHolds(Array(holds.keys), now: now)
            }
            guard holds.count < max(1, configuration.maxOutstandingHolds) else {
                return deny(.tooManyInFlight, retryAfter: Time.second)
            }
        }

        let cost = configuration.price.cost(estimate)
        breaker.roll(now: now)
        if breaker.isOpen(now: now), let openUntil = breaker.openUntil {
            return deny(.orgSpendBreakerOpen, retryAfter: max(0, Sat.sub(openUntil, now)))
        }
        guard breaker.canAdmit(cost) else {
            // Blocked only by in-flight holds: they settle within seconds, so retry soon.
            let retry = breaker.blockedOnlyByHolds(cost) ? 5 * Time.second : max(0, Sat.sub(breaker.windowEnd, now))
            return deny(.orgBudgetWouldExceed, retryAfter: retry)
        }

        guard storeAvailable else {
            return authorizeDuringOutage(id, key: key, apiKey: apiKey, estimate: estimate, promptDigest: promptDigest,
                                         policy: policy, cost: cost, now: now)
        }

        // Check every limit on copies first; commit only if all pass (invariant 1).
        var day = daily[key] ?? DailyUsage(dayIndex: Time.dayIndex(now))
        day.roll(now: now)
        guard Sat.add(day.used, estimate.total) <= policy.dailyBudget else {
            let nextDay = Time.startOfDay(Sat.add(day.dayIndex, 1))
            return deny(.dailyBudgetExhausted, retryAfter: max(0, Sat.sub(nextDay, now)))
        }
        var bucket = buckets[key] ?? TokenBucket(limit: policy.burst, now: now)
        bucket.refill(now: now)
        guard bucket.canTake(estimate.total) else {
            return deny(.burstExhausted, retryAfter: bucket.millisUntilAvailable(estimate.total))
        }

        bucket.take(estimate.total)
        day.used = Sat.add(day.used, estimate.total)
        buckets[key] = bucket
        daily[key] = day
        breaker.hold(cost)

        let grant = Grant(requestID: id, reservedTokens: estimate.total,
                          burstRemaining: bucket.availableTokens,
                          dailyRemaining: max(0, Sat.sub(policy.dailyBudget, day.used)),
                          degraded: false)
        insertHold(Hold(key: key, apiKey: apiKey, estimate: estimate, promptDigest: promptDigest, grant: grant,
                        createdMs: now, windowDay: day.dayIndex, debitedCounters: true, estimatedCost: cost,
                        outageEpoch: 0), for: id)
        counters.granted = Sat.add(counters.granted, 1)
        return .granted(grant)
    }

    private mutating func authorizeDuringOutage(_ id: RequestID, key: QuotaKey, apiKey: String,
                                                estimate: Estimate, promptDigest: String?, policy: TierPolicy,
                                                cost: Int64, now: Millis) -> Decision {
        switch policy.outage {
        case .failClosed:
            return deny(.storeUnavailable, retryAfter: nil)
        case .failOpenBounded(let allowance):
            guard estimate.total <= allowance else { return deny(.exceedsOutageAllowance, retryAfter: nil) }
            let used = outageUsed[key] ?? 0
            let after = Sat.add(used, estimate.total)
            guard after <= allowance else { return deny(.outageAllowanceExhausted, retryAfter: nil) }
            outageUsed[key] = after
            breaker.hold(cost)
            let grant = Grant(requestID: id, reservedTokens: estimate.total, burstRemaining: 0,
                              dailyRemaining: max(0, Sat.sub(allowance, after)), degraded: true)
            insertHold(Hold(key: key, apiKey: apiKey, estimate: estimate, promptDigest: promptDigest, grant: grant,
                            createdMs: now, windowDay: Time.dayIndex(now), debitedCounters: false,
                            estimatedCost: cost, outageEpoch: outageEpoch), for: id)
            counters.granted = Sat.add(counters.granted, 1)
            counters.degradedGrants = Sat.add(counters.degradedGrants, 1)
            return .granted(grant)
        }
    }

    private mutating func deny(_ reason: DenialReason, retryAfter: Millis?) -> Decision {
        counters.denied[reason, default: 0] = Sat.add(counters.denied[reason, default: 0], 1)
        return .denied(Denial(reason: reason, retryAfterMs: retryAfter))
    }

    private mutating func rejectReuse() -> Decision {
        counters.requestIDReuses = Sat.add(counters.requestIDReuses, 1)
        return deny(.requestIDReused, retryAfter: nil)
    }

    private mutating func insertHold(_ hold: Hold, for id: RequestID) {
        holds[id] = hold
        holdIDs[hold.key, default: []].insert(id)
    }

    private mutating func removeHold(_ id: RequestID) -> Hold? {
        guard let hold = holds.removeValue(forKey: id) else { return nil }
        holdIDs[hold.key]?.remove(id)
        if holdIDs[hold.key]?.isEmpty == true { holdIDs[hold.key] = nil }
        return hold
    }

    /// Remembers a finished request. Records past retention are purged first, so the capacity cap
    /// only ever evicts IDs that are still inside their retention window.
    private mutating func remember(_ id: RequestID, _ record: Record, now: Millis) {
        purgeRecords(now: now)
        records.insert(record, for: id)
    }

    // MARK: Claim

    /// Called by the completion handler immediately before it calls the model, with the same user,
    /// API key and prompt digest it authorised. At most one claim per request ID returns `.claimed`;
    /// every other caller must serve the first call's response (or wait for it).
    public mutating func claim(_ id: RequestID, key: QuotaKey, apiKey: String, promptDigest: String? = nil,
                               now: Millis) -> ClaimResult {
        if var hold = holds[id] {
            guard hold.matchesClaim(key: key, apiKey: apiKey, promptDigest: promptDigest) else {
                counters.claimMismatches = Sat.add(counters.claimMismatches, 1)
                return .mismatch
            }
            guard hold.claimedAtMs == nil else {
                counters.duplicateClaims = Sat.add(counters.duplicateClaims, 1)
                return .alreadyClaimed
            }
            hold.claimedAtMs = now
            holds[id] = hold
            counters.claims = Sat.add(counters.claims, 1)
            return .claimed(hold.grant)
        }
        if let parked = provisional[id] {
            guard parked.hold.matchesClaim(key: key, apiKey: apiKey, promptDigest: promptDigest) else {
                counters.claimMismatches = Sat.add(counters.claimMismatches, 1)
                return .mismatch
            }
            counters.duplicateClaims = Sat.add(counters.duplicateClaims, 1)
            return .alreadyClaimed
        }
        guard let record = records[id] else { return .noHold }
        // Same identity check as an open hold's, so `alreadySettled` (and the cached response a
        // handler serves for it) only ever goes to the request that was actually authorised.
        guard record.key == key, record.apiKey == apiKey,
              record.estimate == nil || record.promptDigest == promptDigest else {
            counters.claimMismatches = Sat.add(counters.claimMismatches, 1)
            return .mismatch
        }
        switch record.terminal {
        case .settled: return .alreadySettled
        case .expiredUnclaimed: return .noHold
        }
    }

    // MARK: Settle

    /// Replaces a hold with the actual usage from the response (`Usage.zero` if the call failed
    /// before billing). `key` and `apiKey` are only used when the ledger has no record of `id`;
    /// otherwise the reservation's owner is charged.
    public mutating func settle(_ id: RequestID, key: QuotaKey, apiKey: String,
                                usage: Usage, now: Millis) -> SettleOutcome {
        guard usage.isValid else { return .invalidUsage }
        let record = records[id]
        if let record, record.terminal == .settled {
            counters.duplicateSettles = Sat.add(counters.duplicateSettles, 1)
            return .duplicate
        }

        let actual = usage.total
        let actualCost = configuration.price.cost(usage)
        counters.settled = Sat.add(counters.settled, 1)

        if let hold = removeHold(id) {
            breaker.release(hold.estimatedCost)
            breaker.spend(actualCost, now: now)
            let adjust = hold.debitedCounters ? Sat.sub(actual, hold.grant.reservedTokens) : actual
            let persistence = apply(entry(for: hold, adjust: adjust, attributed: actual, now: now), now: now)
            remember(id, Record(hold, terminal: .settled, finishedAtMs: now), now: now)
            return .settled(charged: actual, adjustment: adjust, persistence: persistence)
        }

        if let parked = provisional.removeValue(forKey: id) {
            // The call outlived its claimed TTL; its provisional charge (and estimated cost) were
            // kept, so only the difference is applied now — a refund if it used less.
            breaker.spend(max(0, Sat.sub(actualCost, parked.hold.estimatedCost)), now: now)
            let adjust = Sat.sub(actual, parked.provisionalTokens)
            let persistence = apply(entry(for: parked.hold, adjust: adjust, attributed: actual, now: now), now: now)
            remember(id, Record(parked.hold, terminal: .settled, finishedAtMs: now), now: now)
            counters.lateSettles = Sat.add(counters.lateSettles, 1)
            return .lateSettled(charged: actual, persistence: persistence)
        }

        breaker.spend(actualCost, now: now)
        let today = Time.dayIndex(now)
        let attributionDay: Int64
        switch configuration.attributeUsageTo {
        case .callStart: attributionDay = Time.dayIndex(record?.startedAtMs ?? now)
        case .settlement: attributionDay = today
        }
        // A remembered (expired) request is charged to whoever reserved it, not to the caller's key.
        let fullCharge = JournalEntry(key: record?.key ?? key, apiKey: record?.apiKey ?? apiKey, windowDay: today,
                                      counterAdjust: actual, attributionDay: attributionDay, attributedTokens: actual)
        let persistence = apply(fullCharge, now: now)
        if var expired = record {
            // Expired unclaimed: it was refunded, so the actual usage is charged in full.
            expired.terminal = .settled
            expired.finishedAtMs = now
            remember(id, expired, now: now)
            counters.lateSettles = Sat.add(counters.lateSettles, 1)
            return .lateSettled(charged: actual, persistence: persistence)
        }
        remember(id, Record(unknown: key, apiKey: apiKey, at: now), now: now)
        counters.unknownSettles = Sat.add(counters.unknownSettles, 1)
        return .unknownSettled(charged: actual, persistence: persistence)
    }

    private func entry(for hold: Hold, adjust: Int64, attributed: Int64, now: Millis) -> JournalEntry {
        let attributionInstant: Millis
        switch configuration.attributeUsageTo {
        case .callStart: attributionInstant = hold.startedAtMs
        case .settlement: attributionInstant = now
        }
        return JournalEntry(key: hold.key, apiKey: hold.apiKey, windowDay: hold.windowDay,
                            counterAdjust: adjust, attributionDay: Time.dayIndex(attributionInstant),
                            attributedTokens: attributed)
    }

    /// Applies an entry now, or journals it while the store is down.
    private mutating func apply(_ entry: JournalEntry, now: Millis) -> Persistence {
        guard storeAvailable else {
            guard journal.count < max(0, configuration.journalCapacity) else {
                // The single loss path: counted, and visible in reconciliation as ledgerUnder.
                counters.journalDroppedEntries = Sat.add(counters.journalDroppedEntries, 1)
                counters.journalDroppedTokens = Sat.add(counters.journalDroppedTokens, max(0, entry.attributedTokens))
                if entry.attributedTokens <= 0, entry.counterAdjust > 0 {
                    counters.journalDroppedChargeTokens = Sat.add(counters.journalDroppedChargeTokens, entry.counterAdjust)
                }
                return .dropped
            }
            journal.append(entry)
            return .journaled
        }
        commit(entry, now: now)
        return .applied
    }

    private mutating func commit(_ entry: JournalEntry, now: Millis) {
        if let policy = configuration.policies[entry.key.tier] {
            var bucket = buckets[entry.key] ?? TokenBucket(limit: policy.burst, now: now)
            bucket.refill(now: now)
            if entry.counterAdjust > 0 { bucket.take(entry.counterAdjust) }
            if entry.counterAdjust < 0 { bucket.give(Sat.neg(entry.counterAdjust)) }
            buckets[entry.key] = bucket

            var day = daily[entry.key] ?? DailyUsage(dayIndex: Time.dayIndex(now))
            day.roll(now: now)
            // An adjustment for a window that has already closed is dropped from the *counter*
            // (that day can no longer be enforced) but still attributed below.
            if day.dayIndex == entry.windowDay {
                day.used = max(0, Sat.add(day.used, entry.counterAdjust))
            }
            daily[entry.key] = day
        }
        if entry.attributedTokens > 0 {
            let key = AttributionKey(apiKey: entry.apiKey, dayIndex: entry.attributionDay)
            attribution[key] = Sat.add(attribution[key] ?? 0, entry.attributedTokens)
        }
    }

    // MARK: Outage

    /// Marks the counter store reachable or not. On recovery, parked refunds and then the journal are
    /// applied in order. Returns the number of journal entries replayed.
    @discardableResult
    public mutating func setStoreAvailable(_ available: Bool, now: Millis) -> Int {
        guard available != storeAvailable else { return 0 }
        storeAvailable = available
        guard available else {
            outageEpoch = Sat.add(outageEpoch, 1)
            return 0
        }
        let refunds = pendingRefunds
        pendingRefunds.removeAll()
        for refund in refunds { commit(refund, now: now) }
        let pending = journal
        journal.removeAll()
        outageUsed.removeAll()
        for entry in pending { commit(entry, now: now) }
        counters.refundsReplayed = Sat.add(counters.refundsReplayed, Int64(refunds.count))
        counters.journalReplayed = Sat.add(counters.journalReplayed, Int64(pending.count))
        return pending.count
    }

    /// Closes the org breaker (an on-call decision), optionally adding headroom to this window's cap.
    public mutating func resetBreaker(overrideMicroUSD: Int64 = 0, now: Millis) {
        breaker.reset(overrideMicroUSD: overrideMicroUSD, now: now)
    }

    // MARK: Maintenance

    /// Expires stale holds, forgets request IDs past retention, and garbage-collects counters that
    /// are equivalent to fresh ones. The backend calls this on a timer (every few seconds); nothing
    /// else bounds `attribution` or the idempotency window's time limit.
    public mutating func sweep(now: Millis) {
        expireHolds(Array(holds.keys), now: now)
        purgeRecords(now: now)
        purgeProvisional(now: now)

        guard storeAvailable else { return }
        let today = Time.dayIndex(now)
        // A full bucket with no usage today is indistinguishable from a fresh one, even if a hold
        // from an earlier day is still open: settling it recreates the same counters.
        for (key, var bucket) in buckets {
            bucket.refill(now: now)
            let usedToday = daily[key].map { $0.dayIndex >= today && $0.used > 0 } ?? false
            if bucket.isFull, !usedToday {
                buckets[key] = nil
                daily[key] = nil
            }
        }
        let oldestKept = Sat.sub(today, max(0, configuration.attributionRetentionDays))
        attribution = attribution.filter { $0.key.dayIndex >= oldestKept }
    }

    private mutating func expireHolds(_ candidates: [RequestID], now: Millis) {
        let due = candidates.filter { id in holds[id].map { $0.expiresAt(configuration) <= now } ?? false }.sorted()
        for id in due {
            guard let hold = removeHold(id) else { continue }
            breaker.release(hold.estimatedCost)
            counters.expiredHolds = Sat.add(counters.expiredHolds, 1)
            if hold.claimedAtMs != nil {
                expireMidCall(id, hold, now: now)
            } else {
                expireUnclaimed(id, hold, now: now)
            }
        }
    }

    /// A model call started and never reported back; it almost certainly used tokens. Keep the
    /// reservation as a provisional charge (fail toward counting) and keep the ID spent, so a retry
    /// can't claim a second call. A late settle trues it up.
    private mutating func expireMidCall(_ id: RequestID, _ hold: Hold, now: Millis) {
        var provisionalTokens = hold.grant.reservedTokens
        if !hold.debitedCounters {
            // An outage grant never touched the counters, so its provisional charge is written now.
            let charge = JournalEntry(key: hold.key, apiKey: hold.apiKey, windowDay: hold.windowDay,
                                      counterAdjust: hold.grant.reservedTokens,
                                      attributionDay: Time.dayIndex(hold.startedAtMs), attributedTokens: 0)
            if apply(charge, now: now) == .dropped { provisionalTokens = 0 }
        }
        breaker.spend(hold.estimatedCost, now: now)
        purgeProvisional(now: now)
        provisional.insert(Provisional(hold: hold, provisionalTokens: provisionalTokens, expiredAtMs: now), for: id)
        counters.expiredMidCall = Sat.add(counters.expiredMidCall, 1)
    }

    /// The client never followed through: refund the reservation (or the outage allowance).
    private mutating func expireUnclaimed(_ id: RequestID, _ hold: Hold, now: Millis) {
        if hold.debitedCounters {
            let refund = JournalEntry(key: hold.key, apiKey: hold.apiKey, windowDay: hold.windowDay,
                                      counterAdjust: Sat.neg(hold.grant.reservedTokens),
                                      attributionDay: Time.dayIndex(now), attributedTokens: 0)
            if storeAvailable {
                _ = apply(refund, now: now)
            } else {
                // A refund is a write, and the store is down. Park it outside the journal (it can't
                // overflow: see `pendingRefunds`) and free the hold's slots now, so abandoned
                // pre-outage holds don't turn a fail-open tier into a fail-closed one.
                pendingRefunds.append(refund)
            }
        } else if !storeAvailable, hold.outageEpoch == outageEpoch, let used = outageUsed[hold.key] {
            // An unused degraded hold gives its allowance back — but only to the outage it came from.
            outageUsed[hold.key] = max(0, Sat.sub(used, hold.grant.reservedTokens))
        }
        remember(id, Record(hold, terminal: .expiredUnclaimed, finishedAtMs: now), now: now)
    }

    private mutating func purgeRecords(now: Millis) {
        let retention = max(0, configuration.idempotencyRetentionMs)
        records.removeOldest { _, record in Sat.add(record.finishedAtMs, retention) <= now }
    }

    private mutating func purgeProvisional(now: Millis) {
        let retention = max(0, configuration.provisionalRetentionMs)
        provisional.removeOldest { _, parked in Sat.add(parked.expiredAtMs, retention) <= now }
    }

    // MARK: Read-only views

    public func bucket(for key: QuotaKey) -> TokenBucket? { buckets[key] }

    public func dailyUsed(for key: QuotaKey, now: Millis) -> Int64 {
        guard let day = daily[key], day.dayIndex == Time.dayIndex(now) else { return 0 }
        return day.used
    }

    public func inFlight(for key: QuotaKey) -> Int { holdIDs[key]?.count ?? 0 }
    /// Keys with at least one open hold.
    public var keysInFlight: Int { holdIDs.count }
    public var outstandingHolds: Int { holds.count }
    public var journalCount: Int { journal.count }
    public var pendingRefundCount: Int { pendingRefunds.count }
    public var trackedKeys: Int { Set(buckets.keys).union(daily.keys).count }
    public var rememberedRequests: Int { records.count }
    public var rememberedMidCallExpiries: Int { provisional.count }
}
