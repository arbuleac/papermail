import XCTest
@testable import SSCore

final class TokenManagerTests: XCTestCase {
    private let accountID = AccountID("acct-1")
    private let issuedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private var directory: URL!
    private var configurations: ClientConfigurationStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appending(path: "ss-token-manager-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: "oauth-clients.json")
        try Data("""
        {"google": {"clientID": "google-client", "clientSecret": "google-secret"},
         "microsoft": {"clientID": "ms-client", "tenant": "common"}}
        """.utf8).write(to: fileURL)
        configurations = ClientConfigurationStore(fileURL: fileURL)
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeManager(kind: ProviderKind = .gmail, tokens: OAuthTokens?) -> (TokenManager, InMemoryTokenStore) {
        let store = InMemoryTokenStore()
        if let tokens { try? store.save(tokens, for: accountID) }
        let now = issuedAt
        let manager = TokenManager(
            tokenStore: store,
            configurations: configurations,
            kinds: { _ in kind },
            session: StubURLProtocol.makeSession(),
            now: { now }
        )
        return (manager, store)
    }

    private func tokens(expiringIn seconds: TimeInterval, refreshToken: String? = "rt-1") -> OAuthTokens {
        OAuthTokens(accessToken: "at-1", refreshToken: refreshToken, expiresAt: issuedAt.addingTimeInterval(seconds), scope: "scope-1")
    }

    private func installRefreshReply(_ json: String = #"{"access_token":"at-2","expires_in":3600,"token_type":"Bearer"}"#, delay: TimeInterval = 0) {
        StubURLProtocol.install { _ in
            if delay > 0 { Thread.sleep(forTimeInterval: delay) }
            return StubURLProtocol.Reply(json: json)
        }
    }

    private func assertAccessToken(_ manager: TokenManager, equals expected: String, line: UInt = #line) async {
        do {
            let token = try await manager.accessToken(for: accountID)
            XCTAssertEqual(token, expected, line: line)
        } catch {
            XCTFail("unexpected \(error)", line: line)
        }
    }

    func testReturnsCachedTokenWhenFarFromExpiry() async throws {
        installRefreshReply()
        let (manager, _) = makeManager(tokens: tokens(expiringIn: 3600))
        let token = try await manager.accessToken(for: accountID)
        XCTAssertEqual(token, "at-1")
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testRefreshesWhenWithinLeeway() async throws {
        installRefreshReply()
        let (manager, store) = makeManager(tokens: tokens(expiringIn: 59))
        let token = try await manager.accessToken(for: accountID)
        XCTAssertEqual(token, "at-2")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url, OAuthEndpoints.googleTokenURL)
        XCTAssertEqual(request.form["grant_type"], "refresh_token")
        XCTAssertEqual(request.form["refresh_token"], "rt-1")
        XCTAssertEqual(request.form["client_id"], "google-client")
        XCTAssertEqual(request.form["client_secret"], "google-secret")
        XCTAssertNil(request.form["scope"])
        let saved = try XCTUnwrap(store.tokens(for: accountID))
        XCTAssertEqual(saved.accessToken, "at-2")
        XCTAssertEqual(saved.expiresAt, issuedAt.addingTimeInterval(3600))
        // A second call is served from the refreshed cache.
        let again = try await manager.accessToken(for: accountID)
        XCTAssertEqual(again, "at-2")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testExpiredTokenIsRefreshed() async throws {
        installRefreshReply()
        let (manager, _) = makeManager(tokens: tokens(expiringIn: -10))
        await assertAccessToken(manager, equals: "at-2")
    }

    func testConcurrentCallersShareOneRefresh() async throws {
        installRefreshReply(delay: 0.2)
        let (manager, _) = makeManager(tokens: tokens(expiringIn: 10))
        let results = try await withThrowingTaskGroup(of: String.self) { group -> [String] in
            for _ in 0 ..< 12 {
                group.addTask { try await manager.accessToken(for: self.accountID) }
            }
            var collected: [String] = []
            for try await token in group { collected.append(token) }
            return collected
        }
        XCTAssertEqual(results.count, 12)
        XCTAssertTrue(results.allSatisfy { $0 == "at-2" })
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testKeepsOldRefreshTokenWhenResponseOmitsIt() async throws {
        installRefreshReply(#"{"access_token":"at-2","expires_in":3600}"#)
        let (manager, store) = makeManager(kind: .microsoft, tokens: tokens(expiringIn: 5))
        await assertAccessToken(manager, equals: "at-2")
        let saved = try XCTUnwrap(store.tokens(for: accountID))
        XCTAssertEqual(saved.refreshToken, "rt-1")
        XCTAssertEqual(saved.scope, "scope-1")
    }

    func testAdoptsRotatedRefreshToken() async throws {
        installRefreshReply(#"{"access_token":"at-2","refresh_token":"rt-2","expires_in":3600,"scope":"scope-2"}"#)
        let (manager, store) = makeManager(kind: .microsoft, tokens: tokens(expiringIn: 5))
        await assertAccessToken(manager, equals: "at-2")
        let saved = try XCTUnwrap(store.tokens(for: accountID))
        XCTAssertEqual(saved.refreshToken, "rt-2")
        XCTAssertEqual(saved.scope, "scope-2")
    }

    func testMicrosoftRefreshSendsScopeAndNoSecret() async throws {
        installRefreshReply()
        let (manager, _) = makeManager(kind: .microsoft, tokens: tokens(expiringIn: 5))
        _ = try await manager.accessToken(for: accountID)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url, OAuthEndpoints.microsoftTokenURL(tenant: "common"))
        XCTAssertEqual(request.form["client_id"], "ms-client")
        XCTAssertNil(request.form["client_secret"])
        XCTAssertEqual(request.form["scope"], "scope-1")
    }

    func testInvalidGrantMapsToUnauthorized() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Reply(status: 400, json: #"{"error":"invalid_grant","error_description":"expired"}"#)
        }
        let (manager, _) = makeManager(tokens: tokens(expiringIn: 5))
        do {
            _ = try await manager.accessToken(for: accountID)
            XCTFail("expected unauthorized")
        } catch ProviderError.unauthorized {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testOtherServerErrorsMapToRefreshFailed() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Reply(status: 400, json: #"{"error":"invalid_client","error_description":"bad client"}"#)
        }
        let (manager, _) = makeManager(tokens: tokens(expiringIn: 5))
        do {
            _ = try await manager.accessToken(for: accountID)
            XCTFail("expected refreshFailed")
        } catch AuthError.refreshFailed(let message) {
            XCTAssertTrue(message.contains("invalid_client"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTransportFailureMapsToNetwork() async {
        StubURLProtocol.install { _ in throw URLError(.notConnectedToInternet) }
        let (manager, _) = makeManager(tokens: tokens(expiringIn: 5))
        do {
            _ = try await manager.accessToken(for: accountID)
            XCTFail("expected network error")
        } catch ProviderError.network {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testMissingTokensOrRefreshTokenIsUnauthorized() async {
        installRefreshReply()
        let (noTokens, _) = makeManager(tokens: nil)
        do {
            _ = try await noTokens.accessToken(for: accountID)
            XCTFail("expected unauthorized")
        } catch ProviderError.unauthorized {} catch { XCTFail("unexpected \(error)") }

        let (noRefresh, _) = makeManager(tokens: tokens(expiringIn: 5, refreshToken: nil))
        do {
            _ = try await noRefresh.accessToken(for: accountID)
            XCTFail("expected unauthorized")
        } catch ProviderError.unauthorized {} catch { XCTFail("unexpected \(error)") }
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testInvalidateForcesRefreshOfFreshToken() async throws {
        installRefreshReply()
        let (manager, _) = makeManager(tokens: tokens(expiringIn: 3600))
        await assertAccessToken(manager, equals: "at-1")
        await manager.invalidateAccessToken(for: accountID)
        await assertAccessToken(manager, equals: "at-2")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        await assertAccessToken(manager, equals: "at-2")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testFailedRefreshIsRetriedOnNextCall() async throws {
        StubURLProtocol.install { _ in throw URLError(.timedOut) }
        let (manager, _) = makeManager(tokens: tokens(expiringIn: 5))
        _ = try? await manager.accessToken(for: accountID)
        installRefreshReply()
        await assertAccessToken(manager, equals: "at-2")
    }

    func testStoreAndRemoveTokens() async throws {
        installRefreshReply()
        let (manager, store) = makeManager(tokens: nil)
        try await manager.store(tokens(expiringIn: 3600), for: accountID)
        await assertAccessToken(manager, equals: "at-1")
        XCTAssertNotNil(try store.tokens(for: accountID))
        try await manager.removeTokens(for: accountID)
        XCTAssertNil(try store.tokens(for: accountID))
        do {
            _ = try await manager.accessToken(for: accountID)
            XCTFail("expected unauthorized")
        } catch ProviderError.unauthorized {} catch { XCTFail("unexpected \(error)") }
    }

    func testUnknownAccountKindIsNotFound() async {
        installRefreshReply()
        let store = InMemoryTokenStore()
        try? store.save(tokens(expiringIn: 5), for: accountID)
        let now = issuedAt
        let manager = TokenManager(tokenStore: store, configurations: configurations, kinds: { _ in nil }, session: StubURLProtocol.makeSession(), now: { now })
        do {
            _ = try await manager.accessToken(for: accountID)
            XCTFail("expected notFound")
        } catch ProviderError.notFound {} catch { XCTFail("unexpected \(error)") }
    }
}
