import Foundation
import os
import XCTest
@testable import SSCore

/// An unsubscribe through the engine (roadmap Q2.4, docs/ARCHITECTURE.md "Unsubscribe"): the archive and the request
/// stored together, the request sent after the account's other operations and apart from them, the one-click POST on
/// a session of its own (no cookies, no credentials, https-only redirects) and the mailto request through the
/// provider's send. Every POST goes to `UnsubscribeStubProtocol`; nothing leaves the process.
final class MailEngineUnsubscribeTests: XCTestCase {
    private let conversation = ConversationID(accountID: Fixtures.accountID, providerID: "t1")
    private let oneClick = UnsubscribeMethod.oneClick(URL(string: "https://news.example.com/u/42?t=abc")!)
    private let mailto = UnsubscribeMethod.mailto(URL(string: "mailto:leave@news.example.com?subject=Stop&body=please%20stop")!)

    override func setUp() {
        super.setUp()
        UnsubscribeStubProtocol.reset()
    }

    override func tearDown() {
        UnsubscribeStubProtocol.reset()
        super.tearDown()
    }

    private func bootstrappedHarness(tune: (inout SyncTuning) -> Void = { _ in }) async throws -> EngineHarness {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        let harness = try EngineHarness(provider: provider) { tuning in
            tuning.unsubscribeConfiguration = { UnsubscribeStubProtocol.configuration() }
            tune(&tuning)
        }
        harness.engine.start()
        try await waitUntil("bootstrap complete") { try harness.store.syncCursor(for: Fixtures.accountID) == "c0" }
        return harness
    }

