import XCTest
@testable import TokenQuota

enum Fixture {
    static let free = TierPolicy(burst: BucketLimit(capacity: 1_000, refillPerSecond: 10),
                                 dailyBudget: 2_500, maxSingleRequest: 800, outage: .failClosed)
    static let pro = TierPolicy(burst: BucketLimit(capacity: 5_000, refillPerSecond: 100),
                                dailyBudget: 50_000, maxSingleRequest: 4_000,
                                outage: .failOpenBounded(allowanceTokens: 1_500))
    static let price = PriceTable(inputMicroUSDPerMTok: 3_000_000, outputMicroUSDPerMTok: 15_000_000)

    static func configuration(orgLimit: Int64 = 1_000_000_000, velocityTrip: Int64? = nil,
                              holdTTL: Millis = Time.minute, claimedTTL: Millis = 10 * Time.minute,
                              maxHolds: Int = 100, retention: Millis = Time.hour, idempotency: Int = 1_000,
                              journal: Int = 100, attribute: AttributionDay = .callStart) -> LedgerConfiguration {
        LedgerConfiguration(policies: [.free: free, .pro: pro], price: price,
                            orgSpendLimitMicroUSD: orgLimit, orgVelocityTripMicroUSD: velocityTrip,
                            holdTTLMs: holdTTL, claimedHoldTTLMs: claimedTTL, maxOutstandingHolds: maxHolds,
                            idempotencyRetentionMs: retention, idempotencyCapacity: idempotency,
                            journalCapacity: journal, attributionRetentionDays: 3, attributeUsageTo: attribute)
    }

    static let alice = QuotaKey(userID: "alice", feature: "summarize", tier: .free)
    static let bob = QuotaKey(userID: "bob", feature: "summarize", tier: .pro)
    static let mallory = QuotaKey(userID: "mallory", feature: "summarize", tier: .pro)
    static let t0: Millis = 10 * Time.day + 12 * Time.hour

    static func est(_ input: Int64, _ output: Int64 = 0) -> Estimate { Estimate(inputTokens: input, maxOutputTokens: output) }
    static func use(_ input: Int64, _ output: Int64 = 0) -> Usage { Usage(inputTokens: input, outputTokens: output) }
}

final class LedgerReserveTests: XCTestCase {
    typealias F = Fixture

