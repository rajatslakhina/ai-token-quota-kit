import XCTest
@testable import TokenQuota

final class ArithmeticTests: XCTestCase {
    func testAddSubMulSaturateInsteadOfTrapping() {
        XCTAssertEqual(Sat.add(.max, 1), .max)
        XCTAssertEqual(Sat.add(.min, -1), .min)
        XCTAssertEqual(Sat.sub(.min, 1), .min)
        XCTAssertEqual(Sat.sub(.max, -1), .max)
        XCTAssertEqual(Sat.mul(.max, 2), .max)
        XCTAssertEqual(Sat.mul(.min, 2), .min)
        XCTAssertEqual(Sat.mul(.min, -1), .max)
        XCTAssertEqual(Sat.add(2, 3), 5)
        XCTAssertEqual(Sat.mul(-4, 5), -20)
    }

    func testDivisionNeverTraps() {
        XCTAssertEqual(Sat.div(10, 0), 0)
        XCTAssertEqual(Sat.div(10, 0, orIfZero: -1), -1)
        XCTAssertEqual(Sat.div(.min, -1), .max)
        XCTAssertEqual(Sat.div(7, 2), 3)
        XCTAssertEqual(Sat.neg(.min), .max)
    }

    func testDoubleConversionNeverTraps() {
        XCTAssertEqual(Sat.int64(.nan), 0)
        XCTAssertEqual(Sat.int64(.infinity), .max)
        XCTAssertEqual(Sat.int64(-.infinity), .min)
        XCTAssertEqual(Sat.int64(1e300), .max)
        XCTAssertEqual(Sat.int64(Double(Int64.max)), .max)   // 2^63: one past the range
        XCTAssertEqual(Sat.int64(-1e300), .min)
        XCTAssertEqual(Sat.int64(1234.9), 1234)
    }
}

final class TokenBucketTests: XCTestCase {
    let limit = BucketLimit(capacity: 100, refillPerSecond: 10)

    func testStartsFullAndTakes() {
        var bucket = TokenBucket(limit: limit, now: 0)
        XCTAssertTrue(bucket.isFull)
        XCTAssertTrue(bucket.canTake(100))
        XCTAssertFalse(bucket.canTake(101))
        bucket.take(60)
        XCTAssertEqual(bucket.availableTokens, 40)
    }

    func testRefillIsExactAtMillisecondGranularity() {
        // 1 token/s refilled every single millisecond for 3 s must gain exactly 3 tokens.
        // An implementation that converts each 1 ms step to whole tokens would gain 0.
        var bucket = TokenBucket(limit: BucketLimit(capacity: 10, refillPerSecond: 1), now: 0)
        bucket.take(10)
        for t in 1...3_000 { bucket.refill(now: Millis(t)) }
        XCTAssertEqual(bucket.levelMilli, 3_000)
        XCTAssertEqual(bucket.availableTokens, 3)
    }

    func testGiveNeverOverfills() {
        var bucket = TokenBucket(limit: limit, now: 0)
        bucket.give(10)
        XCTAssertEqual(bucket.levelMilli, bucket.capacityMilli, "a refund to a full bucket stays at capacity")
        bucket.take(30)
        bucket.give(1_000)
        XCTAssertEqual(bucket.availableTokens, 100)
    }

    func testRefillCapsAtCapacity() {
        var bucket = TokenBucket(limit: limit, now: 0)
        bucket.take(50)
        bucket.refill(now: 1_000_000)
        XCTAssertEqual(bucket.availableTokens, 100)
    }

    func testClockSteppingBackNeverRefillsTwice() {
        var bucket = TokenBucket(limit: limit, now: 10_000)
        bucket.take(100)
        bucket.refill(now: 5_000)          // backwards: nothing
        XCTAssertEqual(bucket.levelMilli, 0)
        XCTAssertEqual(bucket.lastRefillMs, 10_000)
        bucket.refill(now: 11_000)         // 1 s past the high-water mark: 10 tokens, not 60
        XCTAssertEqual(bucket.availableTokens, 10)
    }

    func testDebtIsFlooredAtOneBucket() {
        var bucket = TokenBucket(limit: limit, now: 0)
        bucket.take(1_000_000)
        XCTAssertEqual(bucket.levelMilli, -100_000)
        XCTAssertEqual(bucket.availableTokens, -100)
        // From the floor, a 50-token request waits (capacity + 50) / rate = 15 s.
        XCTAssertEqual(bucket.millisUntilAvailable(50), 15_000)
    }

