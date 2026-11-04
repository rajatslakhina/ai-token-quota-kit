import Foundation
import XCTest
import TokenQuota   // deliberately NOT `@testable`: this target sees only the public API, like an app does

/// An app's HTTPS transport minus the HTTP: the request and the `Decision` both cross a JSON wire.
/// If a type a transport needs lacked a public initializer or `Codable`, this file would not compile.
struct JSONLoopbackTransport: QuotaTransport {
    let server: QuotaGateway

    func authorize(_ request: AuthorizeRequest) async throws -> Decision {
        let sent = try JSONEncoder().encode(request)
        let received = try JSONDecoder().decode(AuthorizeRequest.self, from: sent)
        let decision = await server.authorize(received)
        let body = try JSONEncoder().encode(decision)
        return try JSONDecoder().decode(Decision.self, from: body)
    }
}

/// The integration the README describes: the app sends only the request ID, the feature and the
/// prompt (`payload`); the "backend" derives the user, tier, API key, estimate and digest itself.
struct PromptCarryingTransport: QuotaTransport {
    struct Wire: Codable { let requestID: RequestID; let feature: String; let prompt: Data }
    let server: QuotaGateway
    let sessionUser: String

    func authorize(_ request: AuthorizeRequest) async throws -> Decision {
        guard let prompt = request.payload else { return .denied(Denial(reason: .invalidEstimate, retryAfterMs: nil)) }
        let body = try JSONEncoder().encode(Wire(requestID: request.requestID, feature: request.key.feature, prompt: prompt))
        // --- server side ---
        let wire = try JSONDecoder().decode(Wire.self, from: body)
        let key = QuotaKey(userID: sessionUser, feature: wire.feature, tier: .pro)       // from the session + entitlements
        let counted = Int64(wire.prompt.count)                                          // stands in for count_tokens
        let digest = "len:\(wire.prompt.count)"                                          // stands in for a SHA-256
        let decision = await server.authorize(AuthorizeRequest(requestID: wire.requestID, key: key, apiKey: "apikey_backend",
                                                               estimate: Estimate(inputTokens: counted, maxOutputTokens: 100),
                                                               promptDigest: digest))
        return try JSONDecoder().decode(Decision.self, from: JSONEncoder().encode(decision))
    }
}

/// A transport written the way an app would write a stub, from public initializers only.
struct CannedTransport: QuotaTransport {
    func authorize(_ request: AuthorizeRequest) async throws -> Decision {
        request.estimate.total > 1_000
            ? .denied(Denial(reason: .burstExhausted, retryAfterMs: 2_000))
            : .granted(Grant(requestID: request.requestID, reservedTokens: request.estimate.total,
                             burstRemaining: 10, dailyRemaining: 100, degraded: false))
    }
}

final class PublicAPITests: XCTestCase {
    let key = QuotaKey(userID: "u1", feature: "summarize", tier: .pro)

    func configuration() -> LedgerConfiguration {
        LedgerConfiguration(
            policies: [.pro: TierPolicy(burst: BucketLimit(capacity: 10_000, refillPerSecond: 100),
                                        dailyBudget: 100_000, maxSingleRequest: 8_000,
                                        outage: .failOpenBounded(allowanceTokens: 1_000))],
            price: PriceTable(inputMicroUSDPerMTok: 3_000_000, outputMicroUSDPerMTok: 15_000_000),
            orgSpendLimitMicroUSD: 1_000_000)
    }

    func testClientWorksThroughACodableWireFormat() async {
        let clock = ManualClock(startingAt: 30 * Time.day)
        let gateway = QuotaGateway(configuration: configuration(), clock: clock)
        let client = QuotaClient(transport: JSONLoopbackTransport(server: gateway), clock: clock)
        let route = await client.route(key: key, apiKey: "key-summarize", estimate: Estimate(inputTokens: 900, maxOutputTokens: 100))
        guard case .cloud(let grant) = route else { return XCTFail("expected a cloud route, got \(route)") }
        XCTAssertEqual(grant.reservedTokens, 1_000)
        guard case .claimed = await gateway.claim(grant.requestID, key: key, apiKey: "key-summarize") else { return XCTFail("claim failed") }
        let outcome = await gateway.settle(grant.requestID, key: key, apiKey: "key-summarize",
                                           usage: Usage(inputTokens: 900, outputTokens: 40))
        XCTAssertEqual(outcome, .settled(charged: 940, adjustment: -60, persistence: .applied))
    }