    func testGrantDebitsBurstAndDaily() {
        var ledger = QuotaLedger(configuration: F.configuration())
        let grant = ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(300, 100), now: F.t0).grant
        XCTAssertEqual(grant?.reservedTokens, 400)
        XCTAssertEqual(grant?.burstRemaining, 600)
        XCTAssertEqual(grant?.dailyRemaining, 2_100)
        XCTAssertEqual(ledger.dailyUsed(for: F.alice, now: F.t0), 400)
        XCTAssertEqual(ledger.outstandingHolds, 1)
        XCTAssertEqual(ledger.inFlight(for: F.alice), 1)
    }

    func testBurstDenialCarriesExactRetryAfter() {
        var ledger = QuotaLedger(configuration: F.configuration())
        _ = ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(800), now: F.t0)
        let denial = ledger.authorize(RequestID("b"), key: F.alice, apiKey: "k", estimate: F.est(500), now: F.t0).denial
        XCTAssertEqual(denial?.reason, .burstExhausted)
        XCTAssertEqual(denial?.retryAfterMs, 30_000)   // need 300 more at 10/s
        let later = ledger.authorize(RequestID("b"), key: F.alice, apiKey: "k", estimate: F.est(500), now: F.t0 + 30_000)
        XCTAssertNotNil(later.grant)
    }

    func testDailyDenialChangesNoCounterAndHoldsNoSpend() {
        // Daily has room for 2,500. Burst is refilled between calls, so the *daily* check fails first.
        var ledger = QuotaLedger(configuration: F.configuration())
        var now = F.t0
        for i in 0..<3 {
            _ = ledger.authorize(RequestID("r\(i)"), key: F.alice, apiKey: "k", estimate: F.est(800), now: now)
            now += 100_000
        }
        let heldBefore = ledger.breaker.heldMicroUSD
        let before = ledger.bucket(for: F.alice)
        let denial = ledger.authorize(RequestID("x"), key: F.alice, apiKey: "k", estimate: F.est(200), now: now).denial
        XCTAssertEqual(denial?.reason, .dailyBudgetExhausted)
        var expected = before
        expected?.refill(now: now)
        var after = ledger.bucket(for: F.alice)
        after?.refill(now: now)
        XCTAssertEqual(after?.levelMilli, expected?.levelMilli)
        XCTAssertEqual(ledger.dailyUsed(for: F.alice, now: now), 2_400)
        XCTAssertEqual(ledger.outstandingHolds, 3)
        XCTAssertEqual(ledger.breaker.heldMicroUSD, heldBefore, "a denial must not hold org spend")
    }

    func testBurstDenialChangesNoCounterAndHoldsNoSpend() {
        var ledger = QuotaLedger(configuration: F.configuration())
        _ = ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(800), now: F.t0)
        let heldBefore = ledger.breaker.heldMicroUSD
        XCTAssertEqual(ledger.authorize(RequestID("b"), key: F.alice, apiKey: "k", estimate: F.est(500), now: F.t0).denial?.reason,
                       .burstExhausted)
        XCTAssertEqual(ledger.dailyUsed(for: F.alice, now: F.t0), 800, "the daily reservation must not leak on a burst denial")
        XCTAssertEqual(ledger.breaker.heldMicroUSD, heldBefore)
    }

    func testDailyBudgetBoundaryIsInclusive() {
        var ledger = QuotaLedger(configuration: F.configuration())
        var now = F.t0
        for i in 0..<3 {
            _ = ledger.authorize(RequestID("r\(i)"), key: F.alice, apiKey: "k", estimate: F.est(800), now: now)
            now += 100_000
        }
        XCTAssertNotNil(ledger.authorize(RequestID("exact"), key: F.alice, apiKey: "k", estimate: F.est(100), now: now).grant,
                        "2,400 + 100 is exactly the 2,500 budget")
        XCTAssertEqual(ledger.authorize(RequestID("over"), key: F.alice, apiKey: "k", estimate: F.est(1), now: now + 100_000).denial?.reason,
                       .dailyBudgetExhausted)
    }

    func testDailyDenialRetriesAtUTCMidnight() {
        var ledger = QuotaLedger(configuration: F.configuration())
        var now = F.t0
        for i in 0..<3 {
            _ = ledger.authorize(RequestID("r\(i)"), key: F.alice, apiKey: "k", estimate: F.est(800), now: now)
            now += 100_000
        }
        let denial = ledger.authorize(RequestID("x"), key: F.alice, apiKey: "k", estimate: F.est(200), now: now).denial
        XCTAssertEqual(denial?.retryAfterMs, Time.startOfDay(11) - now)
        XCTAssertNotNil(ledger.authorize(RequestID("x"), key: F.alice, apiKey: "k", estimate: F.est(200),
                                         now: Time.startOfDay(11)).grant)
    }

    func testRetrySameIDReplaysWithoutSecondReservation() {
        var ledger = QuotaLedger(configuration: F.configuration())
        let first = ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(400), now: F.t0)
        let second = ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(400), now: F.t0 + 5)
        XCTAssertEqual(first, second)
        XCTAssertEqual(ledger.dailyUsed(for: F.alice, now: F.t0), 400)
        XCTAssertEqual(ledger.outstandingHolds, 1)
        XCTAssertEqual(ledger.stats.replays, 1)
        // Once settled the ID is spent: re-granting it could fund a second, uncharged model call.
        _ = ledger.settle(RequestID("a"), key: F.alice, apiKey: "k", usage: F.use(300), now: F.t0 + 10)
        XCTAssertEqual(ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(400), now: F.t0 + 20).denial?.reason,
                       .alreadySettled)
        XCTAssertEqual(ledger.dailyUsed(for: F.alice, now: F.t0), 300)
    }

    func testReplayRequiresTheSameRequest() {
        var ledger = QuotaLedger(configuration: F.configuration())
        let grant = ledger.authorize(RequestID("a"), key: F.bob, apiKey: "k-bob", estimate: F.est(400), now: F.t0).grant
        XCTAssertNotNil(grant)
        // Someone else presenting bob's ID does not get bob's grant…
        XCTAssertEqual(ledger.authorize(RequestID("a"), key: F.mallory, apiKey: "k-bob", estimate: F.est(400), now: F.t0).denial?.reason,
                       .requestIDReused)
        // …and neither does bob asking for more under the same ID.
        XCTAssertEqual(ledger.authorize(RequestID("a"), key: F.bob, apiKey: "k-bob", estimate: F.est(3_900), now: F.t0).denial?.reason,
                       .requestIDReused)
        XCTAssertEqual(ledger.outstandingHolds, 1)
        XCTAssertEqual(ledger.stats.requestIDReuses, 2)
        XCTAssertEqual(ledger.stats.replays, 0)
        // Still true once the request has finished.
        _ = ledger.settle(RequestID("a"), key: F.bob, apiKey: "k-bob", usage: F.use(400), now: F.t0)
        XCTAssertEqual(ledger.authorize(RequestID("a"), key: F.mallory, apiKey: "k-bob", estimate: F.est(400), now: F.t0).denial?.reason,
                       .requestIDReused)
    }

    func testExpiredIDIsReEvaluatedNotReplayed() {
        // The hold lapsed and was refunded; replaying its grant would let a call through with no reservation.
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute))
        _ = ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(400), now: F.t0)
        ledger.sweep(now: F.t0 + Time.minute)
        XCTAssertEqual(ledger.dailyUsed(for: F.alice, now: F.t0), 0)
        XCTAssertNotNil(ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(400), now: F.t0 + Time.minute).grant)
        XCTAssertEqual(ledger.dailyUsed(for: F.alice, now: F.t0), 400, "re-reserved, not replayed for free")
        XCTAssertEqual(ledger.outstandingHolds, 1)
        XCTAssertEqual(ledger.stats.replays, 0)
        XCTAssertEqual(ledger.settle(RequestID("a"), key: F.alice, apiKey: "k", usage: F.use(350), now: F.t0 + Time.minute),
                       .settled(charged: 350, adjustment: -50, persistence: .applied))
    }

    func testDeniedRequestsAreReEvaluatedNotReplayed() {
        var ledger = QuotaLedger(configuration: F.configuration())
        _ = ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(800), now: F.t0)
        XCTAssertNotNil(ledger.authorize(RequestID("b"), key: F.alice, apiKey: "k", estimate: F.est(800), now: F.t0).denial)
        XCTAssertNotNil(ledger.authorize(RequestID("b"), key: F.alice, apiKey: "k", estimate: F.est(800), now: F.t0 + 80_000).grant)
    }

    func testValidationDenials() {
        var ledger = QuotaLedger(configuration: F.configuration(maxHolds: 1))
        XCTAssertEqual(ledger.authorize(RequestID("n"), key: F.alice, apiKey: "k", estimate: F.est(-1, 5), now: F.t0).denial?.reason, .invalidEstimate)
        XCTAssertEqual(ledger.authorize(RequestID("z"), key: F.alice, apiKey: "k", estimate: F.est(0, 0), now: F.t0).denial?.reason, .invalidEstimate)
        let ent = QuotaKey(userID: "e", feature: "f", tier: .enterprise)
        XCTAssertEqual(ledger.authorize(RequestID("t"), key: ent, apiKey: "k", estimate: F.est(1), now: F.t0).denial?.reason, .unknownTier)
        XCTAssertEqual(ledger.authorize(RequestID("big"), key: F.alice, apiKey: "k", estimate: F.est(801), now: F.t0).denial?.reason, .requestTooLarge)
        XCTAssertEqual(ledger.authorize(RequestID("ovf"), key: F.alice, apiKey: "k", estimate: F.est(.max, .max), now: F.t0).denial?.reason, .requestTooLarge)
        XCTAssertNotNil(ledger.authorize(RequestID("1"), key: F.alice, apiKey: "k", estimate: F.est(10), now: F.t0).grant)
        XCTAssertEqual(ledger.authorize(RequestID("2"), key: F.bob, apiKey: "k", estimate: F.est(10), now: F.t0).denial?.reason, .tooManyInFlight)
        XCTAssertEqual(ledger.stats.totalDenied, 6)
    }

    func testEffectiveMaxNeverExceedsBucketOrDay() {
        let odd = TierPolicy(burst: BucketLimit(capacity: 100, refillPerSecond: 1), dailyBudget: 50,
                             maxSingleRequest: 10_000, outage: .failClosed)
        XCTAssertEqual(odd.effectiveMaxSingleRequest, 50)
    }

    func testPerKeyInFlightCapProtectsOtherTenants() {
        // One user opening tiny reservations must not lock everyone else out of the global table.
        var ledger = QuotaLedger(configuration: F.configuration(maxHolds: 100))
        for i in 0..<8 {
            XCTAssertNotNil(ledger.authorize(RequestID("b\(i)"), key: F.bob, apiKey: "k", estimate: F.est(1), now: F.t0).grant)
        }
        XCTAssertEqual(ledger.authorize(RequestID("b8"), key: F.bob, apiKey: "k", estimate: F.est(1), now: F.t0).denial?.reason,
                       .tooManyInFlight)
        XCTAssertNotNil(ledger.authorize(RequestID("a0"), key: F.alice, apiKey: "k", estimate: F.est(1), now: F.t0).grant)
        _ = ledger.settle(RequestID("b0"), key: F.bob, apiKey: "k", usage: F.use(1), now: F.t0)
        XCTAssertEqual(ledger.inFlight(for: F.bob), 7)
        XCTAssertNotNil(ledger.authorize(RequestID("b8"), key: F.bob, apiKey: "k", estimate: F.est(1), now: F.t0).grant)
    }

    func testGlobalCapExpiresStaleHoldsLazily() {
        // Nobody called sweep(): the cap itself must clear expired holds before refusing.
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute, maxHolds: 2))
        _ = ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(10), now: F.t0)
        _ = ledger.authorize(RequestID("b"), key: F.bob, apiKey: "k", estimate: F.est(10), now: F.t0)
        let carol = QuotaKey(userID: "carol", feature: "summarize", tier: .pro)
        XCTAssertEqual(ledger.authorize(RequestID("c"), key: carol, apiKey: "k", estimate: F.est(10), now: F.t0 + 1).denial?.reason,
                       .tooManyInFlight)
        XCTAssertNotNil(ledger.authorize(RequestID("c"), key: carol, apiKey: "k", estimate: F.est(10), now: F.t0 + Time.minute).grant)
        XCTAssertEqual(ledger.outstandingHolds, 1)
        XCTAssertEqual(ledger.stats.expiredHolds, 2)
        XCTAssertEqual(ledger.breaker.heldMicroUSD, 30, "only carol's hold is still held")
    }
}