    func testMillisUntilAvailableRoundsUpAndKnowsImpossible() {
        var bucket = TokenBucket(limit: BucketLimit(capacity: 100, refillPerSecond: 3), now: 0)
        bucket.take(100)
        XCTAssertEqual(bucket.millisUntilAvailable(0), 0)
        XCTAssertEqual(bucket.millisUntilAvailable(1), 334)   // 1000 milli / 3 per ms, rounded up
        XCTAssertNil(bucket.millisUntilAvailable(101))       // larger than the bucket: never
        let frozen = TokenBucket(limit: BucketLimit(capacity: 5, refillPerSecond: 0), now: 0)
        XCTAssertEqual(frozen.millisUntilAvailable(5), 0)
        var drained = frozen
        drained.take(5)
        XCTAssertNil(drained.millisUntilAvailable(1))
    }

    func testZeroAndNegativeLimitsDoNotTrap() {
        var bucket = TokenBucket(limit: BucketLimit(capacity: -5, refillPerSecond: -1), now: 0)
        bucket.refill(now: .max)
        XCTAssertEqual(bucket.capacityMilli, 0)
        XCTAssertFalse(bucket.canTake(1))
        XCTAssertTrue(bucket.canTake(0))
        XCTAssertFalse(bucket.canTake(-1))
        var huge = TokenBucket(limit: BucketLimit(capacity: .max, refillPerSecond: .max), now: .min)
        huge.refill(now: .max)
        huge.take(.max)
        XCTAssertLessThanOrEqual(huge.levelMilli, huge.capacityMilli)
    }

    func testDailyWindowRollsForwardOnly() {
        var day = DailyUsage(dayIndex: 3, used: 500)
        day.roll(now: 3 * Time.day + 10)
        XCTAssertEqual(day.used, 500)
        day.roll(now: 2 * Time.day)
        XCTAssertEqual(day.dayIndex, 3)
        day.roll(now: 4 * Time.day)
        XCTAssertEqual(day.dayIndex, 4)
        XCTAssertEqual(day.used, 0)
        XCTAssertEqual(Time.dayIndex(-5), 0)
    }
}

final class CalendarTests: XCTestCase {
    func testCivilDates() {
        XCTAssertTrue(Time.civil(dayIndex: 0) == (1970, 1, 1))
        XCTAssertTrue(Time.civil(dayIndex: 20_454) == (2026, 1, 1))
        XCTAssertTrue(Time.civil(dayIndex: 20_484) == (2026, 1, 31))
        XCTAssertTrue(Time.civil(dayIndex: 21_243) == (2028, 2, 29))
        XCTAssertTrue(Time.civil(dayIndex: 21_244) == (2028, 3, 1))
        XCTAssertTrue(Time.civil(dayIndex: -5) == (1970, 1, 1), "clamped, not trapped")
        _ = Time.civil(dayIndex: .max)   // clamped to maxCalendarDay: must not trap
    }

    func testMonthLengthsAndLeapRules() {
        XCTAssertEqual(Time.daysInMonth(year: 2024, month: 2), 29)
        XCTAssertEqual(Time.daysInMonth(year: 2026, month: 2), 28)
        XCTAssertEqual(Time.daysInMonth(year: 2000, month: 2), 29)
        XCTAssertEqual(Time.daysInMonth(year: 1900, month: 2), 28)
        XCTAssertEqual(Time.daysInMonth(year: 2100, month: 2), 28)
        XCTAssertEqual(Time.daysInMonth(year: 2026, month: 4), 30)
        XCTAssertEqual(Time.daysInMonth(year: 2026, month: 12), 31)
    }

    func testFirstDayOfNextMonth() {
        XCTAssertEqual(Time.firstDayOfNextMonth(after: 20_484), 20_485)   // 31 Jan 2026 → 1 Feb
        XCTAssertEqual(Time.firstDayOfNextMonth(after: 20_454), 20_485)   // 1 Jan 2026 → 1 Feb
        XCTAssertEqual(Time.firstDayOfNextMonth(after: 21_215), 21_244)   // 1 Feb 2028 (leap) → 1 Mar
        XCTAssertEqual(Time.firstDayOfNextMonth(after: 47_513), 47_541)   // 1 Feb 2100 (not leap) → 1 Mar
    }
}

