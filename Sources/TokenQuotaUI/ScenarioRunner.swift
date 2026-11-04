import Foundation
import TokenQuota

/// A deterministic, scripted run of the real gateway + client on a manual clock.
/// Portable (no SwiftUI), so the scenario tests run on Linux as well as on Apple platforms.
public enum Scenario: String, CaseIterable, Sendable, Identifiable {
    case runawayAgent, storeOutage, lostResponse, orgBreaker, reconcile

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .runawayAgent: return "Runaway agent loop"
        case .storeOutage: return "Counter store outage"
        case .lostResponse: return "Lost response + retries"
        case .orgBreaker: return "Org spend breaker"
        case .reconcile: return "Reconcile vs. analytics"
        }
    }

    public init?(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "-scenario"),
              arguments.indices.contains(flag + 1),
              let scenario = Scenario(rawValue: arguments[flag + 1]) else { return nil }
        self = scenario
    }
}

public struct ScenarioEvent: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable { case grant, deny, local, settle, info, alert }
    public let id: Int
    public let atMs: Millis
    public let kind: Kind
    public let text: String
}

public struct ScenarioMetric: Sendable, Equatable, Identifiable {
    public let label: String
    public let value: String
    public var id: String { label }
}

public struct ScenarioReport: Sendable, Equatable {
    public let scenario: Scenario
    public let headline: String
    public let metrics: [ScenarioMetric]
    public let events: [ScenarioEvent]
    public let findings: [DriftFinding]
    /// Raw counts the tests assert on (and the headline is computed from).
    public let counts: [String: Int64]
}

/// The demo's limits. Prices are illustrative ($3 / $15 per million input/output tokens).
public enum DemoLimits {
    public static let configuration = LedgerConfiguration(
        policies: [
            .free: TierPolicy(burst: BucketLimit(capacity: 6_000, refillPerSecond: 50),
                              dailyBudget: 40_000, maxSingleRequest: 4_000, outage: .failClosed),
            .pro: TierPolicy(burst: BucketLimit(capacity: 24_000, refillPerSecond: 200),
                             dailyBudget: 400_000, maxSingleRequest: 16_000,
                             outage: .failOpenBounded(allowanceTokens: 8_000)),
            .enterprise: TierPolicy(burst: BucketLimit(capacity: 100_000, refillPerSecond: 1_000),
                                    dailyBudget: 5_000_000, maxSingleRequest: 64_000,
                                    outage: .failOpenBounded(allowanceTokens: 50_000)),
        ],
        features: ["summarize", "translate", "draft-reply", "doc-review"],
        price: PriceTable(inputMicroUSDPerMTok: 3_000_000, outputMicroUSDPerMTok: 15_000_000),
        orgSpendLimitMicroUSD: 5_000_000,           // $5.00 per hour
        orgVelocityTripMicroUSD: 2_000_000,         // $2.00 inside any 5-minute window trips the breaker
        orgVelocityWindowMs: 5 * Time.minute,
        orgBreakerCooldownMs: 15 * Time.minute)

    /// 20 days after the epoch, 10:00 UTC — far enough in that "two days ago" exists.
    public static let start: Millis = 20 * Time.day + 10 * Time.hour
}

public enum ScenarioRunner {
    /// The phone's default on-device model: present, good for jobs up to 4,000 tokens.
    public static let standardDevice = OnDeviceCapability(available: true, maxTokens: 4_000)

    /// - Parameter onDevice: what *this* device can run locally. It is the app's call, not the
    ///   library's (it depends on hardware and OS), so the demo app passes it in.
    public static func run(_ scenario: Scenario, onDevice: OnDeviceCapability = standardDevice) async -> ScenarioReport {
        var log = Log(clock: ManualClock(startingAt: DemoLimits.start))
        switch scenario {
        case .runawayAgent: return await runaway(&log, onDevice: onDevice)
        case .storeOutage: return await outage(&log)
        case .lostResponse: return await lostResponse(&log, onDevice: onDevice)
        case .orgBreaker: return await orgBreaker(&log)
        case .reconcile: return await reconcile(&log)
        }
    }