final class LedgerClaimTests: XCTestCase {
    typealias F = Fixture

    func testClaimIsSingleUse() {
        var ledger = QuotaLedger(configuration: F.configuration())
        XCTAssertEqual(ledger.claim(RequestID("a"), key: F.bob, apiKey: "k", now: F.t0), .noHold)
        let grant = ledger.authorize(RequestID("a"), key: F.bob, apiKey: "k", estimate: F.est(400), now: F.t0).grant
        XCTAssertNotNil(grant)
        XCTAssertEqual(ledger.claim(RequestID("a"), key: F.bob, apiKey: "k", now: F.t0), grant.map(ClaimResult.claimed))
        XCTAssertEqual(ledger.claim(RequestID("a"), key: F.bob, apiKey: "k", now: F.t0), .alreadyClaimed)
        // A retried authorize still replays the same grant, but it cannot be claimed again.
        XCTAssertEqual(ledger.authorize(RequestID("a"), key: F.bob, apiKey: "k", estimate: F.est(400), now: F.t0).grant, grant)
        XCTAssertEqual(ledger.claim(RequestID("a"), key: F.bob, apiKey: "k", now: F.t0), .alreadyClaimed)
        _ = ledger.settle(RequestID("a"), key: F.bob, apiKey: "k", usage: F.use(400), now: F.t0)
        XCTAssertEqual(ledger.claim(RequestID("a"), key: F.bob, apiKey: "k", now: F.t0), .alreadySettled)
        XCTAssertEqual(ledger.stats.claims, 1)
        XCTAssertEqual(ledger.stats.duplicateClaims, 2)
    }

