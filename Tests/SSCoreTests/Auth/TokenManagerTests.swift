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

    /// What a provider reads before replaying an answer, without a request: the scopes stored with the token.
    func testGrantedScopesComeFromTheStoredTokens() async {
        let (manager, _) = makeManager(tokens: tokens(expiringIn: 3_600))
        let scopes = await manager.grantedScopes(for: accountID)
        XCTAssertEqual(scopes, "scope-1")
        let (empty, _) = makeManager(tokens: nil)
        let none = await empty.grantedScopes(for: accountID)
        XCTAssertNil(none)
    }

    /// A reconnect that added the calendar scope saves its tokens through the manager; the cached token of a healthy
    /// account would otherwise stand for up to an hour, and the answer waiting for the scope with it.
    func testTokensAReconnectStoredCountAtOnce() async throws {
        installRefreshReply()
        let (manager, store) = makeManager(tokens: tokens(expiringIn: 3_600))
        await assertAccessToken(manager, equals: "at-1")
        let granted = OAuthTokens(accessToken: "at-new", refreshToken: "rt-new", expiresAt: issuedAt.addingTimeInterval(3_600),
                                  scope: "scope-1 calendar")
        try store.save(granted, for: accountID)
        let cached = await manager.grantedScopes(for: accountID)
        XCTAssertEqual(cached, "scope-1", "a write the manager did not make is not seen while it has a cached token")

        // Through the protocol, as the engine calls it: the manager's own method, not the protocol's default.
        let provider: AccessTokenProvider = manager
        try await provider.replaceTokens(for: accountID) { try store.save(granted, for: self.accountID) }
        let scopes = await provider.grantedScopes(for: accountID)
        XCTAssertEqual(scopes, "scope-1 calendar")
        await assertAccessToken(manager, equals: "at-new")
        XCTAssertEqual(StubURLProtocol.requestCount, 0, "the new token is used as it is, without a refresh")
    }

    /// A refresh that started with the old refresh token is still answered to its callers (failing them would read as a
    /// cancelled sync and stop the lane), but it never writes the old grant over the new one.
    func testARefreshRunningWhenTokensAreReplacedNeitherFailsItsCallersNorOverwritesTheNewGrant() async throws {
        installRefreshReply(delay: 0.3)
        let (manager, store) = makeManager(tokens: tokens(expiringIn: 10))
        let inFlight = Task { try await manager.accessToken(for: self.accountID) }
        let deadline = Date().addingTimeInterval(10)
        while StubURLProtocol.requestCount == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "the refresh is under way")

        let granted = OAuthTokens(accessToken: "at-new", refreshToken: "rt-new", expiresAt: issuedAt.addingTimeInterval(3_600),
                                  scope: "scope-1 calendar")
        try await manager.replaceTokens(for: accountID) { try store.save(granted, for: self.accountID) }
        let answered = try await inFlight.value
        XCTAssertEqual(answered, "at-2", "the caller that waited gets the token it asked for")

        XCTAssertEqual(try store.tokens(for: accountID), granted, "the new grant stays in the store")
        await assertAccessToken(manager, equals: "at-new")
        let scopes = await manager.grantedScopes(for: accountID)
        XCTAssertEqual(scopes, "scope-1 calendar")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
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

    /// `removeTokens` racing a refresh whose reply has already arrived: the reply must be dropped, not persisted.
    func testRemoveTokensWhileARefreshReplyIsPendingDropsTheReply() async throws {
        let other = AccountID("acct-2")
        let endpointReached = expectation(description: "token endpoint reached")
        let replyGate = DispatchSemaphore(value: 0)
        StubURLProtocol.install { _ in
            endpointReached.fulfill()
            replyGate.wait()
            return StubURLProtocol.Reply(json: #"{"access_token":"at-2","refresh_token":"rt-2","expires_in":3600}"#)
        }
        let readEntered = expectation(description: "gated read entered")
        readEntered.assertForOverFulfill = false
        let store = GatedTokenStore(
            InMemoryTokenStore([accountID: tokens(expiringIn: 5), other: tokens(expiringIn: 3600)]),
            gating: other,
            readEntered: readEntered
        )
        // Open both gates on every exit so a failed assertion cannot leave the actor's thread parked.
        defer {
            replyGate.signal()
            store.readGate.signal()
        }
        let now = issuedAt
        let manager = TokenManager(tokenStore: store, configurations: configurations, kinds: { _ in .gmail }, session: StubURLProtocol.makeSession(), now: { now })

        // The refresh for acct-1 is parked at the token endpoint and the actor is idle.
        let refresh = Task { try await manager.accessToken(for: self.accountID) }
        await fulfillment(of: [endpointReached], timeout: 5)
        // Hold the actor inside an unrelated read so the removal queues up behind it, and only then let the
        // reply through: its continuation lands in the queue after the removal. That is the order a Keychain
        // read on the actor produces when the user removes an account mid-refresh.
        let unrelated = Task { try await manager.accessToken(for: other) }
        await fulfillment(of: [readEntered], timeout: 5)
        let removal = Task { try await manager.removeTokens(for: self.accountID) }
        try await Task.sleep(for: .milliseconds(100))
        replyGate.signal()
        try await Task.sleep(for: .milliseconds(100))
        store.readGate.signal()

        _ = try await unrelated.value
        try await removal.value
        let outcome = await refresh.result
        XCTAssertEqual(store.writes, ["delete \(accountID)"], "the stale reply must not be written back")
        XCTAssertNil(try store.tokens(for: accountID))
        if case .success(let token) = outcome {
            XCTFail("refresh for a removed account returned \(token)")
        }
        do {
            _ = try await manager.accessToken(for: accountID)
            XCTFail("expected unauthorized")
        } catch ProviderError.unauthorized {} catch { XCTFail("unexpected \(error)") }
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    /// A reconnect saves its new grant, and the manager must stop trusting a refresh of the old one. That refresh can
    /// land at any moment of the reconnect, here right after the keychain write: it must never write the old grant over
    /// the new one there, so the save is made through the manager, with no moment between it and the manager's knowing.
    func testARefreshLandingAsAReconnectSavesItsTokensNeverWritesTheOldGrantOverTheNew() async throws {
        installRefreshReply(delay: 0.3)
        let account = Fixtures.account()
        let store = SaveHookTokenStore()
        try store.save(tokens(expiringIn: 10), for: account.id)
        let now = issuedAt
        let manager = TokenManager(tokenStore: store, configurations: configurations, kinds: { _ in .gmail },
                                   session: StubURLProtocol.makeSession(), now: { now })
        let granted = OAuthTokens(accessToken: "at-new", refreshToken: "rt-new", expiresAt: issuedAt.addingTimeInterval(3_600),
                                  scope: "scope-1 calendar")
        let authenticator = StubAuthenticator()
        authenticator.result = .success(granted)
        let cache = FileManager.default.temporaryDirectory.appending(path: "ss-reconnect-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: cache) }
        let engine = MailEngine(store: InMemoryMailStore(), tokenStore: store, tokenProvider: manager, authenticator: authenticator,
                                sanitizer: RecordingSanitizer(), providerFactory: { _ in ScriptedProvider(accountID: account.id) },
                                attachmentCacheDirectory: cache)

        // A request found the old token about to expire: its refresh, with the old refresh token, is under way.
        let refreshed = DispatchSemaphore(value: 0)
        let inFlight = Task {
            defer { refreshed.signal() }
            return try await manager.accessToken(for: account.id)
        }
        let deadline = Date().addingTimeInterval(10)
        while StubURLProtocol.requestCount == 0, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "the refresh is under way")
        // The refresh's reply is let in right after the new grant reaches the keychain, if anything lets it in then.
        store.afterSaving = { tokens, id in
            guard id == account.id, tokens.refreshToken == "rt-new" else { return }
            _ = refreshed.wait(timeout: .now() + 1)
        }

        _ = try await engine.reconnect(account)
        let answered = try await inFlight.value
        XCTAssertEqual(answered, "at-2", "the caller that waited still gets the token it asked for")
        XCTAssertEqual(try store.tokens(for: account.id), granted, "the new grant stays in the keychain")
        let token = try await manager.accessToken(for: account.id)
        XCTAssertEqual(token, "at-new")
        let scopes = await manager.grantedScopes(for: account.id)
        XCTAssertEqual(scopes, "scope-1 calendar")
        await engine.stopAndWait()
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

/// Wraps a store so one account's reads park the calling thread until the test releases them, which holds the
/// `TokenManager` actor busy at a chosen moment. Writes are recorded in order.
private final class GatedTokenStore: TokenStore, @unchecked Sendable {
    private let inner: InMemoryTokenStore
    private let gatedAccount: AccountID
    private let readEntered: XCTestExpectation
    private let lock = NSLock()
    private var recordedWrites: [String] = []
    let readGate = DispatchSemaphore(value: 0)

    init(_ inner: InMemoryTokenStore, gating gatedAccount: AccountID, readEntered: XCTestExpectation) {
        self.inner = inner
        self.gatedAccount = gatedAccount
        self.readEntered = readEntered
    }

    var writes: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedWrites
    }

    func tokens(for accountID: AccountID) throws -> OAuthTokens? {
        if accountID == gatedAccount {
            readEntered.fulfill()
            readGate.wait()
        }
        return try inner.tokens(for: accountID)
    }

    func save(_ tokens: OAuthTokens, for accountID: AccountID) throws {
        record("save \(accountID)")
        try inner.save(tokens, for: accountID)
    }

    func delete(for accountID: AccountID) throws {
        record("delete \(accountID)")
        try inner.delete(for: accountID)
    }

    private func record(_ entry: String) {
        lock.lock(); defer { lock.unlock() }
        recordedWrites.append(entry)
    }
}

/// A token store that runs `afterSaving` once a save has written, on the saving thread: a test parks that thread there
/// to hold whatever made the save at that moment.
private final class SaveHookTokenStore: TokenStore, @unchecked Sendable {
    private let inner = InMemoryTokenStore()
    private let lock = NSLock()
    private var hook: (@Sendable (OAuthTokens, AccountID) -> Void)?

    var afterSaving: (@Sendable (OAuthTokens, AccountID) -> Void)? {
        get { lock.withLock { hook } }
        set { lock.withLock { hook = newValue } }
    }

    func tokens(for accountID: AccountID) throws -> OAuthTokens? {
        try inner.tokens(for: accountID)
    }

    func save(_ tokens: OAuthTokens, for accountID: AccountID) throws {
        try inner.save(tokens, for: accountID)
        afterSaving?(tokens, accountID)
    }

    func delete(for accountID: AccountID) throws {
        try inner.delete(for: accountID)
    }
}