    struct Log {
        let clock: ManualClock
        var events: [ScenarioEvent] = []
        var nextID = 0

        mutating func add(_ kind: ScenarioEvent.Kind, _ text: String) {
            events.append(ScenarioEvent(id: nextID, atMs: Sat.sub(clock.nowMillis(), DemoLimits.start),
                                        kind: kind, text: text))
            nextID += 1
        }
    }

    static func counter(prefix: String = "r-") -> @Sendable () -> RequestID {
        let box = IDBox(prefix: prefix)
        return { box.next() }
    }

    /// Scenarios never really sleep: the clock is manual, so backoff waits are instantaneous.
    static let noSleep: @Sendable (Millis) async -> Void = { _ in }

    // MARK: Runaway agent

    static func runaway(_ log: inout Log, onDevice: OnDeviceCapability) async -> ScenarioReport {
        let gateway = QuotaGateway(configuration: DemoLimits.configuration, clock: log.clock)
        let client = QuotaClient(transport: gateway, clock: log.clock, policy: ClientPolicy(onDevice: onDevice),
                                 makeRequestID: counter(), sleep: noSleep)
        let key = QuotaKey(userID: "u-free-7", feature: "summarize", tier: .free)
        let estimate = Estimate(inputTokens: 1_000, maxOutputTokens: 500)
        let usage = Usage(inputTokens: 1_000, outputTokens: 320)
        let loopCalls = 12
        let spacing: Millis = 150
        let pause: Millis = 30 * Time.second
        let burst = DemoLimits.configuration.policies[.free]?.burst.capacity ?? 0
        var cloud: Int64 = 0, ranOnDevice: Int64 = 0, waited: Int64 = 0, limited: Int64 = 0

        log.add(.info, "Agent loop starts: \(loopCalls) summarize calls, \(spacing) ms apart (free tier, \(formatTokens(burst))-token burst).")
        for step in 1...(loopCalls + 1) {
            if step == loopCalls + 1 {
                log.clock.advance(by: pause)
                log.add(.info, "User comes back \(formatSeconds(pause)) later.")
            } else if step > 1 {
                log.clock.advance(by: spacing)
            }
            let route = await client.route(key: key, apiKey: "key-summarize", estimate: estimate)
            switch route {
            case .cloud(let grant):
                cloud += 1
                _ = await gateway.claim(grant.requestID, key: key, apiKey: "key-summarize")   // right before the model call
                _ = await gateway.settle(grant.requestID, key: key, apiKey: "key-summarize", usage: usage)
                log.add(.grant, "#\(step) cloud — reserved \(formatTokens(grant.reservedTokens)) (burst left \(formatTokens(grant.burstRemaining))), settled \(formatTokens(usage.total))")
            case .onDevice(let reason), .tryLater(_, let reason):
                let local = route == .onDevice(reason)
                if local { ranOnDevice += 1 } else { waited += 1 }
                let outcome = local ? "ran on device" : "shown \"try again shortly\" (no on-device model)"
                if case .limited(let denial) = reason {
                    limited += 1
                    let until = await client.cooldown(for: key.feature) ?? 0
                    log.add(.deny, "#\(step) 429 \(denial.rawValue) — Retry-After \(formatSeconds(Sat.sub(until, log.clock.nowMillis()))); \(outcome)")
                } else {
                    log.add(.local, "#\(step) \(reason.label) — no network call; \(outcome)")
                }
            case .unavailable(let reason):
                log.add(.deny, "#\(step) \(reason.rawValue) — not retried")
            case .cancelled:
                log.add(.local, "#\(step) cancelled")
            }
        }
        let attempts = Int64(await client.networkAttempts)
        let local = Int64(await client.localDecisions)
        let throttled = ranOnDevice + waited
        let headline = ranOnDevice > 0
            ? "\(local) of \(throttled) throttled calls were answered on the phone without a network round trip; cloud resumed after the Retry-After."
            : "\(local) of \(throttled) throttled calls were held on the phone without a network round trip (no on-device model, so the user saw \"try again shortly\"); cloud resumed after the Retry-After."
        return ScenarioReport(
            scenario: .runawayAgent, headline: headline,
            metrics: [ScenarioMetric(label: "Cloud calls", value: "\(cloud)"),
                      ScenarioMetric(label: ranOnDevice > 0 ? "On-device" : "Try later", value: "\(throttled)"),
                      ScenarioMetric(label: "Network attempts", value: "\(attempts)"),
                      ScenarioMetric(label: "Decided locally", value: "\(local)")],
            events: log.events, findings: [],
            counts: ["cloud": cloud, "onDevice": ranOnDevice, "tryLater": waited, "throttled": throttled,
                     "limited": limited, "networkAttempts": attempts, "localDecisions": local])
    }