final class BoundedMapTests: XCTestCase {
    func testEvictsOldestBeyondCapacity() {
        var map = BoundedMap<Int, String>(capacity: 2)
        map.insert("a", for: 1)
        map.insert("b", for: 2)
        map.insert("c", for: 3)
        XCTAssertNil(map[1])
        XCTAssertEqual(map[2], "b")
        XCTAssertEqual(map[3], "c")
        XCTAssertEqual(map.evictions, 1)
    }

    func testMemoryStaysBoundedNotJustTheCount() {
        var map = BoundedMap<Int, Int>(capacity: 3)
        for i in 0..<10_000 { map.insert(i, for: i) }
        XCTAssertEqual(map.count, 3)
        XCTAssertEqual(map[9_999], 9_999)
        XCTAssertNil(map[9_996])
        // Without compaction the ordering array would hold all 10,000 keys.
        XCTAssertLessThanOrEqual(map.storageFootprint, 2 * 3 + 2)
        var tiny = BoundedMap<Int, Int>(capacity: 0)
        tiny.insert(1, for: 1)
        tiny.insert(2, for: 2)
        XCTAssertEqual(tiny.count, 1)
        XCTAssertEqual(tiny[2], 2)
    }

    func testRewritingAKeyMakesItTheNewestEntry() {
        var map = BoundedMap<String, Int>(capacity: 3)
        map.insert(1, for: "a")
        map.insert(2, for: "b")
        map.insert(3, for: "c")
        map.insert(10, for: "a")   // a is now the freshest
        map.insert(4, for: "d")    // so b, not a, is evicted
        XCTAssertEqual(map["a"], 10)
        XCTAssertNil(map["b"])
        XCTAssertEqual(map.evictions, 1)
        // Time-based removal reaches entries behind a rewritten one instead of stalling on it.
        var timed = BoundedMap<String, Int>(capacity: 10)
        timed.insert(1, for: "x")
        timed.insert(2, for: "y")
        timed.insert(50, for: "x")
        timed.removeOldest { _, stamp in stamp < 5 }
        XCTAssertNil(timed["y"])
        XCTAssertEqual(timed["x"], 50)
    }

    func testRemoveValueAndHeavyRewritesStayBounded() {
        var map = BoundedMap<Int, Int>(capacity: 4)
        for i in 0..<4 { map.insert(i, for: i) }
        XCTAssertEqual(map.removeValue(forKey: 2), 2)
        XCTAssertNil(map[2])
        map.insert(20, for: 2)
        XCTAssertEqual(map[2], 20)
        for round in 0..<10_000 { map.insert(round, for: round % 4) }   // rewrites only
        XCTAssertEqual(map.count, 4)
        XCTAssertLessThanOrEqual(map.storageFootprint, 2 * 4 + 16 + 1, "stale slots are compacted away")
        XCTAssertEqual(map.evictions, 0)
    }

    func testHugeCapacitiesDoNotTrap() {
        var map = BoundedMap<Int, Int>(capacity: .max)
        XCTAssertEqual(map.capacity, BoundedMap<Int, Int>.maxCapacity)
        for i in 0..<100 { map.insert(i, for: i % 7) }
        map.removeOldest { _, _ in true }
        XCTAssertEqual(map.count, 0)
    }

    func testRemoveOldestStopsAtTheFirstEntryItKeeps() {
        var map = BoundedMap<Int, Int>(capacity: 10)
        for i in 0..<5 { map.insert(i, for: i) }
        map.removeOldest { key, _ in key < 2 }
        XCTAssertEqual(map.count, 3)
        XCTAssertNil(map[1])
        XCTAssertEqual(map[2], 2)
        map.removeOldest { _, _ in true }
        XCTAssertEqual(map.count, 0)
        XCTAssertEqual(map.storageFootprint, 0)
        map.insert(7, for: 0)
        XCTAssertEqual(map[0], 7)
        XCTAssertEqual(map.evictions, 0, "removal by time is not a capacity eviction")
    }
}

final class BreakerTests: XCTestCase {
    func testAdmissionCountsHeldAndSpent() {
        var breaker = OrgSpendBreaker(limitMicroUSD: 100)
        breaker.roll(now: 0)
        breaker.hold(60)
        XCTAssertTrue(breaker.canAdmit(40))
        XCTAssertFalse(breaker.canAdmit(41))
        XCTAssertTrue(breaker.blockedOnlyByHolds(41))
        breaker.release(60)
        breaker.spend(90, now: 0)
        XCTAssertFalse(breaker.canAdmit(11))
        XCTAssertFalse(breaker.blockedOnlyByHolds(11))
        XCTAssertNil(breaker.openUntil)
    }