    func testUnclaimedHoldExpiresFastButARunningCallKeepsItsHold() {
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute, claimedTTL: 10 * Time.minute))
        _ = ledger.authorize(RequestID("idle"), key: F.bob, apiKey: "k", estimate: F.est(100), now: F.t0)
        _ = ledger.authorize(RequestID("running"), key: F.bob, apiKey: "k", estimate: F.est(100), now: F.t0)
        _ = ledger.claim(RequestID("running"), key: F.bob, apiKey: "k", now: F.t0 + 30 * Time.second)
        ledger.sweep(now: F.t0 + Time.minute)
        XCTAssertEqual(ledger.outstandingHolds, 1, "the never-claimed hold is refunded; the running call is not")
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: F.t0), 100)
    }

    func testHoldThatExpiresMidCallKeepsItsChargeAndItsIDStaysSpent() {
        // A sequence adversarial review found: claim → claimed TTL passes → re-authorise → claim again
        // would have bought two model calls and one charge.
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute, claimedTTL: 10 * Time.minute))
        _ = ledger.authorize(RequestID("x"), key: F.bob, apiKey: "k", estimate: F.est(800), now: F.t0)
        XCTAssertNotNil(ledger.claim(RequestID("x"), key: F.bob, apiKey: "k", now: F.t0))
        ledger.sweep(now: F.t0 + 10 * Time.minute)
        XCTAssertEqual(ledger.outstandingHolds, 0)
        XCTAssertEqual(ledger.stats.expiredMidCall, 1)
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: F.t0), 800, "the reservation stays as a provisional charge")
        XCTAssertEqual(ledger.breaker.spentMicroUSD, 2_400, "and so does its estimated cost")
        XCTAssertEqual(ledger.breaker.heldMicroUSD, 0, "moved from held to spent, not both")
        XCTAssertEqual(ledger.authorize(RequestID("x"), key: F.bob, apiKey: "k", estimate: F.est(800), now: F.t0 + 10 * Time.minute).denial?.reason,
                       .alreadyClaimed)
        XCTAssertEqual(ledger.claim(RequestID("x"), key: F.bob, apiKey: "k", now: F.t0 + 10 * Time.minute), .alreadyClaimed)
        XCTAssertEqual(ledger.stats.claims, 1)
        // The late settlement trues it up: 900 actual against the 800 kept.
        XCTAssertEqual(ledger.settle(RequestID("x"), key: F.bob, apiKey: "k", usage: F.use(900), now: F.t0 + 11 * Time.minute),
                       .lateSettled(charged: 900, persistence: .applied))
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: F.t0), 900)
        XCTAssertEqual(ledger.attribution[AttributionKey(apiKey: "k", dayIndex: 10)], 900)
        XCTAssertEqual(ledger.breaker.spentMicroUSD, 2_700)
        XCTAssertEqual(ledger.settle(RequestID("x"), key: F.bob, apiKey: "k", usage: F.use(900), now: F.t0 + 11 * Time.minute), .duplicate)
    }
}

final class LedgerSettleTests: XCTestCase {
    typealias F = Fixture

