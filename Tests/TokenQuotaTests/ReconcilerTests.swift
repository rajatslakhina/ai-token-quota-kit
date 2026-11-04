import XCTest
@testable import TokenQuota

final class ReconcilerTests: XCTestCase {
    let day: Int64 = 30
    var afterLatency: Millis { Time.startOfDay(day + 2) }
    var insideLatency: Millis { Time.startOfDay(day + 1) + 2 * Time.hour }

    func key(_ apiKey: String = "k") -> AttributionKey { AttributionKey(apiKey: apiKey, dayIndex: day) }
    func row(_ tokens: Int64, _ apiKey: String = "k") -> AnalyticsRow { AnalyticsRow(apiKey: apiKey, dayIndex: day, tokens: tokens) }

    func status(ledger: Int64?, report: [AnalyticsRow], now: Millis, watermark: Millis? = nil, bp: Int64 = 200) -> DriftStatus? {
        let ledgerMap = ledger.map { [key(): $0] } ?? [:]
        return Reconciler.reconcile(ledger: ledgerMap, report: report, dataRefreshedAt: watermark, now: now,
                                    policy: ReconciliationPolicy(toleranceBasisPoints: bp)).first?.status
    }

    func testToleranceIsMeasuredOnTheLargerSide() {
        // 2% of 10,202 is 204, so a 202-token gap matches; 2% of the smaller side (200) would not.
        XCTAssertEqual(status(ledger: 10_000, report: [row(10_202)], now: afterLatency), .matched)
        XCTAssertEqual(status(ledger: 10_000, report: [row(10_205)], now: afterLatency), .ledgerUnder(205))
    }

    func testRowsForTheSameKeyAndDayAreSummed() {
        XCTAssertEqual(status(ledger: 10_000, report: [row(6_000), row(4_000)], now: afterLatency), .matched)
    }

    func testRowsAreBuiltFromUncachedInputPlusOutput() {
        let row = AnalyticsRow(apiKey: "k", dayIndex: day, uncachedInputTokens: 1_200, outputTokens: 300)
        XCTAssertEqual(row.tokens, 1_500)
        XCTAssertEqual(AnalyticsRow(apiKey: "k", dayIndex: day, uncachedInputTokens: -5, outputTokens: 10).tokens, 10)
    }

    func testShortReportInsideLatencyIsLagNotDrift() {
        XCTAssertEqual(status(ledger: 10_000, report: [row(4_000)], now: insideLatency), .awaitingData)
        XCTAssertEqual(status(ledger: 10_000, report: [], now: insideLatency), .awaitingData)
        // The same numbers after the horizon are real drift.
        XCTAssertEqual(status(ledger: 10_000, report: [row(4_000)], now: afterLatency), .ledgerOver(6_000))
        XCTAssertEqual(status(ledger: 10_000, report: [], now: afterLatency), .ledgerOver(10_000))
    }

    func testDataRefreshedAtDecidesCompletenessWhenTheReportHasIt() {
        let dayEnd = Time.startOfDay(day + 1)
        // Inside the 24 h fallback horizon, but the watermark says the day is complete: real drift.
        XCTAssertEqual(status(ledger: 10_000, report: [row(4_000)], now: insideLatency, watermark: dayEnd + Time.hour),
                       .ledgerOver(6_000))
        // Long after the fallback horizon, but the watermark says the day is still partial: lag.
        XCTAssertEqual(status(ledger: 10_000, report: [row(4_000)], now: Time.startOfDay(day + 10), watermark: dayEnd - Time.hour),
                       .awaitingData)
    }

    func testProviderAboveLedgerIsFlaggedEvenInsideLatency() {
        // Lag can only make the report smaller, so a larger report is never explained by it.
        XCTAssertEqual(status(ledger: 10_000, report: [row(12_000)], now: insideLatency), .ledgerUnder(2_000))
        XCTAssertEqual(status(ledger: 10_000, report: [row(12_000)], now: insideLatency, watermark: 0), .ledgerUnder(2_000))
    }