    func testSpendingExactlyTheCapIsNotAnOverspend() {
        var breaker = OrgSpendBreaker(limitMicroUSD: 100)
        breaker.spend(100, now: 0)
        XCTAssertNil(breaker.openUntil)
        breaker.spend(1, now: 0)
        XCTAssertEqual(breaker.lastTrip, .overspend)
        XCTAssertEqual(breaker.trips, 1)
        breaker.spend(10, now: 1)
        XCTAssertEqual(breaker.trips, 1, "an open breaker does not re-trip")
    }

    func testVelocityTripsBelowTheCap() {
        var breaker = OrgSpendBreaker(limitMicroUSD: 1_000, velocityTripMicroUSD: 200,
                                      velocityWindowMs: 5 * Time.minute, cooldownMs: 10 * Time.minute)
        breaker.spend(150, now: Time.minute)
        XCTAssertFalse(breaker.isOpen(now: Time.minute))
        breaker.spend(60, now: 2 * Time.minute)
        XCTAssertTrue(breaker.isOpen(now: 2 * Time.minute))
        XCTAssertEqual(breaker.lastTrip, .velocity)
        XCTAssertEqual(breaker.openUntil, 12 * Time.minute)
        XCTAssertTrue(breaker.canAdmit(100), "admission alone would still admit: 210 of 1,000 spent")
    }

    func testSlowSpendNeverTripsTheVelocityBreaker() {
        var breaker = OrgSpendBreaker(limitMicroUSD: 1_000, velocityTripMicroUSD: 200, velocityWindowMs: 5 * Time.minute)
        breaker.spend(150, now: Time.minute)
        breaker.spend(150, now: 11 * Time.minute)   // ten minutes later: nothing of the first spend overlaps
        XCTAssertNil(breaker.openUntil)
    }

    func testASpikeStraddlingAWindowBoundaryStillTrips() {
        // 150 at 4:59 and 100 at 5:01: each fixed window alone is under 200, the trailing 5 minutes are not.
        var breaker = OrgSpendBreaker(limitMicroUSD: 10_000, velocityTripMicroUSD: 200, velocityWindowMs: 5 * Time.minute)
        breaker.spend(150, now: 5 * Time.minute - Time.second)
        XCTAssertNil(breaker.openUntil)
        breaker.spend(100, now: 5 * Time.minute + Time.second)
        XCTAssertEqual(breaker.lastTrip, .velocity)
        XCTAssertEqual(breaker.velocityEstimate(now: 5 * Time.minute + Time.second), 249)
    }

    func testClockSteppingBackNeverReopensASpendOrVelocityWindow() {
        var breaker = OrgSpendBreaker(limitMicroUSD: 10_000, velocityTripMicroUSD: 1_000_000, velocityWindowMs: 5 * Time.minute)
        breaker.spend(50, now: 2 * Time.hour + 12 * Time.minute)
        breaker.spend(10, now: Time.hour)   // the clock stepped back over an hour and several velocity windows
        XCTAssertEqual(breaker.spentMicroUSD, 60, "the hour's spend was not reset by a backwards step")
        XCTAssertEqual(breaker.velocitySpentMicroUSD, 60, "neither was the velocity window's")
        XCTAssertEqual(breaker.windowIndex, 2)
    }

    func testAResetIsNotUndoneByASettlementAlreadyInFlight() {
        var breaker = OrgSpendBreaker(limitMicroUSD: 100)
        breaker.spend(120, now: 10)
        XCTAssertTrue(breaker.isOpen(now: 10))
        breaker.reset(now: 15)
        breaker.spend(30, now: 20)   // a call that was already running settles over the cap
        XCTAssertFalse(breaker.isOpen(now: 20))
        XCTAssertEqual(breaker.trips, 1)
        breaker.spend(30, now: Time.hour + 1)   // a new window can trip again
        XCTAssertFalse(breaker.isOpen(now: Time.hour + 1), "30 of 100 in the new hour is not an overspend")
    }

    func testTripOutlivesTheSpendWindow() {
        var breaker = OrgSpendBreaker(limitMicroUSD: 100, windowMs: Time.hour, cooldownMs: 15 * Time.minute)
        breaker.spend(120, now: 58 * Time.minute)
        breaker.roll(now: 61 * Time.minute)
        XCTAssertTrue(breaker.canAdmit(50), "a fresh hour: admission alone would admit")
        XCTAssertTrue(breaker.isOpen(now: 61 * Time.minute))
        XCTAssertFalse(breaker.isOpen(now: 73 * Time.minute))
    }