    // MARK: Store outage

    static func outage(_ log: inout Log) async -> ScenarioReport {
        let gateway = QuotaGateway(configuration: DemoLimits.configuration, clock: log.clock)
        // An older phone: no on-device model, so a denial means "try later".
        let noModel = ClientPolicy(onDevice: OnDeviceCapability(available: false, maxTokens: 0))
        let freeClient = QuotaClient(transport: gateway, clock: log.clock, policy: noModel,
                                     makeRequestID: counter(), sleep: noSleep)
        let proClient = QuotaClient(transport: gateway, clock: log.clock, policy: noModel,
                                    makeRequestID: counter(prefix: "pro-"), sleep: noSleep)
        let free = QuotaKey(userID: "u-free-1", feature: "translate", tier: .free)
        let pro = QuotaKey(userID: "u-pro-1", feature: "translate", tier: .pro)
        let estimate = Estimate(inputTokens: 2_000, maxOutputTokens: 1_000)
        let actual = Usage(inputTokens: 2_400, outputTokens: 1_000)

        await gateway.setStoreAvailable(false)
        log.add(.alert, "Counter store unreachable (Redis primary failing over).")

        var freeDenied: Int64 = 0, proGranted: Int64 = 0, proDenied: Int64 = 0, journaled: Int64 = 0
        if case .tryLater(_, .limited(let reason)) = await freeClient.route(key: free, apiKey: "key-translate", estimate: estimate) {
            freeDenied += 1
            log.add(.deny, "free: \(reason.rawValue) — fails closed, try later")
        }
        for step in 1...3 {
            log.clock.advance(by: 2 * Time.second)
            let route = await proClient.route(key: pro, apiKey: "key-translate", estimate: estimate)
            switch route {
            case .cloud(let grant):
                proGranted += 1
                _ = await gateway.claim(grant.requestID, key: pro, apiKey: "key-translate")
                let outcome = await gateway.settle(grant.requestID, key: pro, apiKey: "key-translate", usage: actual)
                var persistence = "?"
                if case .settled(let charged, _, let persisted) = outcome {
                    persistence = "\(formatTokens(charged)) → \(persisted.rawValue)"
                    if persisted == .journaled { journaled += 1 }
                }
                log.add(.grant, "pro #\(step): degraded grant (allowance left \(formatTokens(grant.dailyRemaining))); settled \(persistence)")
            case .tryLater(_, .limited(let reason)), .onDevice(.limited(let reason)):
                proDenied += 1
                log.add(.deny, "pro #\(step): \(reason.rawValue) — the outage allowance is spent")
            case .tryLater(_, let reason), .onDevice(let reason):
                log.add(.local, "pro #\(step): \(reason.label)")
            case .unavailable(let reason):
                log.add(.deny, "pro #\(step): \(reason.rawValue) — not retried")
            case .cancelled:
                log.add(.local, "pro #\(step): cancelled")
            }
            // Clear the client's cooldown between steps so each attempt reaches the gateway.
            log.clock.advance(by: 31 * Time.second)
        }

        log.clock.advance(by: 20 * Time.second)
        let replayed = await gateway.setStoreAvailable(true)
        let ledger = await gateway.snapshot()
        let proUsed = ledger.dailyUsed(for: pro, now: log.clock.nowMillis())
        let lostTokens = ledger.stats.journalDroppedTokens
        log.add(.info, "Store back. Replayed \(replayed) journaled settlements; pro daily usage now \(formatTokens(proUsed)).")
        var allowance: Int64 = 0
        if case .failOpenBounded(let tokens) = DemoLimits.configuration.policies[.pro]?.outage { allowance = tokens }
        let replayedText = replayed == 2 ? "both" : "all \(replayed)"
        let headline = "Free failed closed, pro failed open within its \(formatTokens(allowance))-token allowance, and \(replayedText) outage settlements were replayed on recovery: \(formatTokens(lostTokens)) tokens of usage lost."
        return ScenarioReport(
            scenario: .storeOutage, headline: headline,
            metrics: [ScenarioMetric(label: "Free denied", value: "\(freeDenied)"),
                      ScenarioMetric(label: "Pro degraded grants", value: "\(proGranted)"),
                      ScenarioMetric(label: "Journal replayed", value: "\(replayed)"),
                      ScenarioMetric(label: "Pro usage after replay", value: formatTokens(proUsed))],
            events: log.events, findings: [],
            counts: ["freeDenied": freeDenied, "proGranted": proGranted, "proDenied": proDenied,
                     "journaled": journaled, "replayed": Int64(replayed), "proUsed": proUsed,
                     "lostTokens": lostTokens])
    }

