import AppKit
import SSCore
import WebKit
import XCTest
@testable import SuperSparrowApp

/// The invitation card in the real reader (spec §5.14): it renders from the stored facts, its buttons answer through
/// the engine (recorded in the store at once, replayed to the provider), an account without calendar permission asks
/// to reconnect on the card, Open in Calendar hands a calendar file over, and a cancellation offers no answer. The
/// engine runs over a throwaway store and a provider in memory; nothing reaches the network, the Keychain, Calendar or
/// the user's mail.
@MainActor
final class ReaderInvitationTests: XCTestCase {
    private var folder: URL!
    private let account = ListTestSupport.accountA
    private lazy var conversation = ConversationID(accountID: account.id, providerID: "thread-invite")
    private lazy var messageID = MessageID(accountID: account.id, providerID: "msg-invite")
    private var engine: MailEngine?
    private var opened: [URL] = []
    private var savedOpener: ((URL) -> Void)?

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderInvitation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        savedOpener = InvitationFiles.opener
        InvitationFiles.opener = { [weak self] in self?.opened.append($0) }
    }

    override func tearDownWithError() throws {
        if let savedOpener { InvitationFiles.opener = savedOpener }
        if let engine {
            var stopped = false
            Task { await engine.stopAndWait(); stopped = true }
            ListTestSupport.spin(until: { stopped }, timeout: 5)
        }
        try? FileManager.default.removeItem(at: folder)
    }

    private func invitation(method: CalendarInvitation.Method = .request) -> CalendarInvitation {
        CalendarInvitation(
            method: method, uid: "uid-1@google.com", title: "Design review",
            start: Date().addingTimeInterval(2 * 86_400), end: Date().addingTimeInterval(2 * 86_400 + 3_600),
            location: "Room 4", organizer: CalendarInvitation.Person(name: "Ben Carter", address: "ben@contoso.test"),
            attendees: [CalendarInvitation.Person(name: nil, address: account.email, response: .needsAction),
                        CalendarInvitation.Person(name: "Ada Lovelace", address: "ada@contoso.test", response: .accepted)],
            repeats: "Every week on Tuesday", userAddress: account.email, userResponse: .needsAction,
            calendarText: "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nEND:VCALENDAR\r\n"
        )
    }

    /// The reader showing one message that carries `invitation`, over an engine whose provider is `provider`. Without
    /// `storingAccount` the store has no row for the message's account, so the engine refuses every answer.
    private func showInvitation(_ invitation: CalendarInvitation? = nil, provider: InvitationProvider,
                                storingAccount: Bool = true) throws -> ConversationViewController {
        let store = InMemoryMailStore()
        if storingAccount { try store.upsertAccount(account) }
        try store.upsertMessages([MessageMetadata(
            id: messageID, conversationID: conversation, subject: "Invitation: Design review", snippet: "Ben Carter has invited you",
            from: EmailAddress(name: "Ben Carter", address: "ben@contoso.test"), to: [EmailAddress(address: account.email)],
            date: Date(), roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false
        )])
        let html = "<p>Ben Carter has invited you.</p>"
        try store.saveBody(StoredBody(body: MessageBody(html: html, text: nil), renderedHTML: html, plainText: "Ben Carter has invited you.",
                                      invitation: invitation ?? self.invitation()), for: messageID)
        let engine = MailEngine(store: store, tokenStore: InMemoryTokenStore(), tokenProvider: DemoTokenProvider(),
                                authenticator: DemoAuthenticator(), sanitizer: HTMLSanitizer(), providerFactory: { _ in provider },
                                attachmentCacheDirectory: folder.appendingPathComponent("attachments", isDirectory: true))
        self.engine = engine
        engine.start()
        let reader = ConversationViewController(client: engine)
        _ = reader.view
        reader.show(conversation)
        let slot = try XCTUnwrap(reader.pool.current)
        XCTAssertTrue(ListTestSupport.spin(until: { slot.isReady && slot.pendingRender == nil && !slot.renderInFlight
                                                    && slot.renderedID == self.conversation }, timeout: 10), "the conversation rendered")
        return reader
    }

    private func evaluate(_ script: String, in reader: ConversationViewController) -> String {
        guard let webView = reader.pool.current?.webView else { return "" }
        var answer: String?
        webView.evaluateJavaScript("(function () { var v = (\(script)); return v === null || v === undefined ? '' : String(v); })()") { value, _ in
            answer = value as? String ?? ""
        }
        ListTestSupport.spin(until: { answer != nil }, timeout: 5)
        return answer ?? ""
    }

    private func waitFor(_ script: String, toBe expected: String, in reader: ConversationViewController, timeout: TimeInterval = 5) -> Bool {
        ListTestSupport.spin(until: { self.evaluate(script, in: reader) == expected }, timeout: timeout)
    }

    func testTheCardRendersAndAnAnswerIsRecordedAndReplayed() throws {
        let provider = InvitationProvider(accountID: account.id)
        let reader = try showInvitation(provider: provider)
        XCTAssertEqual(evaluate("document.querySelector('.ss-invite .ss-ititle').textContent", in: reader), "Design review")
        XCTAssertEqual(evaluate("document.querySelector('.ss-invite .ss-ikick').textContent", in: reader), "Invitation")
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-invite .ss-ans').length", in: reader), "3")
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-invite .ss-ans.ss-chosen').length", in: reader), "0", "not answered yet")
        XCTAssertEqual(evaluate("document.querySelector('.ss-invite .ss-iopen').textContent", in: reader), "Open in Calendar")
        XCTAssertEqual(evaluate("document.querySelector('.ss-invite').getAttribute('aria-label')", in: reader), "Invitation: Design review")

        _ = evaluate("document.querySelector('.ss-ans[data-response=\"tentative\"]').click()", in: reader)
        XCTAssertTrue(ListTestSupport.spin(until: { (try? self.engine?.store.message(self.messageID)?.invitationReply) == .tentative },
                                           timeout: 5), "the answer is in the store")
        XCTAssertTrue(ListTestSupport.spin(until: { provider.answers.map(\.response) == [.tentative] }, timeout: 10), "and replayed once")
        XCTAssertTrue(waitFor("document.querySelector('.ss-ans.ss-chosen').dataset.response", toBe: "tentative", in: reader))
        XCTAssertEqual(evaluate("document.querySelector('.ss-ans.ss-chosen').getAttribute('aria-pressed')", in: reader), "true")
        // The card was rendered again from the store and still shows it chosen.
        XCTAssertTrue(ListTestSupport.spin(until: { reader.pool.current?.renderedInputs?.messages.first?.invitationReply == .tentative },
                                           timeout: 5))
    }

    /// The card marks an answer as it is clicked, before the engine has it. An answer the engine refuses (here its
    /// account is gone) changes nothing in the store, so the card is drawn again from the same facts: it must show what
    /// the store holds, not the answer that was refused.
    func testARefusedAnswerIsTakenOffTheCard() throws {
        let provider = InvitationProvider(accountID: account.id)
        let reader = try showInvitation(provider: provider, storingAccount: false)
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-invite .ss-ans').length", in: reader), "3")
        // Read in the click's own turn: the store's answer may come back before a later evaluation.
        XCTAssertEqual(evaluate("(function () { document.querySelector('.ss-ans[data-response=\"declined\"]').click();"
                                + " var chosen = document.querySelector('.ss-ans.ss-chosen'); return chosen ? chosen.dataset.response : ''; })()",
                                in: reader), "declined", "marked at the click")

        XCTAssertTrue(waitFor("document.querySelectorAll('.ss-invite .ss-ans.ss-chosen').length", toBe: "0", in: reader),
                      "the refused answer is taken off the card")
        XCTAssertEqual(evaluate("document.querySelector('.ss-ans[data-response=\"declined\"]').getAttribute('aria-pressed')", in: reader),
                       "false")
        XCTAssertNil(try engine?.store.message(messageID)?.invitationReply, "the store never had it")
        XCTAssertTrue(provider.answers.isEmpty)
    }

    func testWithoutPermissionTheCardAsksToReconnect() throws {
        let provider = InvitationProvider(accountID: account.id)
        provider.permission = .calendar
        let reader = try showInvitation(provider: provider)
        var actions: [ConversationAction] = []
        reader.onAction = { actions.append($0) }

        _ = evaluate("document.querySelector('.ss-ans[data-response=\"accepted\"]').click()", in: reader)
        XCTAssertTrue(waitFor("document.querySelector('.ss-invite .ss-banner.ss-info .ss-btxt') ? document.querySelector('.ss-invite .ss-banner.ss-info .ss-btxt').textContent : ''",
                              toBe: "Answer invitations: SuperSparrow needs permission to update your calendar.", in: reader, timeout: 10))
        XCTAssertTrue(provider.answers.isEmpty, "nothing goes out without the permission")
        XCTAssertEqual(evaluate("document.querySelector('.ss-ans.ss-chosen').dataset.response", in: reader), "accepted",
                       "the answer stays chosen while it waits")

        _ = evaluate("document.querySelector('.ss-invite .ss-banner.ss-info .ss-link').click()", in: reader)
        XCTAssertTrue(ListTestSupport.spin(until: { !actions.isEmpty }, timeout: 5))
        guard case .reconnect(let id)? = actions.last else { return XCTFail("expected a reconnect, got \(actions)") }
        XCTAssertEqual(id, account.id)

        // Granted: the answer goes out and the card stops asking.
        provider.permission = nil
        engine?.syncNow(accountID: account.id)
        XCTAssertTrue(ListTestSupport.spin(until: { provider.answers.count == 1 }, timeout: 10))
        XCTAssertTrue(waitFor("document.querySelectorAll('.ss-invite .ss-banner.ss-info').length", toBe: "0", in: reader, timeout: 10))
    }

    /// Answering from the keyboard or VoiceOver keeps the user's place: the store renders the card again after the
    /// answer and again when the permission notice comes, and the answer that had focus has it after both. When the
    /// focused control goes (Reconnect, once granted), focus stays in the sheet rather than falling to the page.
    func testFocusSurvivesTheStoresRenders() throws {
        let provider = InvitationProvider(accountID: account.id)
        provider.permission = .calendar
        let reader = try showInvitation(provider: provider)
        let focused = "(function () { var a = document.activeElement; if (!a || a === document.body) { return 'body'; }"
            + " return a.classList.contains('ss-card') ? 'sheet' : (a.dataset.ifocus || a.className); })()"

        _ = evaluate("document.querySelector('.ss-ans[data-response=\"tentative\"]').focus()", in: reader)
        XCTAssertEqual(evaluate(focused, in: reader), "tentative")
        _ = evaluate("document.activeElement.click()", in: reader)
        XCTAssertTrue(ListTestSupport.spin(until: { reader.pool.current?.renderedInputs?.messages.first?.invitationReply == .tentative },
                                           timeout: 5), "rendered again with the answer")
        XCTAssertTrue(waitFor("document.querySelectorAll('.ss-invite .ss-banner.ss-info').length", toBe: "1", in: reader, timeout: 10),
                      "and again with the notice")
        ListTestSupport.spin(until: { false }, timeout: 0.5)
        XCTAssertEqual(evaluate(focused, in: reader), "tentative")
        XCTAssertEqual(evaluate("document.activeElement.getAttribute('aria-pressed')", in: reader), "true")

        _ = evaluate("document.querySelector('.ss-invite [data-ifocus=\"reconnect\"]').focus()", in: reader)
        XCTAssertEqual(evaluate(focused, in: reader), "reconnect")
        provider.permission = nil
        engine?.syncNow(accountID: account.id)
        XCTAssertTrue(waitFor("document.querySelectorAll('.ss-invite .ss-banner.ss-info').length", toBe: "0", in: reader, timeout: 10))
        XCTAssertEqual(evaluate(focused, in: reader), "sheet")
    }

    func testOpenInCalendarHandsOverTheCalendarFile() throws {
        let reader = try showInvitation(provider: InvitationProvider(accountID: account.id))
        _ = evaluate("document.querySelector('.ss-invite .ss-iopen').click()", in: reader)
        XCTAssertTrue(ListTestSupport.spin(until: { !self.opened.isEmpty }, timeout: 5))
        let file = try XCTUnwrap(opened.first)
        XCTAssertEqual(file.lastPathComponent, "Invitation Design review.ics", "named after the subject, without its colon")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nEND:VCALENDAR\r\n")
        XCTAssertEqual(file.deletingLastPathComponent(), InvitationFiles.folder)
    }

    func testACancelledEventOffersNoAnswer() throws {
        let reader = try showInvitation(invitation(method: .cancel), provider: InvitationProvider(accountID: account.id))
        XCTAssertEqual(evaluate("document.querySelector('.ss-invite .ss-ikick').textContent", in: reader), "Cancelled")
        XCTAssertEqual(evaluate("document.querySelector('.ss-invite').classList.contains('ss-cancelled')", in: reader), "true")
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-invite .ss-ans').length", in: reader), "0")
        XCTAssertEqual(evaluate("document.querySelector('.ss-invite').getAttribute('aria-label')", in: reader), "Cancelled event: Design review")
    }

    func testFileNamesFromSubjects() {
        XCTAssertEqual(InvitationFiles.fileName("Invitation: Design review"), "Invitation Design review")
        XCTAssertEqual(InvitationFiles.fileName("../../etc/passwd"), "etc passwd", "no path survives")
        XCTAssertFalse(InvitationFiles.fileName("..hidden").hasPrefix("."))
        XCTAssertEqual(InvitationFiles.fileName(""), "Invitation")
        XCTAssertEqual(InvitationFiles.fileName(nil), "Invitation")
        XCTAssertEqual(InvitationFiles.fileName(String(repeating: "a", count: 200)).count, 80)
    }
}