    func testResetClosesAndOverrideAddsHeadroomForThisWindowOnly() {
        var breaker = OrgSpendBreaker(limitMicroUSD: 100)
        breaker.spend(120, now: 10)
        XCTAssertTrue(breaker.isOpen(now: 10))
        breaker.reset(now: 10)
        XCTAssertFalse(breaker.isOpen(now: 10))
        XCTAssertFalse(breaker.canAdmit(1), "closing the breaker does not raise the cap")
        breaker.reset(overrideMicroUSD: 50, now: 10)
        XCTAssertTrue(breaker.canAdmit(30))
        XCTAssertFalse(breaker.canAdmit(31))
        breaker.roll(now: Time.hour)
        XCTAssertEqual(breaker.effectiveLimitMicroUSD, 100, "the override expires with its window")
    }

    func testAResetSurvivesAnOverspendThatHappenedWhileAlreadyOpen() {
        // Velocity trips first; calls still in flight then push spend past the cap while it is open.
        var breaker = OrgSpendBreaker(limitMicroUSD: 13_000, velocityTripMicroUSD: 4_000)
        breaker.spend(4_500, now: Time.minute)
        XCTAssertEqual(breaker.lastTrip, .velocity)
        breaker.spend(4_500, now: Time.minute + 1)
        breaker.spend(4_500, now: Time.minute + 2)   // 13,500 > 13,000 while open: recorded, not tripped
        breaker.reset(now: 2 * Time.minute)
        breaker.spend(4_500, now: 2 * Time.minute + 1)
        XCTAssertFalse(breaker.isOpen(now: 2 * Time.minute + 1), "the last in-flight call can't reopen it")
        XCTAssertEqual(breaker.trips, 1)
    }

    func testAResetKeepsTheVelocityTripQuietWhileInFlightCallsSettle() {
        var breaker = OrgSpendBreaker(limitMicroUSD: 10_000, velocityTripMicroUSD: 4_000, velocityWindowMs: 5 * Time.minute)
        breaker.spend(10_500, now: Time.minute)
        XCTAssertEqual(breaker.lastTrip, .overspend)
        breaker.reset(overrideMicroUSD: 20_000, now: 2 * Time.minute)
        breaker.spend(4_500, now: 2 * Time.minute + 1)   // in-flight settlements worth a velocity trip
        XCTAssertFalse(breaker.isOpen(now: 2 * Time.minute + 1))
        breaker.spend(4_500, now: 8 * Time.minute)       // after the quiet window, a new spike trips again
        XCTAssertEqual(breaker.lastTrip, .velocity)
        XCTAssertEqual(breaker.trips, 2)
    }

    func testAResetForgetsThePreResetSpike() {
        // Trip at 4:00 on 4,500 in window 0. If reset kept that history, the first spend after the quiet
        // period (9:11, window 1) would still carry ~750 of it and trip on 3,300 of new spend.
        var breaker = OrgSpendBreaker(limitMicroUSD: 100_000, velocityTripMicroUSD: 4_000, velocityWindowMs: 5 * Time.minute)
        breaker.spend(4_500, now: 4 * Time.minute)
        breaker.reset(now: 4 * Time.minute + 10 * Time.second)
        breaker.spend(3_300, now: 9 * Time.minute + 11 * Time.second)
        XCTAssertFalse(breaker.isOpen(now: 9 * Time.minute + 11 * Time.second))
    }

    func testRaisingTheCapRearmsTheOverspendTrip() {
        var breaker = OrgSpendBreaker(limitMicroUSD: 100)
        breaker.spend(120, now: 10)
        breaker.reset(overrideMicroUSD: 50, now: 20)
        breaker.spend(20, now: 30)   // 140 of 150: fine
        XCTAssertFalse(breaker.isOpen(now: 30))
        breaker.spend(20, now: 40)   // 160 of 150: past the raised cap
        XCTAssertEqual(breaker.trips, 2)
    }

    func testZeroCostSettlementNeverTrips() {
        var breaker = OrgSpendBreaker(limitMicroUSD: 0, velocityTripMicroUSD: 0)
        breaker.spend(0, now: 0)
        XCTAssertNil(breaker.openUntil)
    }
}