    func testSettleRefundsUnusedReservation() {
        var ledger = QuotaLedger(configuration: F.configuration())
        _ = ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(300, 500), now: F.t0)
        let outcome = ledger.settle(RequestID("a"), key: F.alice, apiKey: "k", usage: F.use(300, 120), now: F.t0)
        XCTAssertEqual(outcome, .settled(charged: 420, adjustment: -380, persistence: .applied))
        XCTAssertEqual(ledger.dailyUsed(for: F.alice, now: F.t0), 420)
        XCTAssertEqual(ledger.bucket(for: F.alice)?.availableTokens, 580)
        XCTAssertEqual(ledger.outstandingHolds, 0)
        XCTAssertEqual(ledger.inFlight(for: F.alice), 0)
        XCTAssertEqual(ledger.keysInFlight, 0, "a key with no open holds leaves no entry behind")
        XCTAssertEqual(ledger.breaker.heldMicroUSD, 0, "settling releases the held org spend")
        XCTAssertEqual(ledger.attribution[AttributionKey(apiKey: "k", dayIndex: 10)], 420)
    }

    func testOverageCreatesBoundedDebt() {
        var ledger = QuotaLedger(configuration: F.configuration())
        _ = ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(800), now: F.t0)
        _ = ledger.settle(RequestID("a"), key: F.alice, apiKey: "k", usage: F.use(5_000), now: F.t0)
        XCTAssertEqual(ledger.bucket(for: F.alice)?.availableTokens, -1_000, "debt is floored at one bucket")
        XCTAssertEqual(ledger.dailyUsed(for: F.alice, now: F.t0), 5_000, "the daily counter keeps the real usage")
    }

    func testDuplicateSettleChargesOnce() {
        var ledger = QuotaLedger(configuration: F.configuration())
        _ = ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(400), now: F.t0)
        _ = ledger.settle(RequestID("a"), key: F.alice, apiKey: "k", usage: F.use(400), now: F.t0)
        XCTAssertEqual(ledger.settle(RequestID("a"), key: F.alice, apiKey: "k", usage: F.use(400), now: F.t0), .duplicate)
        XCTAssertEqual(ledger.dailyUsed(for: F.alice, now: F.t0), 400)
        XCTAssertEqual(ledger.attribution[AttributionKey(apiKey: "k", dayIndex: 10)], 400)
    }

    func testExpiredHoldIsRefundedThenLateSettleChargesInFullOnce() {
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute))
        _ = ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(600), now: F.t0)
        ledger.sweep(now: F.t0 + Time.minute)
        XCTAssertEqual(ledger.outstandingHolds, 0)
        XCTAssertEqual(ledger.breaker.heldMicroUSD, 0, "expiry releases the held org spend")
        XCTAssertEqual(ledger.dailyUsed(for: F.alice, now: F.t0), 0, "expired hold refunded")
        XCTAssertEqual(ledger.stats.expiredHolds, 1)
        let late = ledger.settle(RequestID("a"), key: F.alice, apiKey: "k", usage: F.use(450), now: F.t0 + 2 * Time.minute)
        XCTAssertEqual(late, .lateSettled(charged: 450, persistence: .applied))
        XCTAssertEqual(ledger.dailyUsed(for: F.alice, now: F.t0), 450)
        XCTAssertEqual(ledger.settle(RequestID("a"), key: F.alice, apiKey: "k", usage: F.use(450), now: F.t0), .duplicate)
        XCTAssertEqual(ledger.dailyUsed(for: F.alice, now: F.t0), 450)
    }

    func testUnknownSettleChargesInsteadOfLosingUsage() {
        var ledger = QuotaLedger(configuration: F.configuration())
        let outcome = ledger.settle(RequestID("ghost"), key: F.alice, apiKey: "k", usage: F.use(250), now: F.t0)
        XCTAssertEqual(outcome, .unknownSettled(charged: 250, persistence: .applied))
        XCTAssertEqual(ledger.dailyUsed(for: F.alice, now: F.t0), 250)
        XCTAssertEqual(ledger.authorize(RequestID("ghost"), key: F.alice, apiKey: "k", estimate: F.est(1), now: F.t0).denial?.reason,
                       .alreadySettled)
    }

    func testSettlementChargesTheReservationsOwnerNotTheCaller() {
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute))
        _ = ledger.authorize(RequestID("a"), key: F.bob, apiKey: "k-bob", estimate: F.est(400), now: F.t0)
        _ = ledger.settle(RequestID("a"), key: F.mallory, apiKey: "k-mallory", usage: F.use(300), now: F.t0)
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: F.t0), 300)
        XCTAssertEqual(ledger.dailyUsed(for: F.mallory, now: F.t0), 0)
        XCTAssertNil(ledger.attribution[AttributionKey(apiKey: "k-mallory", dayIndex: 10)])
        // The same holds for a late settlement of an expired reservation.
        _ = ledger.authorize(RequestID("b"), key: F.bob, apiKey: "k-bob", estimate: F.est(400), now: F.t0)
        ledger.sweep(now: F.t0 + Time.minute)
        _ = ledger.settle(RequestID("b"), key: F.mallory, apiKey: "k-mallory", usage: F.use(200), now: F.t0 + Time.minute)
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: F.t0), 500)
        XCTAssertEqual(ledger.dailyUsed(for: F.mallory, now: F.t0), 0)
    }

    func testIdempotencyIsRetainedByTimeAndEarlyEvictionsAreCounted() {
        var roomy = QuotaLedger(configuration: F.configuration(retention: 10 * Time.minute, idempotency: 1_000))
        _ = roomy.authorize(RequestID("a"), key: F.bob, apiKey: "k", estimate: F.est(100), now: F.t0)
        _ = roomy.settle(RequestID("a"), key: F.bob, apiKey: "k", usage: F.use(100), now: F.t0)
        roomy.sweep(now: F.t0 + 10 * Time.minute - 1)
        XCTAssertEqual(roomy.settle(RequestID("a"), key: F.bob, apiKey: "k", usage: F.use(100), now: F.t0), .duplicate)
        roomy.sweep(now: F.t0 + 10 * Time.minute)
        XCTAssertEqual(roomy.rememberedRequests, 0, "forgotten once retention ends: memory is bounded by time")
        XCTAssertEqual(roomy.stats.idempotencyEvictions, 0)

        var tight = QuotaLedger(configuration: F.configuration(retention: 10 * Time.minute, idempotency: 2))
        for id in ["a", "b", "c"] {
            _ = tight.authorize(RequestID(id), key: F.bob, apiKey: "k", estimate: F.est(100), now: F.t0)
            _ = tight.settle(RequestID(id), key: F.bob, apiKey: "k", usage: F.use(100), now: F.t0)
        }
        XCTAssertEqual(tight.rememberedRequests, 2)
        XCTAssertEqual(tight.stats.idempotencyEvictions, 1, "the capacity cap forgot an ID before its retention ended")
        // "a" was forgotten early: a duplicate now is charged again (fail toward counting) — reconciliation catches it.
        XCTAssertEqual(tight.settle(RequestID("a"), key: F.bob, apiKey: "k", usage: F.use(100), now: F.t0),
                       .unknownSettled(charged: 100, persistence: .applied))
        XCTAssertEqual(tight.settle(RequestID("c"), key: F.bob, apiKey: "k", usage: F.use(100), now: F.t0), .duplicate)
    }

    func testAnUpdatedRecordIsNeitherAPurgeBlockerNorTheFirstEviction() {
        // The common mobile path: a hold expires while the app is backgrounded, the same ID is
        // re-authorised and settled. That record is now the freshest one and must be treated so.
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute, retention: 10 * Time.minute, idempotency: 3))
        _ = ledger.authorize(RequestID("x"), key: F.bob, apiKey: "k", estimate: F.est(100), now: F.t0)
        ledger.sweep(now: F.t0 + Time.minute)                                   // x: expiredUnclaimed
        for id in ["a", "b"] {
            _ = ledger.authorize(RequestID(id), key: F.bob, apiKey: "k", estimate: F.est(100), now: F.t0 + 2 * Time.minute)
            _ = ledger.settle(RequestID(id), key: F.bob, apiKey: "k", usage: F.use(100), now: F.t0 + 2 * Time.minute)
        }
        _ = ledger.authorize(RequestID("x"), key: F.bob, apiKey: "k", estimate: F.est(100), now: F.t0 + 3 * Time.minute)
        _ = ledger.settle(RequestID("x"), key: F.bob, apiKey: "k", usage: F.use(100), now: F.t0 + 3 * Time.minute)
        _ = ledger.authorize(RequestID("c"), key: F.bob, apiKey: "k", estimate: F.est(100), now: F.t0 + 4 * Time.minute)
        _ = ledger.settle(RequestID("c"), key: F.bob, apiKey: "k", usage: F.use(100), now: F.t0 + 4 * Time.minute)
        XCTAssertEqual(ledger.stats.idempotencyEvictions, 1, "capacity evicted the oldest record, \"a\"")
        XCTAssertEqual(ledger.settle(RequestID("x"), key: F.bob, apiKey: "k", usage: F.use(100), now: F.t0 + 4 * Time.minute), .duplicate,
                       "x was settled a minute ago: it must still be remembered")
        ledger.sweep(now: F.t0 + 12 * Time.minute)
        XCTAssertEqual(ledger.rememberedRequests, 2, "b expired by time; x and c are still inside retention")
    }

    func testCapacityEvictionsCountOnlyIDsStillInsideRetention() {
        var ledger = QuotaLedger(configuration: F.configuration(retention: Time.minute, idempotency: 2))
        for id in ["a", "b"] {
            _ = ledger.authorize(RequestID(id), key: F.bob, apiKey: "k", estimate: F.est(100), now: F.t0)
            _ = ledger.settle(RequestID(id), key: F.bob, apiKey: "k", usage: F.use(100), now: F.t0)
        }
        _ = ledger.authorize(RequestID("c"), key: F.bob, apiKey: "k", estimate: F.est(100), now: F.t0 + 2 * Time.minute)
        _ = ledger.settle(RequestID("c"), key: F.bob, apiKey: "k", usage: F.use(100), now: F.t0 + 2 * Time.minute)
        XCTAssertEqual(ledger.stats.idempotencyEvictions, 0, "a and b were past retention: purged, not evicted")
        XCTAssertEqual(ledger.rememberedRequests, 1)
    }

    func testInvalidUsageIsRejected() {
        var ledger = QuotaLedger(configuration: F.configuration())
        XCTAssertEqual(ledger.settle(RequestID("a"), key: F.alice, apiKey: "k", usage: F.use(-1), now: F.t0), .invalidUsage)
        XCTAssertEqual(ledger.stats.settled, 0)
    }

    func testAttributionDayFollowsConfigurationAndTheClosedWindowIsLeftAlone() {
        let lateEvening = Time.startOfDay(11) - 1_000
        for (mode, expectedDay) in [(AttributionDay.callStart, Int64(10)), (.settlement, 11)] {
            var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.hour, attribute: mode))
            _ = ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(500), now: lateEvening)
            _ = ledger.claim(RequestID("a"), key: F.alice, apiKey: "k", now: lateEvening)
            _ = ledger.settle(RequestID("a"), key: F.alice, apiKey: "k", usage: F.use(900), now: Time.startOfDay(11) + 1_000)
            XCTAssertEqual(ledger.attribution[AttributionKey(apiKey: "k", dayIndex: expectedDay)], 900, "\(mode)")
            // The +400 overage belongs to yesterday's (closed) window, not to today's budget.
            XCTAssertEqual(ledger.dailyUsed(for: F.alice, now: Time.startOfDay(11) + 1_000), 0, "\(mode)")
        }
    }
}

