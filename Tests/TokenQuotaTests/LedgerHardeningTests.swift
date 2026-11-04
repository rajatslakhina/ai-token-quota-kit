import XCTest
@testable import TokenQuota

/// Regression tests for failure paths found by adversarial review: each one was first reproduced
/// with a probe against an earlier version of the ledger.
final class LedgerHardeningTests: XCTestCase {
    typealias F = Fixture

    // MARK: Outages and the hold caps

    func testAbandonedPreOutageHoldsFreeTheirSlotsDuringTheOutage() {
        // Eight abandoned holds from before the outage must not turn bob's fail-open tier into fail-closed.
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute))
        for i in 0..<8 {
            XCTAssertNotNil(ledger.authorize(RequestID("old\(i)"), key: F.bob, apiKey: "k", estimate: F.est(1), now: F.t0).grant)
        }
        ledger.setStoreAvailable(false, now: F.t0 + 1)
        let during = F.t0 + Time.minute + 1
        let grant = ledger.authorize(RequestID("new"), key: F.bob, apiKey: "k", estimate: F.est(100), now: during).grant
        XCTAssertEqual(grant?.degraded, true, "the per-key cap expired bob's own stale holds, lazily")
        XCTAssertEqual(ledger.inFlight(for: F.bob), 1)
        XCTAssertEqual(ledger.pendingRefundCount, 8, "the refunds wait for the store, off the hold tables")
        XCTAssertEqual(ledger.journalCount, 0, "and never enter the journal")
        ledger.setStoreAvailable(true, now: during + 1)
        XCTAssertEqual(ledger.pendingRefundCount, 0)
        XCTAssertEqual(ledger.stats.refundsReplayed, 8)
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: during + 1), 0, "all eight reservations refunded")
    }

    func testAbandonedHoldsDoNotLockOtherTenantsOutOfTheGlobalTable() {
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute, maxHolds: 2))
        _ = ledger.authorize(RequestID("a"), key: F.bob, apiKey: "k", estimate: F.est(10), now: F.t0)
        _ = ledger.authorize(RequestID("b"), key: F.mallory, apiKey: "k", estimate: F.est(10), now: F.t0)
        ledger.setStoreAvailable(false, now: F.t0 + 1)
        let carol = QuotaKey(userID: "carol", feature: "summarize", tier: .pro)
        let grant = ledger.authorize(RequestID("c"), key: carol, apiKey: "k", estimate: F.est(10), now: F.t0 + 30 * Time.minute).grant
        XCTAssertEqual(grant?.degraded, true)
        XCTAssertEqual(ledger.pendingRefundCount, 2)
    }

    func testOversizedRequestDuringAnOutageIsRefusedPermanently() {
        // 2,000 tokens fits the tier (4,000) but not the whole 1,500-token outage allowance: retrying
        // every few seconds for the length of the outage can never succeed.
        var ledger = QuotaLedger(configuration: F.configuration())
        ledger.setStoreAvailable(false, now: F.t0)
        let denial = ledger.authorize(RequestID("big"), key: F.bob, apiKey: "k", estimate: F.est(2_000), now: F.t0).denial
        XCTAssertEqual(denial?.reason, .exceedsOutageAllowance)
        XCTAssertEqual(denial?.reason.isTransient, false)
    }

    // MARK: Mid-call expiry

    func testMidCallExpiryOfAnOutageGrantStillCharges() {
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute, claimedTTL: 10 * Time.minute))
        ledger.setStoreAvailable(false, now: F.t0)
        _ = ledger.authorize(RequestID("d"), key: F.bob, apiKey: "k", estimate: F.est(1_000), now: F.t0)
        _ = ledger.claim(RequestID("d"), key: F.bob, apiKey: "k", now: F.t0)
        ledger.sweep(now: F.t0 + 10 * Time.minute)
        XCTAssertEqual(ledger.journalCount, 1, "the provisional charge is written (journaled: the store is down)")
        ledger.setStoreAvailable(true, now: F.t0 + 11 * Time.minute)
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: F.t0), 1_000, "an outage grant that outlived its TTL is not free")
        XCTAssertEqual(ledger.settle(RequestID("d"), key: F.bob, apiKey: "k", usage: F.use(600), now: F.t0 + 12 * Time.minute),
                       .lateSettled(charged: 600, persistence: .applied))
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: F.t0), 600, "the late settle refunds the 400 it didn't use")
    }

    func testALateSettleAfterTheIdempotencyWindowIsStillNotChargedTwice() {
        // Mid-call expiries live in their own map with a longer retention than ordinary records.
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute, claimedTTL: 10 * Time.minute,
                                                                retention: 10 * Time.minute))
        _ = ledger.authorize(RequestID("s"), key: F.bob, apiKey: "k", estimate: F.est(800), now: F.t0)
        _ = ledger.claim(RequestID("s"), key: F.bob, apiKey: "k", now: F.t0)
        ledger.sweep(now: F.t0 + 10 * Time.minute)
        ledger.sweep(now: F.t0 + 40 * Time.minute)   // well past the 10-minute idempotency retention
        XCTAssertEqual(ledger.rememberedMidCallExpiries, 1)
        XCTAssertEqual(ledger.settle(RequestID("s"), key: F.bob, apiKey: "k", usage: F.use(900), now: F.t0 + 40 * Time.minute),
                       .lateSettled(charged: 900, persistence: .applied))
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: F.t0), 900, "900, not 800 + 900")
        XCTAssertEqual(ledger.rememberedMidCallExpiries, 0)
    }

    func testLateSettleBelowTheProvisionalChargeRefundsTheDifference() {
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute, claimedTTL: 10 * Time.minute))
        _ = ledger.authorize(RequestID("x"), key: F.bob, apiKey: "k", estimate: F.est(800), now: F.t0)
        _ = ledger.claim(RequestID("x"), key: F.bob, apiKey: "k", now: F.t0)
        ledger.sweep(now: F.t0 + 10 * Time.minute)
        _ = ledger.settle(RequestID("x"), key: F.bob, apiKey: "k", usage: F.use(500), now: F.t0 + 11 * Time.minute)
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: F.t0), 500)
        XCTAssertEqual(ledger.breaker.spentMicroUSD, 2_400, "the estimated cost was already spent; it never goes down")
    }

    // MARK: Claim and the request's identity

    func testAClaimMustComeFromTheOwnerWithTheSameRequest() {
        var ledger = QuotaLedger(configuration: F.configuration())
        _ = ledger.authorize(RequestID("a"), key: F.bob, apiKey: "k", estimate: F.est(400), promptDigest: "sha256:abc", now: F.t0)
        XCTAssertEqual(ledger.claim(RequestID("a"), key: F.mallory, apiKey: "k", promptDigest: "sha256:abc", now: F.t0), .mismatch,
                       "a leaked ID can't be claimed by another session")
        XCTAssertEqual(ledger.claim(RequestID("a"), key: F.bob, apiKey: "k", promptDigest: "sha256:LONGER", now: F.t0), .mismatch,
                       "a completion can't run a different prompt than the one admitted")
        XCTAssertEqual(ledger.authorize(RequestID("a"), key: F.bob, apiKey: "k", estimate: F.est(400), promptDigest: "sha256:LONGER",
                                        now: F.t0).denial?.reason, .requestIDReused)
        guard case .claimed = ledger.claim(RequestID("a"), key: F.bob, apiKey: "k", promptDigest: "sha256:abc", now: F.t0) else {
            return XCTFail("the owner's own claim must still succeed")
        }
        XCTAssertEqual(ledger.stats.claimMismatches, 2)
        XCTAssertEqual(ledger.stats.claims, 1)
    }

    func testSettlingZeroUsageAfterAProviderErrorRefundsEverythingAndSpendsTheID() {
        var ledger = QuotaLedger(configuration: F.configuration())
        _ = ledger.authorize(RequestID("e"), key: F.bob, apiKey: "k", estimate: F.est(800, 200), now: F.t0)
        _ = ledger.claim(RequestID("e"), key: F.bob, apiKey: "k", now: F.t0)
        XCTAssertEqual(ledger.settle(RequestID("e"), key: F.bob, apiKey: "k", usage: .zero, now: F.t0),
                       .settled(charged: 0, adjustment: -1_000, persistence: .applied))
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: F.t0), 0)
        XCTAssertEqual(ledger.breaker.heldMicroUSD, 0)
        XCTAssertEqual(ledger.authorize(RequestID("e"), key: F.bob, apiKey: "k", estimate: F.est(800, 200), now: F.t0).denial?.reason,
                       .alreadySettled, "the app retries with a new ID, not this one")
    }

    func testOnlyAllowlistedFeaturesAreMetered() {
        var configuration = F.configuration()
        configuration.features = ["summarize"]
        var ledger = QuotaLedger(configuration: configuration)
        let invented = QuotaKey(userID: "bob", feature: "summarize-2", tier: .pro)
        XCTAssertEqual(ledger.authorize(RequestID("i"), key: invented, apiKey: "k", estimate: F.est(10), now: F.t0).denial?.reason,
                       .unknownFeature, "inventing feature names must not multiply a user's limits")
        XCTAssertNotNil(ledger.authorize(RequestID("j"), key: F.bob, apiKey: "k", estimate: F.est(10), now: F.t0).grant)
        XCTAssertEqual(ledger.trackedKeys, 1)
    }

    func testCallStartAttributionCoversALateSettleOfAnUnclaimedHold() {
        let reservedAt = Time.startOfDay(11) - 30 * Time.second
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute))
        _ = ledger.authorize(RequestID("n"), key: F.bob, apiKey: "k", estimate: F.est(100), now: reservedAt)
        ledger.sweep(now: reservedAt + Time.minute)
        _ = ledger.settle(RequestID("n"), key: F.bob, apiKey: "k", usage: F.use(80), now: reservedAt + 2 * Time.minute)
        XCTAssertEqual(ledger.attribution[AttributionKey(apiKey: "k", dayIndex: 10)], 80, "reserved on day 10, so attributed to day 10")
    }

    // MARK: The breaker

    func testAResetIsNotUndoneByCallsAlreadyInFlight() {
        // Four holds fit a $0.013 cap at $0.003 each; each actually costs $0.0045, so the third settle overspends.
        var ledger = QuotaLedger(configuration: F.configuration(orgLimit: 13_000))
        for i in 0..<4 { _ = ledger.authorize(RequestID("h\(i)"), key: F.bob, apiKey: "k", estimate: F.est(1_000), now: F.t0) }
        for i in 0..<3 { _ = ledger.settle(RequestID("h\(i)"), key: F.bob, apiKey: "k", usage: F.use(1_500), now: F.t0) }
        XCTAssertEqual(ledger.breaker.lastTrip, .overspend)
        ledger.resetBreaker(now: F.t0)
        _ = ledger.settle(RequestID("h3"), key: F.bob, apiKey: "k", usage: F.use(1_500), now: F.t0 + Time.second)
        XCTAssertFalse(ledger.breaker.isOpen(now: F.t0 + Time.second), "the in-flight call settling over the cap doesn't reopen it")
        XCTAssertEqual(ledger.breaker.trips, 1)
        XCTAssertEqual(ledger.authorize(RequestID("next"), key: F.bob, apiKey: "k", estimate: F.est(1), now: F.t0 + Time.second).denial?.reason,
                       .orgBudgetWouldExceed, "admission still enforces the cap")
    }

    // MARK: Identity, clock steps and retention

    func testAClaimOnAFinishedIDChecksTheOwnerAndTheRequest() {
        var ledger = QuotaLedger(configuration: F.configuration())
        _ = ledger.authorize(RequestID("f"), key: F.bob, apiKey: "k", estimate: F.est(100), promptDigest: "d1", now: F.t0)
        _ = ledger.claim(RequestID("f"), key: F.bob, apiKey: "k", promptDigest: "d1", now: F.t0)
        _ = ledger.settle(RequestID("f"), key: F.bob, apiKey: "k", usage: F.use(90), now: F.t0)
        XCTAssertEqual(ledger.claim(RequestID("f"), key: F.mallory, apiKey: "k", promptDigest: "d1", now: F.t0), .mismatch,
                       "another user must not be served bob's cached response")
        XCTAssertEqual(ledger.claim(RequestID("f"), key: F.bob, apiKey: "k", promptDigest: "d2", now: F.t0), .mismatch,
                       "nor bob, for a different prompt")
        XCTAssertEqual(ledger.claim(RequestID("f"), key: F.bob, apiKey: "k", promptDigest: "d1", now: F.t0), .alreadySettled)
    }

    func testAMidCallExpiryChecksTheOwnerToo() {
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute, claimedTTL: 10 * Time.minute))
        _ = ledger.authorize(RequestID("p"), key: F.bob, apiKey: "k", estimate: F.est(100), now: F.t0)
        _ = ledger.claim(RequestID("p"), key: F.bob, apiKey: "k", now: F.t0)
        ledger.sweep(now: F.t0 + 10 * Time.minute)
        XCTAssertEqual(ledger.authorize(RequestID("p"), key: F.mallory, apiKey: "k", estimate: F.est(100), now: F.t0 + 10 * Time.minute).denial?.reason,
                       .requestIDReused)
        XCTAssertEqual(ledger.claim(RequestID("p"), key: F.mallory, apiKey: "k", now: F.t0 + 10 * Time.minute), .mismatch)
        XCTAssertEqual(ledger.claim(RequestID("p"), key: F.bob, apiKey: "k", now: F.t0 + 10 * Time.minute), .alreadyClaimed)
    }

    func testClaimingAnExpiredUnclaimedIDSaysThereIsNoHold() {
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute))
        _ = ledger.authorize(RequestID("u"), key: F.bob, apiKey: "k", estimate: F.est(100), now: F.t0)
        ledger.sweep(now: F.t0 + Time.minute)
        XCTAssertEqual(ledger.claim(RequestID("u"), key: F.bob, apiKey: "k", now: F.t0 + Time.minute), .noHold)
    }

    func testAClockStepBackAcrossMidnightRefundsTheWindowItCharged() {
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute))
        let justAfterMidnight = Time.startOfDay(11) + 10 * Time.second
        _ = ledger.authorize(RequestID("a"), key: F.bob, apiKey: "k", estimate: F.est(100), now: justAfterMidnight)
        _ = ledger.settle(RequestID("a"), key: F.bob, apiKey: "k", usage: F.use(100), now: justAfterMidnight)
        let steppedBack = Time.startOfDay(11) - 10 * Time.second   // the wall clock steps back 20 s
        _ = ledger.authorize(RequestID("b"), key: F.bob, apiKey: "k", estimate: F.est(1_000), now: steppedBack)
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: justAfterMidnight), 1_100, "charged to day 11, the open window")
        ledger.sweep(now: steppedBack + 2 * Time.minute)
        XCTAssertEqual(ledger.dailyUsed(for: F.bob, now: steppedBack + 2 * Time.minute), 100, "and refunded to day 11")
    }

    func testHugeIdempotencyCapacitiesDoNotTrap() {
        let configuration = LedgerConfiguration(policies: [.pro: F.pro], price: F.price, orgSpendLimitMicroUSD: .max,
                                                idempotencyCapacity: .max, provisionalCapacity: .max)
        var ledger = QuotaLedger(configuration: configuration)
        _ = ledger.authorize(RequestID("a"), key: F.bob, apiKey: "k", estimate: F.est(100), now: F.t0)
        XCTAssertEqual(ledger.settle(RequestID("a"), key: F.bob, apiKey: "k", usage: F.use(100), now: F.t0),
                       .settled(charged: 100, adjustment: 0, persistence: .applied))
        ledger.sweep(now: F.t0 + Time.day)
    }

    func testGlobalLazyExpiryRunsAtMostOnceASecond() {
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute, maxHolds: 2))
        _ = ledger.authorize(RequestID("a"), key: F.bob, apiKey: "k", estimate: F.est(10), now: F.t0)
        _ = ledger.authorize(RequestID("b"), key: F.mallory, apiKey: "k", estimate: F.est(10), now: F.t0)
        let carol = QuotaKey(userID: "carol", feature: "summarize", tier: .pro)
        let justBefore = F.t0 + Time.minute - 1
        XCTAssertNotNil(ledger.authorize(RequestID("c"), key: carol, apiKey: "k", estimate: F.est(10), now: justBefore).denial,
                        "scanned: nothing had expired yet")
        XCTAssertNotNil(ledger.authorize(RequestID("c"), key: carol, apiKey: "k", estimate: F.est(10), now: justBefore + 1).denial,
                        "1 ms later the holds have expired, but the full scan is rate-limited")
        XCTAssertNotNil(ledger.authorize(RequestID("c"), key: carol, apiKey: "k", estimate: F.est(10), now: justBefore + Time.second).grant,
                        "a second later it scans again")
    }

    func testMidCallExpiriesArePurgedByTimeAndEvictionsAreCounted() {
        var ledger = QuotaLedger(configuration: LedgerConfiguration(
            policies: [.pro: F.pro], price: F.price, orgSpendLimitMicroUSD: .max, holdTTLMs: Time.minute,
            claimedHoldTTLMs: 10 * Time.minute, provisionalRetentionMs: Time.day, provisionalCapacity: 1))
        for id in ["m1", "m2"] {
            _ = ledger.authorize(RequestID(id), key: F.bob, apiKey: "k", estimate: F.est(100), now: F.t0)
            _ = ledger.claim(RequestID(id), key: F.bob, apiKey: "k", now: F.t0)
        }
        ledger.sweep(now: F.t0 + 10 * Time.minute)
        XCTAssertEqual(ledger.stats.provisionalEvictions, 1, "capacity 1: one of the two was forgotten early")
        XCTAssertEqual(ledger.rememberedMidCallExpiries, 1)
        ledger.sweep(now: F.t0 + 10 * Time.minute + Time.day)
        XCTAssertEqual(ledger.rememberedMidCallExpiries, 0, "purged once its 24 h retention ended")
    }

    func testSettlementAttributionAlsoCoversLateSettles() {
        let reservedAt = Time.startOfDay(11) - 30 * Time.second
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute, attribute: .settlement))
        _ = ledger.authorize(RequestID("n"), key: F.bob, apiKey: "k", estimate: F.est(100), now: reservedAt)
        ledger.sweep(now: reservedAt + Time.minute)
        _ = ledger.settle(RequestID("n"), key: F.bob, apiKey: "k", usage: F.use(80), now: reservedAt + 2 * Time.minute)
        XCTAssertEqual(ledger.attribution[AttributionKey(apiKey: "k", dayIndex: 11)], 80)
    }

    func testADroppedProvisionalChargeIsCounted() {
        var ledger = QuotaLedger(configuration: F.configuration(holdTTL: Time.minute, claimedTTL: 10 * Time.minute, journal: 0))
        ledger.setStoreAvailable(false, now: F.t0)
        _ = ledger.authorize(RequestID("d"), key: F.bob, apiKey: "k", estimate: F.est(700), now: F.t0)
        _ = ledger.claim(RequestID("d"), key: F.bob, apiKey: "k", now: F.t0)
        ledger.sweep(now: F.t0 + 10 * Time.minute)
        XCTAssertEqual(ledger.stats.journalDroppedEntries, 1)
        XCTAssertEqual(ledger.stats.journalDroppedChargeTokens, 700)
        XCTAssertEqual(ledger.stats.journalDroppedTokens, 0, "not usage: reconciliation can't see it, so it has its own counter")
    }
}