    func testKeyTheLedgerNeverSawIsUnknown() {
        XCTAssertEqual(status(ledger: nil, report: [row(5_000)], now: insideLatency), .unknownKey(5_000))
        XCTAssertEqual(status(ledger: nil, report: [row(0)], now: afterLatency), .matched)
    }

    func testZeroToleranceAndNegativeRowsAndHugeValues() {
        XCTAssertEqual(status(ledger: 100, report: [row(101)], now: afterLatency, bp: 0), .ledgerUnder(1))
        XCTAssertEqual(status(ledger: 100, report: [row(100), row(-50)], now: afterLatency, bp: 0), .matched)
        XCTAssertEqual(status(ledger: .max, report: [row(.max), row(.max)], now: afterLatency), .matched)
        XCTAssertEqual(status(ledger: 0, report: [row(.max)], now: afterLatency), .ledgerUnder(.max))
    }

    func testFinalityIsMonthEndPlusSevenDays() {
        let policy = ReconciliationPolicy()
        // 31 Jan 2026 and 1 Jan 2026 both become final on 8 Feb 2026 (day 20,492).
        XCTAssertEqual(policy.finality(of: 20_484), Time.startOfDay(20_492))
        XCTAssertEqual(policy.finality(of: 20_454), Time.startOfDay(20_492))
        let ledger = [AttributionKey(apiKey: "k", dayIndex: 20_484): Int64(10)]
        let report = [AnalyticsRow(apiKey: "k", dayIndex: 20_484, tokens: 10)]
        XCTAssertEqual(Reconciler.reconcile(ledger: ledger, report: report, now: Time.startOfDay(20_492) - 1).first?.isFinal, false)
        XCTAssertEqual(Reconciler.reconcile(ledger: ledger, report: report, now: Time.startOfDay(20_492)).first?.isFinal, true)
    }

    func testOrdering() {
        let ledger = [AttributionKey(apiKey: "b", dayIndex: 31): Int64(1), AttributionKey(apiKey: "a", dayIndex: 31): 1,
                      AttributionKey(apiKey: "z", dayIndex: 2): 1]
        let findings = Reconciler.reconcile(ledger: ledger, report: [], now: Time.startOfDay(50))
        XCTAssertEqual(findings.map(\.apiKey), ["z", "a", "b"])
        // Day 2 is 3 Jan 1970 (final from 8 Feb, day 38); day 31 is 1 Feb (final from 8 Mar, day 66).
        XCTAssertEqual(findings.map(\.isFinal), [true, false, false])
        XCTAssertTrue(findings.allSatisfy { $0.status.needsAttention })
    }

    /// The README claims reconciliation catches a path that bypasses metering. Feed it a deliberately
    /// broken pipeline — a ledger that silently skips one in five calls — and assert it is caught.
    func testBrokenMeteringIsCaught() {
        var ledger = QuotaLedger(configuration: Fixture.configuration())
        var billed: Int64 = 0
        let start = Time.startOfDay(day) + Time.hour
        for call in 0..<50 {
            let usage = Usage(inputTokens: 300, outputTokens: 100)
            billed += usage.total
            if call % 5 == 0 { continue }   // the bypass: the provider bills it, the ledger never sees it
            let id = RequestID("c\(call)")
            let now = start + Millis(call) * Time.minute
            _ = ledger.authorize(id, key: Fixture.bob, apiKey: "k", estimate: Estimate(inputTokens: 300, maxOutputTokens: 200), now: now)
            _ = ledger.claim(id, key: Fixture.bob, apiKey: "k", now: now)
            _ = ledger.settle(id, key: Fixture.bob, apiKey: "k", usage: usage, now: now)
        }
        let findings = Reconciler.reconcile(ledger: ledger.attribution, report: [row(billed)], now: afterLatency)
        XCTAssertEqual(findings.first?.status, .ledgerUnder(4_000))
        // And the honest pipeline matches, so the check is not just always-red.
        let honest = Reconciler.reconcile(ledger: [key(): billed], report: [row(billed)], now: afterLatency)
        XCTAssertEqual(honest.first?.status, .matched)
    }
}