    func testThePromptTravelsWithTheRequestAndTheBackendOwnsEverythingElse() async {
        let clock = ManualClock(startingAt: 30 * Time.day)
        let gateway = QuotaGateway(configuration: configuration(), clock: clock)
        let client = QuotaClient(transport: PromptCarryingTransport(server: gateway, sessionUser: "u-from-session"), clock: clock)
        let prompt = Data(repeating: 65, count: 400)
        // The app passes no API key, and its tier is only used for its own local decisions.
        let route = await client.route(key: QuotaKey(userID: "whatever-the-app-says", feature: "summarize", tier: .free),
                                       estimate: Estimate(inputTokens: 1, maxOutputTokens: 1), payload: prompt)
        guard case .cloud(let grant) = route else { return XCTFail("expected a cloud route, got \(route)") }
        XCTAssertEqual(grant.reservedTokens, 500, "the backend's own count (400 + 100), not the app's estimate")
        let serverKey = QuotaKey(userID: "u-from-session", feature: "summarize", tier: .pro)
        let wrongPrompt = await gateway.claim(grant.requestID, key: serverKey, apiKey: "apikey_backend", promptDigest: "len:999")
        XCTAssertEqual(wrongPrompt, .mismatch)
        guard case .claimed = await gateway.claim(grant.requestID, key: serverKey, apiKey: "apikey_backend", promptDigest: "len:400") else {
            return XCTFail("the backend's claim for the counted prompt must succeed")
        }
    }

    func testAnAppDefinedTransportCanBuildEveryResponse() async {
        let clock = ManualClock(startingAt: 0)
        let client = QuotaClient(transport: CannedTransport(), clock: clock,
                                 policy: ClientPolicy(onDevice: OnDeviceCapability(available: true, maxTokens: 4_000)))
        let big = await client.route(key: key, apiKey: "k", estimate: Estimate(inputTokens: 2_000, maxOutputTokens: 0))
        XCTAssertEqual(big, .onDevice(.limited(.burstExhausted)))
        let other = QuotaKey(userID: "u1", feature: "translate", tier: .pro)
        let small = await client.route(key: other, apiKey: "k", estimate: Estimate(inputTokens: 10, maxOutputTokens: 0))
        XCTAssertTrue(small.isCloud)
    }

    func testDenialsRoundTripThroughJSONWithTheirReason() throws {
        let decision = Decision.denied(Denial(reason: .orgSpendBreakerOpen, retryAfterMs: 880_000))
        let decoded = try JSONDecoder().decode(Decision.self, from: JSONEncoder().encode(decision))
        XCTAssertEqual(decoded, decision)
        let claim = ClaimResult.claimed(Grant(requestID: RequestID("r"), reservedTokens: 1, burstRemaining: 0,
                                              dailyRemaining: 0, degraded: true))
        XCTAssertEqual(try JSONDecoder().decode(ClaimResult.self, from: JSONEncoder().encode(claim)), claim)
    }

    func testHTTPStatusSeparatesLimitsFromRequestsThatCanNeverSucceed() {
        for reason in DenialReason.allCases {
            if reason.isTransient {
                XCTAssertTrue([429, 503].contains(reason.httpStatus), "\(reason) is transient but maps to \(reason.httpStatus)")
            } else {
                XCTAssertTrue((400..<500).contains(reason.httpStatus) && reason.httpStatus != 429,
                              "\(reason) is permanent but maps to \(reason.httpStatus)")
            }
        }
        XCTAssertEqual(DenialReason.storeUnavailable.httpStatus, 503)
        XCTAssertEqual(DenialReason.requestTooLarge.httpStatus, 413)
        XCTAssertEqual(DenialReason.alreadyClaimed.httpStatus, 409)
    }
}
