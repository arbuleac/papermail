import XCTest
@testable import PaperCore

final class OAuthFlowTests: XCTestCase {
    private struct CallbackResult: Sendable {
        var status: Int
        var body: String
    }

    private var directory: URL!
    private var configurations: ClientConfigurationStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appending(path: "ss-oauth-flow-\(UUID().uuidString)", directoryHint: .isDirectory)
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

    // MARK: Helpers

    private static func queryItems(of url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    /// Plays the browser: hits the loopback redirect the authorization URL names, with the given query and headers.
    private static func visitCallback(from authorizationURL: URL, query: [String: String], headers: [String: String] = [:]) async throws -> CallbackResult {
        let redirectURI = queryItems(of: authorizationURL)["redirect_uri"]!
        var target = URLComponents(string: redirectURI)!
        target.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: target.url!)
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: request)
        return CallbackResult(status: (response as! HTTPURLResponse).statusCode, body: String(decoding: data, as: UTF8.self))
    }

    /// An opener that performs the loopback GET itself. The stream hands the test the authorization URL and the
    /// browser task so it can assert on both after `signIn` returns.
    private static func makeOpener(
        headers: [String: String] = [:],
        query: @escaping @Sendable (_ state: String) -> [String: String] = { ["code": "test-code", "state": $0] }
    ) -> (opener: @Sendable (URL) -> Void, opened: AsyncStream<(URL, Task<CallbackResult, Error>)>) {
        let (stream, continuation) = AsyncStream<(URL, Task<CallbackResult, Error>)>.makeStream()
        let opener: @Sendable (URL) -> Void = { url in
            let state = queryItems(of: url)["state"] ?? ""
            let browser = Task { try await visitCallback(from: url, query: query(state), headers: headers) }
            continuation.yield((url, browser))
        }
        return (opener, stream)
    }

    private func installTokenReply(expectedURL: URL, json: String = #"{"access_token":"at","refresh_token":"rt","expires_in":3600,"scope":"granted","token_type":"Bearer"}"#) {
        StubURLProtocol.install { request in
            guard request.url == expectedURL else {
                throw URLError(.badURL)
            }
            return StubURLProtocol.Reply(json: json)
        }
    }

    private func makeFlow(opener: @escaping @Sendable (URL) -> Void, timeout: TimeInterval = 10) -> OAuthFlow {
        OAuthFlow(configurations: configurations, session: StubURLProtocol.makeSession(), opener: opener, timeout: timeout, now: { Date(timeIntervalSince1970: 1_800_000_000) })
    }

    // MARK: Tests

    func testGoogleSignInEndToEnd() async throws {
        installTokenReply(expectedURL: OAuthEndpoints.googleTokenURL)
        let (opener, opened) = Self.makeOpener()
        let flow = makeFlow(opener: opener)

        let tokens = try await flow.signIn(kind: .gmail)
        XCTAssertEqual(tokens.accessToken, "at")
        XCTAssertEqual(tokens.refreshToken, "rt")
        XCTAssertEqual(tokens.scope, "granted")
        XCTAssertEqual(tokens.expiresAt, Date(timeIntervalSince1970: 1_800_000_000 + 3600))

        var iterator = opened.makeAsyncIterator()
        let nextOpened = await iterator.next()
        let (authorizationURL, browser) = try XCTUnwrap(nextOpened)
        let browserResult = try await browser.value
        XCTAssertEqual(browserResult.status, 200)
        XCTAssertTrue(browserResult.body.contains("You can return to Paper"))

        let authorization = Self.queryItems(of: authorizationURL)
        XCTAssertEqual(authorizationURL.host, "accounts.google.com")
        XCTAssertTrue(authorization["redirect_uri"]!.hasPrefix("http://127.0.0.1:"))
        XCTAssertTrue(authorization["redirect_uri"]!.hasSuffix("/callback"))
        XCTAssertEqual(authorization["code_challenge_method"], "S256")

        XCTAssertEqual(StubURLProtocol.requestCount, 1)
        let exchange = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(exchange.method, "POST")
        XCTAssertEqual(exchange.form["grant_type"], "authorization_code")
        XCTAssertEqual(exchange.form["code"], "test-code")
        XCTAssertEqual(exchange.form["redirect_uri"], authorization["redirect_uri"])
        XCTAssertEqual(exchange.form["client_id"], "google-client")
        XCTAssertEqual(exchange.form["client_secret"], "google-secret")
        let verifier = try XCTUnwrap(exchange.form["code_verifier"])
        XCTAssertEqual(PKCE.challenge(for: verifier), authorization["code_challenge"])
    }

    /// A reconnect that adds the calendar asks for it beside mail, through the browser's own request.
    func testASignInAskingForTheCalendarAddsItsScope() async throws {
        installTokenReply(expectedURL: OAuthEndpoints.googleTokenURL)
        let (opener, opened) = Self.makeOpener()
        _ = try await makeFlow(opener: opener).signIn(kind: .gmail, loginHint: "ada@example.com", permissions: [.calendar])
        var iterator = opened.makeAsyncIterator()
        let nextOpened = await iterator.next()
        let (authorizationURL, browser) = try XCTUnwrap(nextOpened)
        _ = try await browser.value
        let authorization = Self.queryItems(of: authorizationURL)
        XCTAssertEqual(authorization["scope"], OAuthEndpoints.googleScope + " " + OAuthEndpoints.googleCalendarScope)
        XCTAssertEqual(authorization["include_granted_scopes"], "true")
        XCTAssertEqual(authorization["login_hint"], "ada@example.com")
    }

    func testMicrosoftSignInUsesLocalhostRedirectAndNoSecret() async throws {
        installTokenReply(expectedURL: OAuthEndpoints.microsoftTokenURL(tenant: "common"), json: #"{"access_token":"ms-at","refresh_token":"ms-rt","expires_in":4000}"#)
        let (opener, opened) = Self.makeOpener()
        let flow = makeFlow(opener: opener)

        let tokens = try await flow.signIn(kind: .microsoft)
        XCTAssertEqual(tokens.accessToken, "ms-at")
        XCTAssertEqual(tokens.refreshToken, "ms-rt")
        XCTAssertNil(tokens.scope)

        var iterator = opened.makeAsyncIterator()
        let nextOpened = await iterator.next()
        let (authorizationURL, browser) = try XCTUnwrap(nextOpened)
        let browserResult = try await browser.value
        XCTAssertEqual(browserResult.status, 200)
        let authorization = Self.queryItems(of: authorizationURL)
        XCTAssertEqual(authorizationURL.host, "login.microsoftonline.com")
        XCTAssertTrue(authorization["redirect_uri"]!.hasPrefix("http://localhost:"))
        XCTAssertFalse(authorization["redirect_uri"]!.contains("/callback"), "the registered http://localhost has no path, and Entra matches it")

        let exchange = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(exchange.form["client_id"], "ms-client")
        XCTAssertNil(exchange.form["client_secret"])
        XCTAssertEqual(exchange.form["redirect_uri"], authorization["redirect_uri"])
    }

    func testWrongStateFailsWithoutExchangingTheCode() async throws {
        installTokenReply(expectedURL: OAuthEndpoints.googleTokenURL)
        let (opener, opened) = Self.makeOpener { _ in ["code": "test-code", "state": "forged"] }
        let flow = makeFlow(opener: opener)

        do {
            _ = try await flow.signIn(kind: .gmail)
            XCTFail("expected a state mismatch")
        } catch AuthError.invalidResponse(let message) {
            XCTAssertTrue(message.lowercased().contains("state"))
        } catch {
            XCTFail("unexpected \(error)")
        }
        var iterator = opened.makeAsyncIterator()
        let nextOpened = await iterator.next()
        let (_, browser) = try XCTUnwrap(nextOpened)
        let browserResult = try await browser.value
        XCTAssertEqual(browserResult.status, 400)
        XCTAssertTrue(browserResult.body.contains("Sign-in failed"))
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testProviderDenialIsUserCancelled() async throws {
        installTokenReply(expectedURL: OAuthEndpoints.googleTokenURL)
        let (opener, opened) = Self.makeOpener { state in ["error": "access_denied", "error_description": "The user denied access.", "state": state] }
        let flow = makeFlow(opener: opener)
        do {
            _ = try await flow.signIn(kind: .gmail)
            XCTFail("expected cancellation")
        } catch AuthError.userCancelled {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
        var iterator = opened.makeAsyncIterator()
        let nextOpened = await iterator.next()
        let (_, browser) = try XCTUnwrap(nextOpened)
        let browserResult = try await browser.value
        XCTAssertTrue(browserResult.body.contains("The user denied access."))
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    func testTokenExchangeFailureIsReported() async throws {
        StubURLProtocol.install { _ in
            StubURLProtocol.Reply(status: 400, json: #"{"error":"invalid_grant","error_description":"Malformed auth code."}"#)
        }
        let (opener, _) = Self.makeOpener()
        let flow = makeFlow(opener: opener)
        do {
            _ = try await flow.signIn(kind: .gmail)
            XCTFail("expected exchange failure")
        } catch AuthError.tokenExchangeFailed(let message) {
            XCTAssertTrue(message.contains("invalid_grant"))
            XCTAssertTrue(message.contains("Malformed auth code."))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    /// Browsers attach every cookie set for localhost or 127.0.0.1 to the redirect, whatever the port, so a
    /// developer's cookie jar can push the request head far past the 8-16 KiB most servers accept.
    func testCallbackWithOversizedHeadersStillCompletesSignIn() async throws {
        installTokenReply(expectedURL: OAuthEndpoints.googleTokenURL)
        let cookies = (0 ..< 12).map { "session\($0)=\(String(repeating: "x", count: 2000))" }.joined(separator: "; ")
        XCTAssertGreaterThan(cookies.utf8.count, 16 * 1024)
        let (opener, opened) = Self.makeOpener(headers: ["Cookie": cookies])
        let flow = makeFlow(opener: opener, timeout: 2)

        let tokens = try await flow.signIn(kind: .gmail)
        XCTAssertEqual(tokens.accessToken, "at")
        var iterator = opened.makeAsyncIterator()
        let nextOpened = await iterator.next()
        let (_, browser) = try XCTUnwrap(nextOpened)
        let browserResult = try await browser.value
        XCTAssertEqual(browserResult.status, 200)
        XCTAssertTrue(browserResult.body.contains("You can return to Paper"))
    }

    func testTimesOutWhenTheBrowserNeverComesBack() async throws {
        let flow = makeFlow(opener: { _ in }, timeout: 0.3)
        let started = Date()
        do {
            _ = try await flow.signIn(kind: .gmail)
            XCTFail("expected a timeout")
        } catch AuthError.userCancelled {
            XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testTaskCancellationAbortsTheWait() async throws {
        let (stream, continuation) = AsyncStream<URL>.makeStream()
        let flow = makeFlow(opener: { continuation.yield($0) }, timeout: 30)
        let signIn = Task { try await flow.signIn(kind: .gmail) }
        var iterator = stream.makeAsyncIterator()
        let nextOpened = await iterator.next()
        let authorizationURL = try XCTUnwrap(nextOpened)
        signIn.cancel()
        do {
            _ = try await signIn.value
            XCTFail("expected cancellation")
        } catch AuthError.userCancelled {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
        // The listener is gone, so the stale browser tab gets a connection error rather than a page.
        do {
            _ = try await Self.visitCallback(from: authorizationURL, query: ["code": "late", "state": "x"])
            XCTFail("expected the listener to be closed")
        } catch {
            XCTAssertTrue(error is URLError)
        }
    }

    func testMissingConfigurationFailsBeforeOpeningTheBrowser() async {
        let flow = OAuthFlow(configurations: ClientConfigurationStore(fileURL: directory.appending(path: "absent.json")), session: StubURLProtocol.makeSession(), opener: { _ in XCTFail("browser must not open") })
        do {
            _ = try await flow.signIn(kind: .microsoft)
            XCTFail("expected missing configuration")
        } catch AuthError.missingClientConfiguration(let kind) {
            XCTAssertEqual(kind, .microsoft)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testUnrelatedRequestsDoNotSettleTheFlow() async throws {
        installTokenReply(expectedURL: OAuthEndpoints.googleTokenURL)
        let (stream, continuation) = AsyncStream<URL>.makeStream()
        let flow = makeFlow(opener: { continuation.yield($0) })
        let signIn = Task { try await flow.signIn(kind: .gmail) }
        var iterator = stream.makeAsyncIterator()
        let nextOpened = await iterator.next()
        let authorizationURL = try XCTUnwrap(nextOpened)
        let redirectURI = Self.queryItems(of: authorizationURL)["redirect_uri"]!
        let base = URL(string: redirectURI)!.deletingLastPathComponent()
        let session = URLSession(configuration: .ephemeral)
        let (_, favicon) = try await session.data(from: base.appending(path: "favicon.ico"))
        XCTAssertEqual((favicon as? HTTPURLResponse)?.statusCode, 404)

        let state = Self.queryItems(of: authorizationURL)["state"]!
        let real = try await Self.visitCallback(from: authorizationURL, query: ["code": "test-code", "state": state])
        XCTAssertEqual(real.status, 200)
        let tokens = try await signIn.value
        XCTAssertEqual(tokens.accessToken, "at")
    }
}