    private func pending(_ harness: EngineHarness) throws -> [SSCore.Operation] {
        try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 20)
    }

    private func archiveTargets(_ harness: EngineHarness) throws -> [MessageID] {
        try harness.store.messages(in: conversation).map(\.id)
    }

    private func unsubscribeRequests(_ harness: EngineHarness) throws -> [SSCore.Operation] {
        try pending(harness).filter { if case .unsubscribe = $0.change { return true } else { return false } }
    }

    // MARK: Capture

    /// Graph's path end to end: a listing carries no headers, the body fetch does, and the hydrator's save puts them on
    /// the message, where the reader reads them; a poll that reports the message again without them keeps them.
    func testABodyFetchPutsTheListHeadersOnTheMessage() async throws {
        let harness = try await bootstrappedHarness()
        let id = MessageID(accountID: Fixtures.accountID, providerID: "2")
        XCTAssertNil(try harness.store.message(id)?.listUnsubscribe)
        harness.provider.bodies["2"] = .success(MessageBody(html: "<p>Issue</p>", text: nil,
                                                            listUnsubscribe: "<https://news.example.com/u/2>",
                                                            listUnsubscribePost: "List-Unsubscribe=One-Click"))
        _ = try await harness.engine.ensureBody(for: id)
        let stored = try XCTUnwrap(try harness.store.message(id))
        XCTAssertEqual(stored.listUnsubscribe, "<https://news.example.com/u/2>")
        XCTAssertEqual(UnsubscribeMethod(message: stored), .oneClick(URL(string: "https://news.example.com/u/2")!))
        try harness.store.upsertMessages([Fixtures.message(2)])
        XCTAssertEqual(try harness.store.message(id)?.listUnsubscribe, "<https://news.example.com/u/2>")
        await harness.shutdown()
    }

    // MARK: Storing

    func testTheArchiveAndTheRequestAreStoredTogetherAndTheArchiveIsNotHeldBack() async throws {
        UnsubscribeStubProtocol.install { _ in .failure(URLError(.notConnectedToInternet)) }
        let harness = try await bootstrappedHarness { $0.backoffBase = 10; $0.backoffCap = 60 }
        try harness.engine.unsubscribe(oneClick, accountID: Fixtures.accountID, archiving: try archiveTargets(harness))

        // Local first: the archive is applied before `unsubscribe` returns.
        XCTAssertTrue(try harness.store.messages(in: conversation).allSatisfy { !$0.roles.contains(.inbox) })
        XCTAssertTrue(try harness.store.conversations(ConversationQuery(view: .inbox)).isEmpty)

        // The archive reaches the provider even though the sender's server cannot be reached.
        try await waitUntil("archive applied") { harness.provider.applyCalls.contains { $0.change == .archive } }
        try await waitUntil("POST attempted") { UnsubscribeStubProtocol.requests.count == 1 }
        try await waitUntil("request waiting for the network") {
            try self.unsubscribeRequests(harness).first.map { $0.attempts == 1 && $0.status == .pending } ?? false
        }
        let waiting = try XCTUnwrap(try unsubscribeRequests(harness).first)
        XCTAssertEqual(waiting.change, .unsubscribe(oneClick))
        XCTAssertGreaterThan(try XCTUnwrap(waiting.nextAttemptAt), Date(), "offline: tried again later, never given up")
        XCTAssertFalse(harness.provider.applyCalls.contains { if case .unsubscribe = $0.change { return true } else { return false } },
                       "the request is never sent to the provider as a change")
        XCTAssertNil(try harness.store.conversations(ConversationQuery(view: .all)).first?.failedOperation)
        await harness.shutdown()
    }

    /// One call to the store, which both stores make one transaction (`testSeveralOperationsAreStoredTogetherInOrder`):
    /// a store that would refuse a second write still takes the archive and the request whole, never half of them.
    func testTheArchiveAndTheRequestGoToTheStoreInOneCall() async throws {
        let store = FaultyStore(base: InMemoryMailStore())
        let harness = try EngineHarness(store: store.base, engineStore: store)
        try store.base.upsertMessages([Fixtures.message(1), Fixtures.message(2)])
        store.fail(.enqueue, after: 1)
        try harness.engine.unsubscribe(oneClick, accountID: Fixtures.accountID, archiving: try archiveTargets(harness))
        XCTAssertEqual(store.fired, [], "one write")
        XCTAssertEqual(try pending(harness).map(\.change), [.archive, .unsubscribe(oneClick)])
        XCTAssertTrue(try harness.store.messages(in: conversation).allSatisfy { !$0.roles.contains(.inbox) })
        await harness.shutdown()
    }

    /// A snoozed conversation is archived already (spec §5.45): unsubscribing ends its snooze, so the list's mail never
    /// comes back to the Inbox at its time, in the store call that queues the request (`setSnoozes(_:enqueueing:at:)`,
    /// one transaction) and never through `enqueue`, so the conversation never leaves Later without its request queued.
    func testUnsubscribingASnoozedConversationEndsItsSnoozeWithTheRequest() async throws {
        let store = FaultyStore(base: InMemoryMailStore())
        let harness = try EngineHarness(store: store.base, engineStore: store)
        try store.base.upsertMessages([Fixtures.message(1), Fixtures.message(2)])
        try harness.engine.setSnoozes([Snooze.Change(conversationID: conversation, until: Date().addingTimeInterval(86_400))],
                                      performing: [MailActionRecord.Step(change: .archive, targets: try archiveTargets(harness))])
        XCTAssertEqual(try harness.store.snoozes().map(\.conversationID), [conversation])
        store.fail(.enqueue, times: 10)
        try harness.engine.unsubscribe(oneClick, accountID: Fixtures.accountID, archiving: [], endingSnoozesOf: [conversation])
        XCTAssertEqual(store.fired, [], "one write, the snooze's end with it")
        XCTAssertTrue(try harness.store.snoozes().isEmpty, "it does not come back at its time")
        XCTAssertTrue(try harness.store.conversations(ConversationQuery(view: .later)).isEmpty)
        XCTAssertTrue(try harness.store.messages(in: conversation).allSatisfy { !$0.roles.contains(.inbox) }, "and stays archived")
        XCTAssertEqual(try pending(harness).map(\.change), [.archive, .unsubscribe(oneClick)], "the snooze's archive, then the request")

        // Another account's conversation is not this request's to bring out of Later.
        let other = ConversationID(accountID: AccountID("other"), providerID: "t1")
        try harness.engine.unsubscribe(.browser(URL(string: "https://news.example.com/page")!), accountID: Fixtures.accountID,
                                       archiving: [], endingSnoozesOf: [other])
        XCTAssertEqual(try pending(harness).count, 2, "a page with nothing to archive or end stores nothing")
        await harness.shutdown()
    }

    func testAPageQueuesNoRequestAndNothingToArchiveQueuesNoArchive() async throws {
        let harness = try await bootstrappedHarness()
        harness.engine.stop()
        try harness.engine.unsubscribe(.browser(URL(string: "https://news.example.com/page")!), accountID: Fixtures.accountID,
                                       archiving: try archiveTargets(harness))
        XCTAssertEqual(try pending(harness).map(\.change), [.archive], "the app opens a page itself")

        try harness.engine.unsubscribe(oneClick, accountID: Fixtures.accountID, archiving: [])
        XCTAssertEqual(try pending(harness).map(\.change), [.archive, .unsubscribe(oneClick)], "a request alone")
        await harness.shutdown()
    }

    // MARK: One-click

    func testTheOneClickPOSTCarriesTheBodyAndNoCookie() async throws {
        UnsubscribeStubProtocol.install { _ in .reply(status: 200, headers: ["Set-Cookie": "sid=tracker; Path=/; Secure"]) }
        let harness = try await bootstrappedHarness()
        try harness.engine.unsubscribe(oneClick, accountID: Fixtures.accountID, archiving: try archiveTargets(harness))
        try await waitUntil("request sent and settled") {
            try UnsubscribeStubProtocol.requests.count == 1 && self.unsubscribeRequests(harness).isEmpty
        }
        try harness.engine.unsubscribe(oneClick, accountID: Fixtures.accountID, archiving: [])
        try await waitUntil("second request sent") { UnsubscribeStubProtocol.requests.count == 2 }
        try await waitUntil("second request settled") { try self.unsubscribeRequests(harness).isEmpty }

        let requests = UnsubscribeStubProtocol.requests
        for request in requests {
            XCTAssertEqual(request.url, URL(string: "https://news.example.com/u/42?t=abc"))
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.body.flatMap { String(data: $0, encoding: .utf8) }, "List-Unsubscribe=One-Click")
            XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
            XCTAssertNil(request.headers["Cookie"], "no cookie goes, not even one the server set a moment ago")
            XCTAssertNil(request.headers["Authorization"], "no credentials")
        }
        XCTAssertTrue(harness.provider.sendCalls.isEmpty)
        await harness.shutdown()
    }

    /// The sender's server is nobody's the user chose: a slow one never holds back the live lane, which goes on polling
    /// while the POST waits, and the request is not sent a second time meanwhile.
    func testASlowSenderNeverHoldsBackThePoll() async throws {
        UnsubscribeStubProtocol.install { _ in
            Thread.sleep(forTimeInterval: 1.5)
            return .reply(status: 200)
        }
        let harness = try await bootstrappedHarness()
        try harness.engine.unsubscribe(oneClick, accountID: Fixtures.accountID, archiving: try archiveTargets(harness))
        try await waitUntil("POST under way") { UnsubscribeStubProtocol.requests.count == 1 }
        let pollsBefore = harness.provider.changesCalls.count
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertFalse(try unsubscribeRequests(harness).isEmpty, "the POST is still waiting for its answer")
        XCTAssertGreaterThanOrEqual(harness.provider.changesCalls.count - pollsBefore, 2, "the live lane kept polling meanwhile")
        try await waitUntil("POST answered and settled") { try self.unsubscribeRequests(harness).isEmpty }
        XCTAssertEqual(UnsubscribeStubProtocol.requests.count, 1, "sent once")
        await harness.shutdown()
    }

    func testTheSessionKeepsNothingAndAsksForNothing() {
        let configuration = Unsubscriber.configuration()
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 15)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 30)
        XCTAssertFalse(configuration.waitsForConnectivity)
    }

    func testARedirectIsFollowedOnlyToHTTPS() async throws {
        UnsubscribeStubProtocol.install { request in
            switch request.url?.path {
            case "/u/42": return .redirect(to: "https://other.example.com/done")
            case "/done": return .reply(status: 204)
            case "/clear": return .redirect(to: "http://news.example.com/plain")
            default: return .reply(status: 200)
            }
        }
        let unsubscriber = Unsubscriber(configuration: { UnsubscribeStubProtocol.configuration() })
        let followed = await unsubscriber.postOneClick(to: URL(string: "https://news.example.com/u/42")!)
        XCTAssertEqual(followed, .sent)
        XCTAssertEqual(UnsubscribeStubProtocol.requests.map(\.url?.absoluteString),
                       ["https://news.example.com/u/42", "https://other.example.com/done"])

        UnsubscribeStubProtocol.install { request in
            request.url?.path == "/clear" ? .redirect(to: "http://news.example.com/plain") : .reply(status: 200)
        }
        let refused = await unsubscriber.postOneClick(to: URL(string: "https://news.example.com/clear")!)
        XCTAssertEqual(refused, .refused("status 302"), "never on to http: the redirect is the answer")
        XCTAssertEqual(UnsubscribeStubProtocol.requests.map(\.url?.absoluteString), ["https://news.example.com/clear"])
    }

    /// A sender's endpoint behind a password, or a TLS server asking for a client certificate: the challenge is
    /// declined, never answered and never cancelled, so a password challenge ends in its 401 and is dropped like any
    /// 4xx, and a certificate request goes on without one.
    func testAnAuthenticationChallengeIsDeclinedAndItsRefusalDropsTheRequest() async throws {
        UnsubscribeStubProtocol.install { request in
            switch request.url?.path {
            case "/basic": return .challenge(method: NSURLAuthenticationMethodHTTPBasic, then: 401)
            case "/ntlm": return .challenge(method: NSURLAuthenticationMethodNTLM, then: 401)
            case "/negotiate": return .challenge(method: NSURLAuthenticationMethodNegotiate, then: 401)
            case "/certificate": return .challenge(method: NSURLAuthenticationMethodClientCertificate, then: 200)
            default: return .reply(status: 200)
            }
        }
        let unsubscriber = Unsubscriber(configuration: { UnsubscribeStubProtocol.configuration() })
        for path in ["basic", "ntlm", "negotiate"] {
            let outcome = await unsubscriber.postOneClick(to: URL(string: "https://news.example.com/\(path)")!)
            XCTAssertEqual(outcome, .refused("status 401"), path)
        }
        let certificate = await unsubscriber.postOneClick(to: URL(string: "https://news.example.com/certificate")!)
        XCTAssertEqual(certificate, .sent, "on without a certificate")
        XCTAssertTrue(UnsubscribeStubProtocol.requests.allSatisfy { $0.headers["Authorization"] == nil }, "no credentials")

        for method in [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM,
                       NSURLAuthenticationMethodNegotiate, NSURLAuthenticationMethodClientCertificate] {
            let (disposition, credential) = HTTPSOnlyRedirects.disposition(for: method)
            XCTAssertEqual(disposition, .rejectProtectionSpace, method)
            XCTAssertNil(credential)
        }
        XCTAssertEqual(HTTPSOnlyRedirects.disposition(for: NSURLAuthenticationMethodServerTrust).0, .performDefaultHandling,
                       "the server's certificate is still checked")

        // Through the engine: dropped once, never asked again.
        UnsubscribeStubProtocol.reset()
        UnsubscribeStubProtocol.install { _ in .challenge(method: NSURLAuthenticationMethodHTTPBasic, then: 401) }
        let harness = try await bootstrappedHarness { $0.backoffBase = 0.05; $0.backoffCap = 0.1 }
        try harness.engine.unsubscribe(oneClick, accountID: Fixtures.accountID, archiving: [])
        try await waitUntil("refusal dropped") { try UnsubscribeStubProtocol.requests.count == 1 && self.unsubscribeRequests(harness).isEmpty }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(UnsubscribeStubProtocol.requests.count, 1, "never asked again")
        await harness.shutdown()
    }

    /// Only a stop is a cancellation that waits for the next run; one from anywhere else counts toward giving up, so
    /// nothing is asked for ever.
    func testOnlyAStopIsACancellationThatNeverGivesUp() async throws {
        UnsubscribeStubProtocol.install { _ in .failure(URLError(.cancelled)) }
        let unsubscriber = Unsubscriber(configuration: { UnsubscribeStubProtocol.configuration() })
        let url = URL(string: "https://news.example.com/u/42")!
        let cancelled = await unsubscriber.postOneClick(to: url)
        XCTAssertEqual(cancelled, .retry(counted: true, retryAfter: nil))

        UnsubscribeStubProtocol.install { _ in
            Thread.sleep(forTimeInterval: 1)
            return .reply(status: 200)
        }
        let task = Task { await unsubscriber.postOneClick(to: url) }
        try await waitUntil("POST under way") { UnsubscribeStubProtocol.requests.count == 1 }
        task.cancel()
        let stopped = await task.value
        XCTAssertEqual(stopped, .retry(counted: false, retryAfter: nil), "the engine stopping: the row waits for the next run")
    }

    /// A mailto request the keychain refuses a token for waits for the user, as one whose token the provider refuses
    /// does; a token refresh that fails sent nothing, so it is tried again without counting towards dropping it.
    func testAMailtoRequestWhoseTokenCannotBeHadIsNotCounted() async {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.sendResults = [
            .failure(AuthError.keychain(status: errSecAuthFailed)),
            .failure(AuthError.refreshFailed("temporarily_unavailable")),
        ]
        let unsubscriber = Unsubscriber()
        let denied = await unsubscriber.sendMail(mailto, from: Fixtures.accountID, via: provider)
        XCTAssertEqual(denied, .needsReauth)
        let unrefreshed = await unsubscriber.sendMail(mailto, from: Fixtures.accountID, via: provider)
        XCTAssertEqual(unrefreshed, .retry(counted: false, retryAfter: nil))
    }

    func testAStatusSaysWhetherToTryAgain() async {
        XCTAssertEqual(Unsubscriber.outcome(status: 200, retryAfter: nil), .sent)
        XCTAssertEqual(Unsubscriber.outcome(status: 202, retryAfter: nil), .sent)
        XCTAssertEqual(Unsubscriber.outcome(status: 404, retryAfter: nil), .refused("status 404"))
        XCTAssertEqual(Unsubscriber.outcome(status: 400, retryAfter: nil), .refused("status 400"))
        XCTAssertEqual(Unsubscriber.outcome(status: 429, retryAfter: "120"), .retry(counted: true, retryAfter: 120))
        XCTAssertEqual(Unsubscriber.outcome(status: 503, retryAfter: nil), .retry(counted: true, retryAfter: nil))
        XCTAssertEqual(Unsubscriber.outcome(URLError(.notConnectedToInternet)), .retry(counted: false, retryAfter: nil))
        XCTAssertEqual(Unsubscriber.outcome(URLError(.networkConnectionLost)), .retry(counted: false, retryAfter: nil))
        XCTAssertEqual(Unsubscriber.outcome(URLError(.timedOut)), .retry(counted: true, retryAfter: nil))
        XCTAssertEqual(Unsubscriber.outcome(URLError(.cannotFindHost)), .retry(counted: true, retryAfter: nil))
        XCTAssertEqual(Unsubscriber.outcome(URLError(.cancelled)), .retry(counted: true, retryAfter: nil),
                       "a stop is told apart by the task's own cancellation, not by the error")
    }

    func testARefusalIsDroppedQuietlyAndAFailingServerIsGivenUpQuietly() async throws {
        UnsubscribeStubProtocol.install { request in
            .reply(status: request.url?.path == "/gone" ? 404 : 500)
        }
        let harness = try await bootstrappedHarness { $0.maxOperationAttempts = 2 }
        let gone = UnsubscribeMethod.oneClick(URL(string: "https://news.example.com/gone")!)
        try harness.engine.unsubscribe(gone, accountID: Fixtures.accountID, archiving: try archiveTargets(harness))
        try await waitUntil("refusal dropped") { try UnsubscribeStubProtocol.requests.count == 1 && self.unsubscribeRequests(harness).isEmpty }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(UnsubscribeStubProtocol.requests.count, 1, "a 4xx is never asked again")

        let broken = UnsubscribeMethod.oneClick(URL(string: "https://news.example.com/broken")!)
        try harness.engine.unsubscribe(broken, accountID: Fixtures.accountID, archiving: [])
        try await waitUntil("failing server given up") { try UnsubscribeStubProtocol.requests.count == 3 && self.unsubscribeRequests(harness).isEmpty }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(UnsubscribeStubProtocol.requests.count, 3, "two tries at the most, then dropped")

        // Quiet: no row marked, nothing given back, the archive kept.
        let summary = try XCTUnwrap(try harness.store.conversations(ConversationQuery(view: .all)).first { $0.id == conversation })
        XCTAssertNil(summary.failedOperation)
        XCTAssertFalse(summary.inInbox)
        await harness.shutdown()
    }

    // MARK: Mailto

    func testTheMailtoRequestIsSentThroughTheProviderWithNoOutboxRow() async throws {
        let harness = try await bootstrappedHarness()
        harness.provider.sendResults = [.failure(ProviderError.network("offline"))]
        let withCopies = UnsubscribeMethod.mailto(URL(string: "mailto:leave@news.example.com?subject=Stop&body=please%20stop&cc=a@victim.example&bcc=b@victim.example")!)
        try harness.engine.unsubscribe(withCopies, accountID: Fixtures.accountID, archiving: try archiveTargets(harness))
        XCTAssertTrue(try harness.store.pendingSends().isEmpty, "no undo window, nothing in the outbox's sending count")
        try await waitUntil("sent after the network came back") {
            try harness.provider.sendCalls.count == 2 && self.unsubscribeRequests(harness).isEmpty
        }
        let sent = try XCTUnwrap(harness.provider.sendCalls.last)
        XCTAssertEqual(sent.accountID, Fixtures.accountID, "from the conversation's account")
        XCTAssertEqual(sent.to.map(\.address), ["leave@news.example.com"])
        XCTAssertEqual(sent.cc, [], "the link's Cc is never used")
        XCTAssertEqual(sent.bcc, [], "nor its Bcc")
        XCTAssertEqual(sent.subject, "Stop")
        XCTAssertEqual(sent.text, "please stop")
        XCTAssertTrue(try harness.store.pendingSends().isEmpty)
        XCTAssertTrue(UnsubscribeStubProtocol.requests.isEmpty, "a mailto request posts nothing")
        await harness.shutdown()
    }

    func testAMailtoTheProviderRefusesIsDroppedQuietly() async throws {
        let harness = try await bootstrappedHarness()
        harness.provider.sendResults = [.failure(ProviderError.server(status: 400, message: "invalid recipient"))]
        try harness.engine.unsubscribe(mailto, accountID: Fixtures.accountID, archiving: [])
        try await waitUntil("refused and dropped") { try harness.provider.sendCalls.count == 1 && self.unsubscribeRequests(harness).isEmpty }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(harness.provider.sendCalls.count, 1)
        await harness.shutdown()
    }
}