final class LedgerOutageTests: XCTestCase {
    typealias F = Fixture

    func testFreeFailsClosedProFailsOpenWithinAllowance() {
        var ledger = QuotaLedger(configuration: F.configuration())
        ledger.setStoreAvailable(false, now: F.t0)
        XCTAssertEqual(ledger.authorize(RequestID("f"), key: F.alice, apiKey: "k", estimate: F.est(10), now: F.t0).denial?.reason, .storeUnavailable)
        let g1 = ledger.authorize(RequestID("p1"), key: F.bob, apiKey: "k", estimate: F.est(1_000), now: F.t0).grant
        XCTAssertEqual(g1?.degraded, true)
        XCTAssertEqual(g1?.dailyRemaining, 500)
        XCTAssertEqual(ledger.authorize(RequestID("p2"), key: F.bob, apiKey: "k", estimate: F.est(600), now: F.t0).denial?.reason, .outageAllowanceExhausted)
        XCTAssertNotNil(ledger.authorize(RequestID("p3"), key: F.bob, apiKey: "k", estimate: F.est(500), now: F.t0).grant)
        XCTAssertEqual(ledger.stats.degradedGrants, 2)
        XCTAssertEqual(ledger.breaker.heldMicroUSD, 4_500, "outage grants hold org spend like any other")
    }