    // MARK: Lost response

    static func lostResponse(_ log: inout Log, onDevice: OnDeviceCapability) async -> ScenarioReport {
        let gateway = QuotaGateway(configuration: DemoLimits.configuration, clock: log.clock)
        let flaky = FaultInjectingTransport(upstream: gateway, plan: [.responseLost, .unreachable, .none])
        let client = QuotaClient(transport: flaky, clock: log.clock, policy: ClientPolicy(onDevice: onDevice),
                                 makeRequestID: counter(), sleep: noSleep)
        let key = QuotaKey(userID: "u-pro-9", feature: "draft-reply", tier: .pro)
        let estimate = Estimate(inputTokens: 3_000, maxOutputTokens: 1_000)

        log.add(.info, "Attempt 1 reaches the gateway, but the response is lost; attempt 2 never leaves the phone.")
        let route = await client.route(key: key, apiKey: "key-draft", estimate: estimate)
        let attempts = Int64(await flaky.attempts)
        var modelCalls: Int64 = 0, charges: Int64 = 0
        if case .cloud(let grant) = route {
            log.add(.grant, "Attempt \(attempts) succeeds with request ID \(grant.requestID) — the same ID as attempt 1.")
            // The app's completion request is retried too, so two handlers race for the same ID.
            for handler in 1...2 {
                switch await gateway.claim(grant.requestID, key: key, apiKey: "key-draft") {
                case .claimed:
                    modelCalls += 1
                    log.add(.grant, "Completion handler \(handler): claimed → calls the model")
                case let other:
                    log.add(.local, "Completion handler \(handler): \(other) → serves the first call's response, no second model call")
                }
            }
            let usage = Usage(inputTokens: 3_000, outputTokens: 640)
            for delivery in 1...2 {   // the settlement queue delivers twice
                let outcome = await gateway.settle(grant.requestID, key: key, apiKey: "key-draft", usage: usage)
                if case .settled(let charged, _, _) = outcome {
                    charges += 1
                    log.add(.settle, "Settlement \(delivery): charged \(formatTokens(charged))")
                } else {
                    log.add(.settle, "Settlement \(delivery): \(outcome) — not charged again")
                }
            }
        }
        let ledger = await gateway.snapshot()
        let used = ledger.dailyUsed(for: key, now: log.clock.nowMillis())
        let headline = "\(attempts) attempts, \(ledger.stats.granted) reservation, \(modelCalls) model call, \(charges) charge: daily usage is \(formatTokens(used)) tokens, exactly the response's usage."
        return ScenarioReport(
            scenario: .lostResponse, headline: headline,
            metrics: [ScenarioMetric(label: "Attempts", value: "\(attempts)"),
                      ScenarioMetric(label: "Reservations", value: "\(ledger.stats.granted)"),
                      ScenarioMetric(label: "Model calls", value: "\(modelCalls)"),
                      ScenarioMetric(label: "Charges", value: "\(charges)")],
            events: log.events, findings: [],
            counts: ["attempts": attempts, "granted": ledger.stats.granted, "replays": ledger.stats.replays,
                     "duplicates": ledger.stats.duplicateSettles, "used": used, "modelCalls": modelCalls,
                     "charges": charges, "duplicateClaims": ledger.stats.duplicateClaims,
                     "cloud": route.isCloud ? 1 : 0])
    }

