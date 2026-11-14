import Foundation
import SSCore
import XCTest
@testable import SSGraph

final class GraphHTTPTests: GraphTestCase {
    func test401InvalidatesTokenAndRetriesOnce() async throws {
        tokens = StubTokenProvider(tokens: ["stale", "fresh"])
        route { request in
            request.header("Authorization") == "Bearer stale"
                ? .json(#"{"error":{"code":"InvalidAuthenticationToken","message":"Access token has expired."}}"#, status: 401)
                : .json(Fixtures.user)
        }

        let profile = try await makeProvider().profile()

        XCTAssertEqual(profile, AccountProfile(email: "robin@example.com", displayName: "Robin Example"))
        XCTAssertEqual(requests.map { $0.header("Authorization") }, ["Bearer stale", "Bearer fresh"])
        XCTAssertEqual(tokens.invalidations, 1)
    }

    func testRepeated401IsUnauthorized() async {
        route { _ in .status(401) }
        await expectProviderError({ try await self.makeProvider().profile() }) { $0.isUnauthorized }
        XCTAssertEqual(requests.count, 2, "exactly one retry")
        XCTAssertEqual(tokens.invalidations, 2)
    }

    func testTokenProviderFailureIsNotRetried() async {
        final class RefusingTokens: AccessTokenProvider {
            func accessToken(for accountID: AccountID) async throws -> String { throw ProviderError.unauthorized }
            func invalidateAccessToken(for accountID: AccountID) async {}
        }
        let provider = GraphProvider(accountID: accountID, tokens: RefusingTokens(), session: StubURLProtocol.makeSession())
        await expectProviderError({ try await provider.profile() }) { $0.isUnauthorized }
        XCTAssertTrue(requests.isEmpty)
    }

    func test429IsThrottledWithRetryAfter() async {
        route { _ in .json(#"{"error":{"code":"TooManyRequests","message":"slow down"}}"#, status: 429, headers: ["Retry-After": "7"]) }
        await expectProviderError({ try await self.makeProvider().profile() }) { $0.retryAfter == 7 }

        route { _ in .status(429) }
        await expectProviderError({ try await self.makeProvider().profile() }) { $0.isThrottled && $0.retryAfter == nil }
    }

    /// Graph throttles with a 503 too when the service is under load; the Retry-After is what marks it.
    func test503WithRetryAfterIsThrottled() async {
        route { _ in .json(#"{"error":{"code":"ServiceUnavailable","message":"busy"}}"#, status: 503, headers: ["Retry-After": "9"]) }
        await expectProviderError({ try await self.makeProvider().profile() }) { $0.retryAfter == 9 }
    }

    func testBatchItem503WithRetryAfterIsThrottled() async {
        route { request in
            self.batchReply(request) { id, _ in
                Fixtures.BatchItem(id: id, status: 503, headers: ["Retry-After": "4"], body: #"{"error":{"code":"ServiceUnavailable","message":"busy"}}"#)
            }
        }
        await expectProviderError({ try await self.makeProvider().apply(.setRead(true), to: ["a"]) }) { $0.retryAfter == 4 }
    }

    func test503And504AreNetwork() async {
        route { _ in .status(503) }
        await expectProviderError({ try await self.makeProvider().profile() }) { $0.isNetwork }
        route { _ in .status(504) }
        await expectProviderError({ try await self.makeProvider().profile() }) { $0.isNetwork }
    }

    /// A gateway failing for now is the service, as 503 and 504 are: the sync line says "slow to respond" rather than
    /// "the server returned an error", a body is fetched again on the next batch, and an operation is never given up for it.
    func test502IsNetworkLike503And504() async {
        route { _ in .json(#"{"error":{"code":"UnknownError","message":""}}"#, status: 502) }
        await expectProviderError({ try await self.makeProvider().profile() }) { $0.isNetwork }
    }

    func testOther5xxIsServerWithGraphCode() async {
        route { _ in .json(#"{"error":{"code":"InternalServerError","message":"boom"}}"#, status: 500) }
        await expectProviderError({ try await self.makeProvider().profile() }) { $0.serverStatus == 500 && $0.serverMessage == "InternalServerError: boom" }
    }

    func test404IsNotFound() async {
        route { _ in .json(Fixtures.notFoundError, status: 404) }
        await expectProviderError({ try await self.makeProvider().body(for: "nope") }) { $0.isNotFound }
    }

    func testMalformedJSONIsDecoding() async {
        route { _ in .json("{\"displayName\": ") }
        await expectProviderError({ try await self.makeProvider().profile() }) { $0.isDecoding }
    }

    func testTransportFailureIsNetwork() async {
        route { _ in .failure(.notConnectedToInternet) }
        await expectProviderError({ try await self.makeProvider().profile() }) { $0.isNetwork }
    }

    func testEveryRequestCarriesBearerAndImmutableIDPreference() async throws {
        route { _ in .json(Fixtures.user) }
        _ = try await makeProvider().profile()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.header("Authorization"), "Bearer token-1")
        XCTAssertEqual(request.header("Prefer"), "IdType=\"ImmutableId\"")
        XCTAssertEqual(request.header("Accept"), "application/json")
        XCTAssertEqual(request.url.absoluteString.hasPrefix("https://graph.microsoft.com/v1.0/"), true)
    }

    func testProviderKindAndAccount() {
        let provider = makeProvider()
        XCTAssertEqual(provider.kind, .microsoft)
        XCTAssertEqual(provider.accountID, accountID)
    }
}