    func testOutageSettlementsAreJournaledAndReplayedInFull() {
        var ledger = QuotaLedger(configuration: F.configuration())
        ledger.setStoreAvailable(false, now: F.t0)
        _ = ledger.authorize(RequestID("p1"), key: F.bob, apiKey: "k", estimate: F.est(1_000), now: F.t0)
        XCTAssertEqual(ledger.settle(RequestID("p1"), key: F.bob, apiKey: "k", usage: F.use(1_200), now: F.t0),
                       .settled(charged: 1_200, adjustment: 1_200, persistence: .journaled))
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: F.t0), 0, "nothing written while down")
        XCTAssertEqual(ledger.journalCount, 1)
        XCTAssertEqual(ledger.setStoreAvailable(true, now: F.t0 + 1_000), 1)
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: F.t0), 1_200)
        XCTAssertEqual(ledger.attribution[AttributionKey(apiKey: "k", dayIndex: 10)], 1_200)
        XCTAssertEqual(ledger.journalCount, 0)
        // A new outage starts with a fresh allowance.
        ledger.setStoreAvailable(false, now: F.t0 + 2_000)
        XCTAssertNotNil(ledger.authorize(RequestID("p9"), key: F.bob, apiKey: "k", estimate: F.est(1_500), now: F.t0 + 2_000).grant)
    }

    func testHoldTakenBeforeOutageSettledDuringItReplaysTheDelta() {
        var ledger = QuotaLedger(configuration: F.configuration())
        _ = ledger.authorize(RequestID("a"), key: F.bob, apiKey: "k", estimate: F.est(1_000), now: F.t0)
        ledger.setStoreAvailable(false, now: F.t0)
        XCTAssertEqual(ledger.settle(RequestID("a"), key: F.bob, apiKey: "k", usage: F.use(700), now: F.t0),
                       .settled(charged: 700, adjustment: -300, persistence: .journaled))
        ledger.setStoreAvailable(true, now: F.t0)
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: F.t0), 700)
    }

    func testJournalOverflowIsReportedAsDroppedAndShowsUpInReconciliation() {
        var ledger = QuotaLedger(configuration: F.configuration(journal: 1))
        ledger.setStoreAvailable(false, now: F.t0)
        var outcomes: [SettleOutcome] = []
        for id in ["a", "b"] {
            _ = ledger.authorize(RequestID(id), key: F.bob, apiKey: "k", estimate: F.est(500), now: F.t0)
            outcomes.append(ledger.settle(RequestID(id), key: F.bob, apiKey: "k", usage: F.use(500), now: F.t0))
        }
        XCTAssertEqual(outcomes, [.settled(charged: 500, adjustment: 500, persistence: .journaled),
                                  .settled(charged: 500, adjustment: 500, persistence: .dropped)])
        XCTAssertEqual(ledger.stats.journalDroppedEntries, 1)
        XCTAssertEqual(ledger.stats.journalDroppedTokens, 500)
        ledger.setStoreAvailable(true, now: F.t0)
        let findings = Reconciler.reconcile(ledger: ledger.attribution,
                                            report: [AnalyticsRow(apiKey: "k", dayIndex: 10, tokens: 1_000)],
                                            now: F.t0 + 3 * Time.day)
        XCTAssertEqual(findings.first?.status, .ledgerUnder(500))
    }

    func testRefundsWaitForTheStoreInsteadOfEnteringTheJournal() {
        // A zero-capacity journal: any refund that went through it would be lost and over-charge bob.
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute, journal: 0))
        _ = ledger.authorize(RequestID("a"), key: F.bob, apiKey: "k", estimate: F.est(800), now: F.t0)
        ledger.setStoreAvailable(false, now: F.t0 + 1)
        ledger.sweep(now: F.t0 + 2 * Time.minute)
        XCTAssertEqual(ledger.outstandingHolds, 0, "the hold's slots are freed now")
        XCTAssertEqual(ledger.pendingRefundCount, 1, "its refund waits for the store")
        XCTAssertEqual(ledger.journalCount, 0)
        XCTAssertEqual(ledger.stats.journalDroppedEntries, 0)
        ledger.setStoreAvailable(true, now: F.t0 + 3 * Time.minute)
        XCTAssertEqual(ledger.pendingRefundCount, 0)
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: F.t0), 0, "refunded once the store was back")
    }

    func testDegradedHoldExpiryReturnsAllowance() {
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute))
        ledger.setStoreAvailable(false, now: F.t0)
        _ = ledger.authorize(RequestID("a"), key: F.bob, apiKey: "k", estimate: F.est(1_500), now: F.t0)
        XCTAssertNotNil(ledger.authorize(RequestID("b"), key: F.bob, apiKey: "k", estimate: F.est(1), now: F.t0).denial)
        ledger.sweep(now: F.t0 + Time.minute)
        XCTAssertEqual(ledger.breaker.heldMicroUSD, 0)
        XCTAssertNotNil(ledger.authorize(RequestID("c"), key: F.bob, apiKey: "k", estimate: F.est(1_500), now: F.t0 + Time.minute).grant)
    }

    func testOutageAllowanceIsPerOutage() {
        // A degraded hold from outage 1 expiring during outage 2 must not refund outage 2's allowance.
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute))
        ledger.setStoreAvailable(false, now: F.t0)
        XCTAssertNotNil(ledger.authorize(RequestID("a"), key: F.bob, apiKey: "k", estimate: F.est(1_500), now: F.t0).grant)
        ledger.setStoreAvailable(true, now: F.t0 + 10 * Time.second)
        ledger.setStoreAvailable(false, now: F.t0 + 20 * Time.second)
        XCTAssertNotNil(ledger.authorize(RequestID("b"), key: F.bob, apiKey: "k", estimate: F.est(1_500), now: F.t0 + 20 * Time.second).grant)
        ledger.sweep(now: F.t0 + 61 * Time.second)   // only "a" (outage 1) is due
        XCTAssertEqual(ledger.outstandingHolds, 1)
        XCTAssertEqual(ledger.authorize(RequestID("c"), key: F.bob, apiKey: "k", estimate: F.est(1), now: F.t0 + 61 * Time.second).denial?.reason,
                       .outageAllowanceExhausted)
    }
}

final class LedgerSpendAndSweepTests: XCTestCase {
    typealias F = Fixture