    // MARK: Org breaker

    struct DocJobs {
        var admitted: Int64 = 0
        var refused: Int64 = 0
        var spent: Int64 = 0
        var trips: Int64 = 0
        var lastTrip: OrgSpendBreaker.TripReason?
        var tripSeat: Int64 = 0
        var tripSpend: Int64 = 0
        var tripAtMs: Millis = 0
    }

    static let seats = 30
    /// `count_tokens` said 20,000 input tokens, but an attachment doubled it.
    static let docEstimate = Estimate(inputTokens: 20_000, maxOutputTokens: 4_000)
    static let docActual = Usage(inputTokens: 40_000, outputTokens: 4_000)

    /// `seats` enterprise seats each send one document job, 20 s apart.
    static func docJobs(_ configuration: LedgerConfiguration, resetAtSeat: Int?, log: inout Log) async -> DocJobs {
        let gateway = QuotaGateway(configuration: configuration, clock: log.clock)
        let estimate = docEstimate
        let actual = docActual
        var result = DocJobs()
        var loggedRefusal = false
        for seat in 1...seats {
            log.clock.advance(by: 20 * Time.second)
            if seat == resetAtSeat {
                await gateway.resetBreaker()
                log.add(.info, "On-call reviews the spike, decides it is legitimate, and resets the breaker.")
                loggedRefusal = false
            }
            let key = QuotaKey(userID: "seat-\(seat)", feature: "doc-review", tier: .enterprise)
            let request = AuthorizeRequest(requestID: RequestID("doc-\(seat)"), key: key, apiKey: "key-docs", estimate: estimate)
            switch await gateway.authorize(request) {
            case .granted:
                result.admitted += 1
                _ = await gateway.claim(request.requestID, key: key, apiKey: "key-docs")
                _ = await gateway.settle(request.requestID, key: key, apiKey: "key-docs", usage: actual)
                let breaker = await gateway.snapshot().breaker
                if breaker.trips > result.trips {
                    result.trips = breaker.trips
                    result.lastTrip = breaker.lastTrip
                    if result.tripSeat == 0 {
                        result.tripSeat = Int64(seat)
                        result.tripSpend = breaker.spentMicroUSD
                        result.tripAtMs = Sat.sub(log.clock.nowMillis(), DemoLimits.start)
                    }
                    log.add(.alert, "Seat \(seat): breaker trips (\(breaker.lastTrip?.rawValue ?? "?")) at \(formatDollars(breaker.spentMicroUSD)) spent this hour")
                }
            case .denied(let denial):
                result.refused += 1
                if !loggedRefusal {
                    loggedRefusal = true
                    log.add(.deny, "Seat \(seat) onward: \(denial.reason.rawValue), retry in \(formatSeconds(denial.retryAfterMs ?? 0))")
                }
            }
        }
        result.spent = await gateway.snapshot().breaker.spentMicroUSD
        return result
    }

