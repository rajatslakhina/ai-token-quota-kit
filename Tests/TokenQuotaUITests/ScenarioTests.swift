import XCTest
import TokenQuota
@testable import TokenQuotaUI

/// Each scenario is what the demo app shows. These assert the outcome its README promises,
/// computed by the real gateway + client — not by the scenario's own headline string.
final class ScenarioTests: XCTestCase {
    func testRunawayAgentIsThrottledLocallyThenResumes() async {
        let report = await ScenarioRunner.run(.runawayAgent)
        let c = report.counts
        XCTAssertEqual(c["limited"], 1, "exactly one 429 reached the phone")
        XCTAssertEqual(c["onDevice"], 8)
        XCTAssertEqual(c["localDecisions"], 7, "the rest never touched the network")
        XCTAssertEqual(c["cloud"], 5, "4 before the limit + 1 after the Retry-After")
        XCTAssertEqual(c["networkAttempts"], 6)
        XCTAssertTrue(report.events.contains { $0.text.contains("Retry-After 15.0 s") })
        XCTAssertTrue(report.headline.hasPrefix("7 of 8 throttled calls were answered on the phone"))
    }

    func testDeviceWithoutModelWaitsInsteadOfRunningLocally() async {
        let report = await ScenarioRunner.run(.runawayAgent, onDevice: OnDeviceCapability(available: false, maxTokens: 0))
        let c = report.counts
        XCTAssertEqual(c["onDevice"], 0)
        XCTAssertEqual(c["tryLater"], 8)
        XCTAssertEqual(c["limited"], 1)
        XCTAssertEqual(c["localDecisions"], 7, "the cooldown still keeps the calls off the network")
        XCTAssertTrue(report.headline.hasPrefix("7 of 8 throttled calls were held on the phone"), report.headline)
        XCTAssertFalse(report.events.contains { $0.text.contains("TokenQuota.") }, "no raw enum dumps on screen")
    }

    func testOutageFailsClosedForFreeOpenForProAndLosesNothing() async {
        let report = await ScenarioRunner.run(.storeOutage)
        let c = report.counts
        XCTAssertEqual(c["freeDenied"], 1)
        XCTAssertEqual(c["proGranted"], 2)
        XCTAssertEqual(c["proDenied"], 1)
        XCTAssertEqual(c["journaled"], 2)
        XCTAssertEqual(c["replayed"], 2)
        XCTAssertEqual(c["proUsed"], 6_800, "both actual usages charged after recovery")
        XCTAssertEqual(c["lostTokens"], 0)
        XCTAssertTrue(report.events.contains { $0.text.contains("settled 3,400 → journaled") })
    }

    func testLostResponseCostsOneReservationOneModelCallAndOneCharge() async {
        let report = await ScenarioRunner.run(.lostResponse)
        let c = report.counts
        XCTAssertEqual(c["cloud"], 1)
        XCTAssertEqual(c["attempts"], 3)
        XCTAssertEqual(c["granted"], 1)
        XCTAssertEqual(c["replays"], 1)
        XCTAssertEqual(c["modelCalls"], 1, "the raced completion handler was refused")
        XCTAssertEqual(c["duplicateClaims"], 1)
        XCTAssertEqual(c["charges"], 1)
        XCTAssertEqual(c["duplicates"], 1)
        XCTAssertEqual(c["used"], 3_640)
    }

    func testVelocityBreakerStopsSpendThatAdmissionAloneWouldHaveAllowed() async {
        let report = await ScenarioRunner.run(.orgBreaker)
        let c = report.counts
        XCTAssertEqual(c["velocityTrip"], 1)
        XCTAssertEqual(c["tripSeat"], 12)
        XCTAssertEqual(c["tripSpend"], 2_160_000)
        XCTAssertEqual(c["tripMinutes"], 4)
        XCTAssertEqual(c["refused"], 15, "seats 13–27, until on-call reset the breaker")
        XCTAssertEqual(c["admitted"], 15)
        XCTAssertEqual(c["spent"], 2_700_000)
        XCTAssertEqual(c["trips"], 1)
        // The counterfactual is measured, not asserted: the same traffic with admission only.
        XCTAssertEqual(c["unguardedAdmitted"], 28)
        XCTAssertEqual(c["unguardedSpent"], 5_040_000)
        XCTAssertEqual(c["unguardedOverspendTrip"], 1)
        XCTAssertTrue(report.headline.contains("$2.16") && report.headline.contains("$5.04"), report.headline)
    }

    func testReconcileFlagsBypassAndUnknownKeyButNotLag() async {
        let report = await ScenarioRunner.run(.reconcile)
        let c = report.counts
        XCTAssertEqual(c["findings"], 7)
        XCTAssertEqual(c["matched"], 3)
        XCTAssertEqual(c["awaiting"], 2)
        XCTAssertEqual(c["attention"], 2)
        XCTAssertTrue(report.findings.contains { $0.apiKey == "key-translate" && $0.status == .ledgerUnder(8_280) })
        XCTAssertTrue(report.findings.contains { $0.apiKey == "key-batch" && $0.status == .unknownKey(250_000) })
    }

    func testLaunchArgumentParsing() {
        XCTAssertEqual(Scenario(arguments: ["app", "-scenario", "reconcile"]), .reconcile)
        XCTAssertNil(Scenario(arguments: ["app", "-scenario"]))
        XCTAssertNil(Scenario(arguments: ["app", "-scenario", "nope"]))
        XCTAssertNil(Scenario(arguments: []))
    }

    func testFormatting() {
        XCTAssertEqual(ScenarioRunner.formatSeconds(15_000), "15.0 s")
        XCTAssertEqual(ScenarioRunner.formatSeconds(-5), "0.0 s")
        XCTAssertEqual(ScenarioRunner.formatSeconds(.max), "9223372036854775.8 s")
        XCTAssertEqual(ScenarioRunner.formatDollars(5_040_000), "$5.04")
        XCTAssertEqual(ScenarioRunner.formatDollars(50_000), "$0.05")
        XCTAssertEqual(ScenarioRunner.formatDollars(.max), "$9223372036854.77")
        XCTAssertEqual(ScenarioRunner.formatTokens(0), "0")
        XCTAssertEqual(ScenarioRunner.formatTokens(999), "999")
        XCTAssertEqual(ScenarioRunner.formatTokens(92_000), "92,000")
        XCTAssertEqual(ScenarioRunner.formatTokens(-1_234_567), "-1,234,567")
        XCTAssertEqual(ScenarioRunner.formatTokens(.min), "-9,223,372,036,854,775,808")
    }
}