    func testHoldDrivenOrgDenialGetsAShortRetry() {
        // 1,000 input tokens ≈ $0.003 → limit $0.01 admits three honest estimates.
        var ledger = QuotaLedger(configuration: F.configuration(orgLimit: 10_000))
        for i in 0..<3 {
            XCTAssertNotNil(ledger.authorize(RequestID("h\(i)"), key: F.bob, apiKey: "k", estimate: F.est(1_000), now: F.t0).grant)
        }
        let denial = ledger.authorize(RequestID("h3"), key: F.bob, apiKey: "k", estimate: F.est(1_000), now: F.t0).denial
        XCTAssertEqual(denial?.reason, .orgBudgetWouldExceed)
        XCTAssertEqual(denial?.retryAfterMs, 5 * Time.second, "only in-flight holds are in the way")
        for i in 0..<3 { _ = ledger.settle(RequestID("h\(i)"), key: F.bob, apiKey: "k", usage: F.use(500), now: F.t0) }
        XCTAssertNotNil(ledger.authorize(RequestID("h3"), key: F.bob, apiKey: "k", estimate: F.est(1_000), now: F.t0).grant)
    }

    func testOverspendTripsTheBreakerAndOnlyAnOverrideRestoresService() {
        var ledger = QuotaLedger(configuration: F.configuration(orgLimit: 10_000))
        let now = F.t0
        for i in 0..<3 { _ = ledger.authorize(RequestID("h\(i)"), key: F.bob, apiKey: "k", estimate: F.est(1_000), now: now) }
        // Estimates lied: each actually used 1,200 tokens → $0.0108 actual > cap → breaker opens.
        for i in 0..<3 { _ = ledger.settle(RequestID("h\(i)"), key: F.bob, apiKey: "k", usage: F.use(1_200), now: now) }
        XCTAssertEqual(ledger.breaker.lastTrip, .overspend)
        let open = ledger.authorize(RequestID("tiny"), key: F.bob, apiKey: "k", estimate: F.est(1), now: now).denial
        XCTAssertEqual(open?.reason, .orgSpendBreakerOpen)
        XCTAssertEqual(open?.retryAfterMs, 15 * Time.minute)
        ledger.resetBreaker(now: now)
        let capped = ledger.authorize(RequestID("tiny"), key: F.bob, apiKey: "k", estimate: F.est(1), now: now).denial
        XCTAssertEqual(capped?.reason, .orgBudgetWouldExceed, "a reset alone does not raise the cap")
        XCTAssertEqual(capped?.retryAfterMs, ledger.breaker.windowEnd - now)
        ledger.resetBreaker(overrideMicroUSD: 4_000, now: now)
        XCTAssertNotNil(ledger.authorize(RequestID("tiny"), key: F.bob, apiKey: "k", estimate: F.est(1), now: now).grant,
                        "with headroom from an on-call override, service resumes")
    }

    func testVelocityBreakerStopsASpikeFarBelowTheCap() {
        var ledger = QuotaLedger(configuration: F.configuration(orgLimit: 1_000_000_000, velocityTrip: 5_000))
        var now = F.t0
        for i in 0..<2 {
            _ = ledger.authorize(RequestID("s\(i)"), key: F.bob, apiKey: "k", estimate: F.est(1_000), now: now)
            _ = ledger.settle(RequestID("s\(i)"), key: F.bob, apiKey: "k", usage: F.use(1_000), now: now)
            now += Time.second
        }
        XCTAssertEqual(ledger.breaker.lastTrip, .velocity)
        XCTAssertEqual(ledger.authorize(RequestID("s2"), key: F.bob, apiKey: "k", estimate: F.est(1), now: now).denial?.reason,
                       .orgSpendBreakerOpen)
        XCTAssertNotNil(ledger.authorize(RequestID("s2"), key: F.bob, apiKey: "k", estimate: F.est(1), now: now + 15 * Time.minute).grant,
                        "it closes on its own after the cooldown")
    }

    func testSweepCollectsFreshStateButKeepsAnythingThatMatters() {
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.hour))
        _ = ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(100), now: F.t0)
        _ = ledger.settle(RequestID("a"), key: F.alice, apiKey: "k", usage: F.use(100), now: F.t0)
        _ = ledger.authorize(RequestID("b"), key: F.bob, apiKey: "k", estimate: F.est(100), now: F.t0)
        ledger.sweep(now: F.t0 + Time.minute)
        XCTAssertEqual(ledger.trackedKeys, 2, "both keys used tokens today")
        _ = ledger.settle(RequestID("b"), key: F.bob, apiKey: "k", usage: F.use(100), now: F.t0)
        ledger.sweep(now: Time.startOfDay(11) + Time.hour)
        XCTAssertEqual(ledger.trackedKeys, 0, "next day, refilled: equivalent to fresh, so dropped")
        ledger.sweep(now: Time.startOfDay(14))
        XCTAssertNil(ledger.attribution[AttributionKey(apiKey: "k", dayIndex: 10)], "past the 3-day retention")
    }

    func testCollectedKeyBehavesExactlyLikeANewOne() {
        var ledger = QuotaLedger(configuration: F.configuration())
        _ = ledger.authorize(RequestID("a"), key: F.alice, apiKey: "k", estimate: F.est(800), now: F.t0)
        _ = ledger.settle(RequestID("a"), key: F.alice, apiKey: "k", usage: F.use(800), now: F.t0)
        ledger.sweep(now: Time.startOfDay(12))
        XCTAssertEqual(ledger.trackedKeys, 0, "the sweep really collected it")
        XCTAssertEqual(ledger.authorize(RequestID("b"), key: F.alice, apiKey: "k", estimate: F.est(800), now: Time.startOfDay(12)).grant?.burstRemaining, 200)
    }
}