    static func orgBreaker(_ log: inout Log) async -> ScenarioReport {
        let price = DemoLimits.configuration.price
        let cap = formatDollars(DemoLimits.configuration.orgSpendLimitMicroUSD)
        log.add(.info, "\(seats) enterprise seats each send one document job. Estimate \(formatDollars(price.cost(docEstimate))), actual \(formatDollars(price.cost(docActual))) (input undercounted).")
        let guarded = await docJobs(DemoLimits.configuration, resetAtSeat: 28, log: &log)
        // The same traffic against admission only (no velocity trip), to measure what the breaker bought.
        var admissionOnly = DemoLimits.configuration
        admissionOnly.orgVelocityTripMicroUSD = nil
        var shadow = Log(clock: ManualClock(startingAt: DemoLimits.start))
        let unguarded = await docJobs(admissionOnly, resetAtSeat: nil, log: &shadow)
        log.add(.info, "Same traffic with admission only: \(unguarded.admitted) admitted, \(formatDollars(unguarded.spent)) spent against the \(cap) cap.")

        let minutes = Sat.div(guarded.tripAtMs, Time.minute)
        let headline = "The velocity breaker tripped at \(formatDollars(guarded.tripSpend)) after \(minutes) minutes, with most of the \(cap) hourly cap unspent. Admission alone let the same traffic reach \(formatDollars(unguarded.spent)), past the cap, because the estimates were low."
        return ScenarioReport(
            scenario: .orgBreaker, headline: headline,
            metrics: [ScenarioMetric(label: "Spent, with breaker", value: formatDollars(guarded.spent)),
                      ScenarioMetric(label: "Spent, admission only", value: formatDollars(unguarded.spent)),
                      ScenarioMetric(label: "Refused while open", value: "\(guarded.refused)"),
                      ScenarioMetric(label: "Tripped at", value: "\(formatDollars(guarded.tripSpend)) · seat \(guarded.tripSeat)")],
            events: log.events, findings: [],
            counts: ["admitted": guarded.admitted, "refused": guarded.refused, "spent": guarded.spent,
                     "trips": guarded.trips, "tripSeat": guarded.tripSeat, "tripSpend": guarded.tripSpend,
                     "tripMinutes": minutes, "velocityTrip": guarded.lastTrip == .velocity ? 1 : 0,
                     "unguardedAdmitted": unguarded.admitted, "unguardedSpent": unguarded.spent,
                     "unguardedOverspendTrip": unguarded.lastTrip == .overspend ? 1 : 0])
    }

    // MARK: Reconcile

    static func reconcile(_ log: inout Log) async -> ScenarioReport {
        let gateway = QuotaGateway(configuration: DemoLimits.configuration, clock: log.clock)
        let today = Time.dayIndex(DemoLimits.start)
        func traffic(day: Int64, apiKey: String, feature: String, calls: Int) async {
            log.clock.set(Time.startOfDay(day) + 9 * Time.hour)
            for call in 0..<calls {
                log.clock.advance(by: 5 * Time.minute)
                let key = QuotaKey(userID: "u-\(call % 5)", feature: feature, tier: .pro)
                let id = RequestID("\(apiKey)-\(day)-\(call)")
                let request = AuthorizeRequest(requestID: id, key: key, apiKey: apiKey,
                                               estimate: Estimate(inputTokens: 4_000, maxOutputTokens: 1_000))
                if case .granted = await gateway.authorize(request) {
                    _ = await gateway.claim(id, key: key, apiKey: apiKey)
                    _ = await gateway.settle(id, key: key, apiKey: apiKey, usage: Usage(inputTokens: 4_000, outputTokens: 600))
                }
            }
        }
        for day in (today - 2)...today {
            await traffic(day: day, apiKey: "key-summarize", feature: "summarize", calls: 20)
            await traffic(day: day, apiKey: "key-translate", feature: "translate", calls: 10)
        }
        let pulledAt = DemoLimits.start + 4 * Time.hour
        let refreshedAt = DemoLimits.start + 3 * Time.hour + 10 * Time.minute
        log.clock.set(pulledAt)
        log.add(.info, "Ledger metered 3 days of traffic. Usage report pulled at \(formatClock(pulledAt)) UTC; data_refreshed_at is \(formatClock(refreshedAt)) UTC today.")
        // One call is 4,000 uncached input + 600 output tokens; rows use uncached_input_tokens + output_tokens.
        let perCall: Int64 = 4_600
        let report: [AnalyticsRow] = [
            // Matches to the token, split across two model rows that are summed.
            AnalyticsRow(apiKey: "key-summarize", dayIndex: today - 2, uncachedInputTokens: 48_000, outputTokens: 12_000),
            AnalyticsRow(apiKey: "key-summarize", dayIndex: today - 2, tokens: 20 * perCall - 60_000),
            AnalyticsRow(apiKey: "key-summarize", dayIndex: today - 1, tokens: 20 * perCall + 900),
            AnalyticsRow(apiKey: "key-translate", dayIndex: today - 2, tokens: 10 * perCall),
            // A share-extension path calls the model directly, so it was never metered: +18%.
            AnalyticsRow(apiKey: "key-translate", dayIndex: today - 1, tokens: 10 * perCall * 118 / 100),
            // A batch job on its own key that never goes through the backend.
            AnalyticsRow(apiKey: "key-batch", dayIndex: today - 1, tokens: 250_000),
            // Today's data is partial: after the watermark, not an error.
            AnalyticsRow(apiKey: "key-summarize", dayIndex: today, tokens: 20 * perCall / 2),
        ]
        let findings = await gateway.reconcile(report: report, dataRefreshedAt: refreshedAt)
        for finding in findings where finding.status.needsAttention {
            log.add(.alert, "\(finding.apiKey) day \(finding.dayIndex): \(describe(finding.status))")
        }
        let attention = Int64(findings.filter { $0.status.needsAttention }.count)
        let awaiting = Int64(findings.filter { $0.status == .awaitingData }.count)
        let matched = Int64(findings.filter { $0.status == .matched }.count)
        let headline = "\(attention) findings need a human: a path that bypasses the backend and a key the ledger has never seen. Today's shortfall is after the data watermark: lag, not drift."
        return ScenarioReport(
            scenario: .reconcile, headline: headline,
            metrics: [ScenarioMetric(label: "Key-days compared", value: "\(findings.count)"),
                      ScenarioMetric(label: "Matched", value: "\(matched)"),
                      ScenarioMetric(label: "Awaiting data", value: "\(awaiting)"),
                      ScenarioMetric(label: "Need attention", value: "\(attention)")],
            events: log.events, findings: findings,
            counts: ["attention": attention, "awaiting": awaiting, "matched": matched,
                     "findings": Int64(findings.count)])
    }

