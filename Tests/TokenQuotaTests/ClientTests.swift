import Dispatch
import Foundation
import XCTest
@testable import TokenQuota

/// Returns scripted decisions in order and can delay specific requests (real concurrency).
actor ScriptedTransport: QuotaTransport {
    var responses: [Decision]
    var calls: [AuthorizeRequest] = []
    private let delayWhenTotal: Int64?

    init(_ responses: [Decision], delayWhenTotal: Int64? = nil) {
        self.responses = responses
        self.delayWhenTotal = delayWhenTotal
    }

    func authorize(_ request: AuthorizeRequest) async throws -> Decision {
        calls.append(request)
        let response = responses.isEmpty ? Decision.denied(Denial(reason: .storeUnavailable, retryAfterMs: nil)) : responses.removeFirst()
        if request.estimate.total == delayWhenTotal {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return response
    }
}

/// Each call follows the next step of a script; a step can wait, then throw or answer.
actor StepTransport: QuotaTransport {
    enum Step: Sendable {
        case answer(Decision)
        case fail(after: UInt64)   // nanoseconds
        /// Waits without observing cancellation, then fails like a transport would.
        case failIgnoringCancellation(after: UInt64)
        case cancel
    }
    private var steps: [Step]
    private(set) var calls = 0

    init(_ steps: [Step]) { self.steps = steps }

    func authorize(_ request: AuthorizeRequest) async throws -> Decision {
        calls += 1
        let step = steps.isEmpty ? Step.fail(after: 0) : steps.removeFirst()
        switch step {
        case .answer(let decision):
            return decision
        case .fail(let nanoseconds):
            if nanoseconds > 0 { try await Task.sleep(nanoseconds: nanoseconds) }
            throw TransportError.unreachable
        case .failIgnoringCancellation(let nanoseconds):
            let deadline = DispatchTime.now().uptimeNanoseconds + nanoseconds
            while DispatchTime.now().uptimeNanoseconds < deadline { await Task.yield() }
            throw TransportError.unreachable
        case .cancel:
            throw CancellationError()
        }
    }
}

/// Distinct IDs on every call, so a client that minted one per *attempt* would be caught.
final class SequentialIDs: @unchecked Sendable {
    // @unchecked Sendable: `value` is only touched under `lock`.
    private let lock = NSLock()
    private var value = 0
    func next() -> RequestID {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return RequestID("id-\(value)")
    }
}

/// Records every backoff the client asks for, without actually sleeping.
final class SleepRecorder: @unchecked Sendable {
    // @unchecked Sendable: `delays` is only touched under `lock`.
    private let lock = NSLock()
    private var delays: [Millis] = []
    var recorded: [Millis] { lock.lock(); defer { lock.unlock() }; return delays }
    func sleep(_ ms: Millis) { lock.lock(); delays.append(ms); lock.unlock() }
}

let noSleep: @Sendable (Millis) async -> Void = { _ in }

final class ClientTests: XCTestCase {
    typealias F = Fixture
    let key = QuotaKey(userID: "bob", feature: "summarize", tier: .pro)

    func grant(_ id: String = "g", daily: Int64 = 10_000, degraded: Bool = false) -> Decision {
        .granted(Grant(requestID: RequestID(id), reservedTokens: 1, burstRemaining: 1, dailyRemaining: daily, degraded: degraded))
    }

    func deny(_ reason: DenialReason, _ retryAfter: Millis?) -> Decision {
        .denied(Denial(reason: reason, retryAfterMs: retryAfter))
    }

    func testLostResponseRetriesWithSameIDAndTheLedgerChargesOnce() async {
        let clock = ManualClock(startingAt: F.t0)
        let gateway = QuotaGateway(configuration: F.configuration(), clock: clock)
        let flaky = FaultInjectingTransport(upstream: gateway, plan: [.responseLost, .unreachable, .none])
        let ids = SequentialIDs()
        let client = QuotaClient(transport: flaky, clock: clock, makeRequestID: { ids.next() }, sleep: noSleep)
        let route = await client.route(key: key, apiKey: "k", estimate: F.est(800))
        guard case .cloud(let grant) = route else { return XCTFail("expected a cloud route, got \(route)") }
        let attempts = await flaky.attempts
        let delivered = await flaky.delivered
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(delivered, 2)
        _ = await gateway.claim(grant.requestID, key: key, apiKey: "k")
        _ = await gateway.settle(grant.requestID, key: key, apiKey: "k", usage: F.use(700))
        let ledger = await gateway.snapshot()
        XCTAssertEqual(ledger.stats.granted, 1)
        XCTAssertEqual(ledger.stats.replays, 1)
        XCTAssertEqual(ledger.dailyUsed(for: key, now: F.t0), 700, "one reservation, settled once")
    }

    func testDedupeIsByRequestIDOnlyNotByPayload() async {
        // Two genuine actions with identical payloads are two reservations. A ledger that deduped on
        // the payload (key + estimate) would silently merge a user's two identical requests.
        let clock = ManualClock(startingAt: F.t0)
        let gateway = QuotaGateway(configuration: F.configuration(), clock: clock)
        _ = await gateway.authorize(AuthorizeRequest(requestID: RequestID("a1"), key: key, apiKey: "k", estimate: F.est(800)))
        _ = await gateway.authorize(AuthorizeRequest(requestID: RequestID("a2"), key: key, apiKey: "k", estimate: F.est(800)))
        let ledger = await gateway.snapshot()
        XCTAssertEqual(ledger.dailyUsed(for: key, now: F.t0), 1_600)
        XCTAssertEqual(ledger.stats.granted, 2)
    }

    func testCooldownShortCircuitsWithoutNetwork() async {
        let clock = ManualClock(startingAt: F.t0)
        let transport = ScriptedTransport([deny(.burstExhausted, 5_000), grant()])
        let client = QuotaClient(transport: transport, clock: clock, sleep: noSleep)
        let first = await client.route(key: key, apiKey: "k", estimate: F.est(100))
        XCTAssertEqual(first, .onDevice(.limited(.burstExhausted)))
        clock.advance(by: 4_999)
        let second = await client.route(key: key, apiKey: "k", estimate: F.est(100))
        XCTAssertEqual(second, .onDevice(.cooldown))
        let callsDuring = await transport.calls.count
        XCTAssertEqual(callsDuring, 1)
        clock.advance(by: 1)
        let third = await client.route(key: key, apiKey: "k", estimate: F.est(100))
        XCTAssertTrue(third.isCloud)
        let local = await client.localDecisions
        XCTAssertEqual(local, 1)
    }

    func testConcurrentRoutesKeepTheLaterCooldown() async {
        // B starts first and is slow; A returns quickly with a 60 s Retry-After; B then returns 10 s.
        // If B overwrote the cooldown, the feature would be back on the network after 10 s.
        let clock = ManualClock(startingAt: F.t0)
        let transport = ScriptedTransport([deny(.burstExhausted, 10_000), deny(.burstExhausted, 60_000)], delayWhenTotal: 2)
        let client = QuotaClient(transport: transport, clock: clock, sleep: noSleep)
        let key = self.key
        let slow = Task { await client.route(key: key, apiKey: "k", estimate: F.est(2)) }
        while await transport.calls.count < 1 { await Task.yield() }
        let fast = await client.route(key: key, apiKey: "k", estimate: F.est(1))
        _ = await slow.value
        XCTAssertEqual(fast, .onDevice(.limited(.burstExhausted)))
        let cooldown = await client.cooldown(for: key.feature)
        XCTAssertEqual(cooldown, F.t0 + 60_000)
        clock.advance(by: 20_000)
        let later = await client.route(key: key, apiKey: "k", estimate: F.est(1))
        XCTAssertEqual(later, .onDevice(.cooldown))
    }

    func testARetryRechecksTheCooldownAfterEverySuspension() async {
        // A's first attempt is in flight (and will fail) when B gets a 429 with a 60 s Retry-After.
        // A must not send its second attempt into that cooldown.
        let clock = ManualClock(startingAt: F.t0)
        let transport = StepTransport([.fail(after: 200_000_000), .answer(deny(.burstExhausted, 60_000))])
        let client = QuotaClient(transport: transport, clock: clock, sleep: noSleep)
        let key = self.key
        let a = Task { await client.route(key: key, apiKey: "k", estimate: F.est(2)) }
        while await transport.calls < 1 { await Task.yield() }
        let b = await client.route(key: key, apiKey: "k", estimate: F.est(1))
        XCTAssertEqual(b, .onDevice(.limited(.burstExhausted)))
        let resultA = await a.value
        XCTAssertEqual(resultA, .onDevice(.cooldown))
        let calls = await transport.calls
        XCTAssertEqual(calls, 2, "A's retry stayed on the phone")
    }

    func testRetriesBackOffWithCappedJitterAndTotalFailureCoolsTheFeatureDown() async {
        let clock = ManualClock(startingAt: F.t0)
        let gateway = QuotaGateway(configuration: F.configuration(), clock: clock)
        let dead = FaultInjectingTransport(upstream: gateway, plan: Array(repeating: .unreachable, count: 10))
        let recorder = SleepRecorder()
        let policy = ClientPolicy(maxAttempts: 4, retryBaseDelayMs: 100, retryMaxDelayMs: 250,
                                  onDevice: OnDeviceCapability(available: false, maxTokens: 0))
        let client = QuotaClient(transport: dead, clock: clock, policy: policy,
                                 sleep: { recorder.sleep($0) }, jitter: { $0 })   // jitter at its upper bound
        let route = await client.route(key: key, apiKey: "k", estimate: F.est(10))
        XCTAssertEqual(route, .tryLater(untilMs: F.t0 + 30_000, .transportFailed))
        XCTAssertEqual(recorder.recorded, [100, 200, 250], "doubling, capped at 250")
        // The backend is dead: the next call from a looping caller doesn't even try.
        let next = await client.route(key: key, apiKey: "k", estimate: F.est(10))
        XCTAssertEqual(next, .tryLater(untilMs: F.t0 + 30_000, .cooldown))
        let attempts = await dead.attempts
        XCTAssertEqual(attempts, 4)
    }

    func testZeroAttemptsMeansOneAndJitterNeverExceedsTheCap() async {
        let clock = ManualClock(startingAt: F.t0)
        let transport = StepTransport([])
        let recorder = SleepRecorder()
        let policy = ClientPolicy(maxAttempts: 0, retryBaseDelayMs: .max, retryMaxDelayMs: 50)
        let client = QuotaClient(transport: transport, clock: clock, policy: policy,
                                 sleep: { recorder.sleep($0) }, jitter: { _ in .max })   // a misbehaving jitter
        _ = await client.route(key: key, apiKey: "k", estimate: F.est(10))
        let calls = await transport.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(recorder.recorded, [])

        let retrying = QuotaClient(transport: StepTransport([]), clock: clock,
                                   policy: ClientPolicy(maxAttempts: 2, retryBaseDelayMs: .max, retryMaxDelayMs: 50),
                                   sleep: { recorder.sleep($0) }, jitter: { _ in .max })
        _ = await retrying.route(key: QuotaKey(userID: "x", feature: "other", tier: .pro), apiKey: "k", estimate: F.est(10))
        XCTAssertEqual(recorder.recorded, [50])
    }

    func testAttemptsAreCappedAtTen() async {
        let clock = ManualClock(startingAt: F.t0)
        let gateway = QuotaGateway(configuration: F.configuration(), clock: clock)
        let dead = FaultInjectingTransport(upstream: gateway, plan: Array(repeating: .unreachable, count: 50))
        let client = QuotaClient(transport: dead, clock: clock, policy: ClientPolicy(maxAttempts: .max), sleep: noSleep)
        _ = await client.route(key: key, apiKey: "k", estimate: F.est(10))
        let attempts = await dead.attempts
        XCTAssertEqual(attempts, 10)
    }

    func testCancellationStopsRetrying() async {
        let clock = ManualClock(startingAt: F.t0)
        let transport = StepTransport([.cancel, .answer(grant())])
        let client = QuotaClient(transport: transport, clock: clock, sleep: noSleep)
        let route = await client.route(key: key, apiKey: "k", estimate: F.est(10))
        XCTAssertEqual(route, .cancelled)
        let calls = await transport.calls
        XCTAssertEqual(calls, 1)
    }

    func testCancellationDuringTheBackoffIsHonoured() async {
        let clock = ManualClock(startingAt: F.t0)
        let transport = StepTransport([.fail(after: 0), .answer(grant())])
        // A real 300 ms backoff, so the cancellation lands while the client is waiting in it.
        let client = QuotaClient(transport: transport, clock: clock,
                                 policy: ClientPolicy(retryBaseDelayMs: 300, retryMaxDelayMs: 300),
                                 sleep: QuotaClient.taskSleep, jitter: { $0 })
        let key = self.key
        let task = Task { await client.route(key: key, apiKey: "k", estimate: F.est(10)) }
        while await transport.calls < 1 { await Task.yield() }
        task.cancel()
        let route = await task.value
        XCTAssertEqual(route, .cancelled)
        let calls = await transport.calls
        XCTAssertEqual(calls, 1, "no second attempt after the cancelled backoff")
    }

    func testCancellationSurfacingAsATransportErrorIsNotRetried() async {
        // URLSession reports a cancelled task as URLError(.cancelled), not CancellationError.
        let clock = ManualClock(startingAt: F.t0)
        let transport = StepTransport([.failIgnoringCancellation(after: 200_000_000), .answer(grant())])
        let recorder = SleepRecorder()
        let client = QuotaClient(transport: transport, clock: clock, sleep: { recorder.sleep($0) })
        let key = self.key
        let task = Task { await client.route(key: key, apiKey: "k", estimate: F.est(10)) }
        while await transport.calls < 1 { await Task.yield() }
        task.cancel()
        let route = await task.value
        XCTAssertEqual(route, .cancelled)
        XCTAssertEqual(recorder.recorded, [], "it didn't even start a backoff")
    }

    func testAnAlreadyCancelledTaskMakesNoNetworkCall() async {
        let clock = ManualClock(startingAt: F.t0)
        let transport = StepTransport([.answer(grant())])
        let client = QuotaClient(transport: transport, clock: clock, sleep: noSleep)
        let key = self.key
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await client.route(key: key, apiKey: "k", estimate: F.est(10))
        }
        let route = await task.value
        XCTAssertEqual(route, .cancelled)
        let calls = await transport.calls
        XCTAssertEqual(calls, 0)
    }

    func testBudgetPrecheckTrustsOnlyAFreshSnapshot() async {
        let clock = ManualClock(startingAt: F.t0)
        let transport = ScriptedTransport([grant(daily: 500), grant(daily: 500)])
        let client = QuotaClient(transport: transport, clock: clock, sleep: noSleep)
        _ = await client.route(key: key, apiKey: "k", estimate: F.est(100))
        let blocked = await client.route(key: key, apiKey: "k", estimate: F.est(501))
        XCTAssertEqual(blocked, .onDevice(.budgetPrecheck))
        let noModel = QuotaClient(transport: ScriptedTransport([grant(daily: 500)]), clock: clock,
                                  policy: ClientPolicy(onDevice: OnDeviceCapability(available: false, maxTokens: 0)), sleep: noSleep)
        _ = await noModel.route(key: key, apiKey: "k", estimate: F.est(100))
        let wait = await noModel.route(key: key, apiKey: "k", estimate: F.est(501))
        XCTAssertEqual(wait, .tryLater(untilMs: F.t0 + 10_001, .budgetPrecheck), "until the snapshot goes stale, not until tomorrow")
        var calls = await transport.calls.count
        XCTAssertEqual(calls, 1)
        // The same snapshot, now stale, must not block: the request goes to the network.
        clock.advance(by: 11_000)
        _ = await client.route(key: key, apiKey: "k", estimate: F.est(501))
        calls = await transport.calls.count
        XCTAssertEqual(calls, 2)
    }

    func testAnOlderSnapshotNeverOverwritesANewerOne() async {
        // The clock steps back between two grants: the earlier observation must not win.
        let clock = ManualClock(startingAt: F.t0 + 1_000)
        let transport = ScriptedTransport([grant(daily: 500), grant(daily: 9_000)])
        let client = QuotaClient(transport: transport, clock: clock, sleep: noSleep)
        _ = await client.route(key: key, apiKey: "k", estimate: F.est(100))   // observed at t0+1000: 500 left
        clock.set(F.t0 + 500)
        _ = await client.route(key: key, apiKey: "k", estimate: F.est(100))   // observed "earlier": 9,000 left
        let snapshot = await client.snapshot(for: key)
        XCTAssertEqual(snapshot?.dailyRemaining, 500)
        XCTAssertEqual(snapshot?.observedAtMs, F.t0 + 1_000)
    }

    func testDegradedGrantDoesNotFeedThePrecheck() async {
        let clock = ManualClock(startingAt: F.t0)
        let transport = ScriptedTransport([grant(daily: 10, degraded: true), grant()])
        let client = QuotaClient(transport: transport, clock: clock, sleep: noSleep)
        _ = await client.route(key: key, apiKey: "k", estimate: F.est(5))
        let snapshot = await client.snapshot(for: key)
        XCTAssertNil(snapshot)
        let next = await client.route(key: key, apiKey: "k", estimate: F.est(100))
        XCTAssertTrue(next.isCloud)
    }

    func testPermanentDenialDoesNotCoolDownTheFeature() async {
        let clock = ManualClock(startingAt: F.t0)
        let transport = ScriptedTransport([deny(.requestTooLarge, nil), grant()])
        let client = QuotaClient(transport: transport, clock: clock, sleep: noSleep)
        let big = await client.route(key: key, apiKey: "k", estimate: F.est(100_000))
        XCTAssertEqual(big, .unavailable(.requestTooLarge), "permanent: not dressed up as 'try again now'")
        let cooldown = await client.cooldown(for: key.feature)
        XCTAssertNil(cooldown)
        let small = await client.route(key: key, apiKey: "k", estimate: F.est(10))
        XCTAssertTrue(small.isCloud)
    }

    func testRetryAfterIsCappedAndMissingRetryAfterUsesDefault() async {
        let clock = ManualClock(startingAt: F.t0)
        let policy = ClientPolicy(defaultCooldownMs: 7_000, maxCooldownMs: 60_000)
        let transport = ScriptedTransport([deny(.dailyBudgetExhausted, .max), deny(.storeUnavailable, nil)])
        let client = QuotaClient(transport: transport, clock: clock, policy: policy, sleep: noSleep)
        _ = await client.route(key: key, apiKey: "k", estimate: F.est(1))
        let capped = await client.cooldown(for: key.feature)
        XCTAssertEqual(capped, F.t0 + 60_000)
        clock.advance(by: 60_000)
        _ = await client.route(key: key, apiKey: "k", estimate: F.est(1))
        let defaulted = await client.cooldown(for: key.feature)
        XCTAssertEqual(defaulted, F.t0 + 67_000)
    }

    func testOnDeviceOnlyForJobsTheLocalModelCanHandle() async {
        let clock = ManualClock(startingAt: F.t0)
        let transport = ScriptedTransport([deny(.burstExhausted, 1_000)])
        let policy = ClientPolicy(onDevice: OnDeviceCapability(available: true, maxTokens: 50))
        let client = QuotaClient(transport: transport, clock: clock, policy: policy, sleep: noSleep)
        let big = await client.route(key: key, apiKey: "k", estimate: F.est(51))
        XCTAssertEqual(big, .tryLater(untilMs: F.t0 + 1_000, .limited(.burstExhausted)))
        let small = await client.route(key: key, apiKey: "k", estimate: F.est(50))
        XCTAssertEqual(small, .onDevice(.cooldown))
    }
}