/// A provider in memory that records invitation answers and can lack the calendar permission.
final class InvitationProvider: MailProvider, @unchecked Sendable {
    let accountID: AccountID
    let kind: ProviderKind = .gmail
    private let lock = NSLock()
    private var recorded: [InvitationAnswer] = []
    private var missing: AccountPermission?

    init(accountID: AccountID) {
        self.accountID = accountID
    }

    var answers: [InvitationAnswer] { lock.withLock { recorded } }
    var permission: AccountPermission? {
        get { lock.withLock { missing } }
        set { lock.withLock { missing = newValue } }
    }

    func missingPermission(for change: MetadataChange) async -> AccountPermission? {
        guard case .answerInvitation = change else { return nil }
        return permission
    }

    func apply(_ change: MetadataChange, to providerIDs: [String]) async throws {
        if case .answerInvitation(let answer) = change { lock.withLock { recorded.append(answer) } }
    }

    func profile() async throws -> AccountProfile { AccountProfile(email: "alex@contoso.test", displayName: "Alex") }
    func bootstrap(page: String?, limit: Int) async throws -> BootstrapPage {
        BootstrapPage(messages: [], nextPage: nil, changeCursor: "c")
    }
    func changes(since cursor: String, limit: Int) async throws -> ChangesPage {
        ChangesPage(upserts: [], deletedIDs: [], cursor: cursor, hasMore: false)
    }
    func metadata(for providerIDs: [String]) async throws -> [MessageMetadata] { [] }
    func body(for providerID: String) async throws -> MessageBody { throw ProviderError.notFound }
    func attachment(messageID providerID: String, attachmentID: String) async throws -> Data { throw ProviderError.notFound }
    func send(_ message: OutgoingMessage) async throws -> SendReceipt { throw ProviderError.notFound }
    func search(_ text: String, limit: Int) async throws -> [String] { [] }
}