/// Answers the unsubscribe session's requests from a handler and records each one with its headers and body. A
/// redirect reply hands URLSession the new request, as a server's 302 would, so the session's own redirect rule runs.
final class UnsubscribeStubProtocol: URLProtocol {
    enum Reply: Sendable {
        case reply(status: Int, headers: [String: String] = [:])
        case redirect(to: String)
        case failure(URLError)
        /// An authentication challenge of `method`, then, unless the session cancelled the load meanwhile, the
        /// server's answer as it comes once a challenge is declined without a credential (a 401 carries its
        /// `WWW-Authenticate`).
        case challenge(method: String, then: Int)
    }

    struct Recorded: Sendable {
        var url: URL?
        var method: String?
        var headers: [String: String]
        var body: Data?
    }

    typealias Handler = @Sendable (Recorded) -> Reply

    private struct State {
        var handler: Handler?
        var requests: [Recorded] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    static func install(_ handler: @escaping Handler) {
        state.withLock { $0 = State(handler: handler) }
    }

    static func reset() {
        state.withLock { $0 = State() }
    }

    static var requests: [Recorded] { state.withLock { $0.requests } }

    /// The engine's own configuration with this protocol in front, so the cookie and credential rules under test are
    /// the real ones.
    static func configuration() -> URLSessionConfiguration {
        let configuration = Unsubscriber.configuration()
        configuration.protocolClasses = [UnsubscribeStubProtocol.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let recorded = Recorded(url: request.url, method: request.httpMethod, headers: request.allHTTPHeaderFields ?? [:],
                                body: Self.body(of: request))
        let handler = Self.state.withLock { state -> Handler? in
            state.requests.append(recorded)
            return state.handler
        }
        guard let handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch handler(recorded) {
        case let .reply(status, headers):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .redirect(let location):
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": location])!
            var next = URLRequest(url: URL(string: location)!)
            next.httpMethod = request.httpMethod
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case let .challenge(method, status):
            challenge(method, then: status, url: url)
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }

    private let stopped = OSAllocatedUnfairLock(initialState: false)

    /// As a real loader does: the challenge goes to the session's delegate, and a cancelled one stops the load
    /// (`stopLoading`), while a declined one goes on to the server's answer.
    private func challenge(_ method: String, then status: Int, url: URL) {
        let space = URLProtectionSpace(host: url.host ?? "", port: 443, protocol: url.scheme, realm: "list", authenticationMethod: method)
        client?.urlProtocol(self, didReceive: URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0, failureResponse: nil, error: nil,
            sender: IgnoredChallengeSender()))
        let headers = status == 401 ? ["WWW-Authenticate": "Basic realm=\"list\""] : [:]
        let answer = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        nonisolated(unsafe) let loader = self
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            guard !loader.stopped.withLock({ $0 }) else { return }
            loader.client?.urlProtocol(loader, didReceive: answer, cacheStoragePolicy: .notAllowed)
            loader.client?.urlProtocolDidFinishLoading(loader)
        }
    }

    /// URLSession hands protocols the body as a stream, never as `httpBody`.
    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// The stub challenge's sender. URLSession tells it nothing it must act on: a cancelled challenge stops the load,
/// and a declined one reaches it as default handling, which the stub's own answer then follows.
private final class IgnoredChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}