    // MARK: Formatting

    public static func describe(_ status: DriftStatus) -> String {
        switch status {
        case .matched: return "matched"
        case .awaitingData: return "awaiting data"
        case .ledgerOver(let n): return "ledger over by \(formatTokens(n))"
        case .ledgerUnder(let n): return "under-metered by \(formatTokens(n))"
        case .unknownKey(let n): return "unknown key, \(formatTokens(n)) tokens"
        }
    }

    /// Thousands separators without Foundation's locale machinery (so output is identical everywhere).
    public static func formatTokens(_ value: Int64) -> String {
        let digits = String(value.magnitude)   // `magnitude` is safe for Int64.min, unlike abs()
        var grouped = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { grouped.append(",") }
            grouped.append(digit)
        }
        return value < 0 ? "-" + grouped : grouped
    }

    /// `HH:MM` of an instant's UTC time of day.
    static func formatClock(_ instant: Millis) -> String {
        let minutes = Sat.div(Sat.sub(max(0, instant), Time.startOfDay(Time.dayIndex(instant))), Time.minute)
        let hours = minutes / 60, rest = minutes % 60
        return "\(hours < 10 ? "0" : "")\(hours):\(rest < 10 ? "0" : "")\(rest)"
    }

    static func formatSeconds(_ ms: Millis) -> String {
        let tenths = Sat.div(Sat.add(max(0, ms), 50), 100)
        return "\(tenths / 10).\(tenths % 10) s"
    }

    static func formatDollars(_ micro: Int64) -> String {
        let cents = Sat.div(Sat.add(max(0, micro), 5_000), 10_000)
        let remainder = cents % 100
        return "$\(cents / 100).\(remainder < 10 ? "0" : "")\(remainder)"
    }
}

/// Sequential request IDs (`r-1`, `r-2`, …) so scenario output is reproducible.
final class IDBox: @unchecked Sendable {
    // @unchecked Sendable: `value` is only touched under `lock`.
    private let lock = NSLock()
    private var value = 0
    private let prefix: String

    init(prefix: String = "r-") { self.prefix = prefix }

    func next() -> RequestID {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return RequestID("\(prefix)\(value)")
    }
}
