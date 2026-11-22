import AppKit
import PaperCore
import PaperDesign
import WebKit
import XCTest
@testable import PaperApp

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
                                storingAccount: Bool = true, html: String = "<p>Ben Carter has invited you.</p>",
                                attachments: [AttachmentInfo] = [], blockedImages: Int? = nil,
                                prepare: (InMemoryMailStore) throws -> Void = { _ in }) throws -> ConversationViewController {
        let store = InMemoryMailStore()
        if storingAccount { try store.upsertAccount(account) }
        try store.upsertMessages([MessageMetadata(
            id: messageID, conversationID: conversation, subject: "Invitation: Design review", snippet: "Ben Carter has invited you",
            from: EmailAddress(name: "Ben Carter", address: "ben@contoso.test"), to: [EmailAddress(address: account.email)],
            date: Date(), roles: [.inbox], isRead: true, isStarred: false, hasAttachments: !attachments.isEmpty
        )])
        try store.saveBody(StoredBody(body: MessageBody(html: html, text: nil, attachments: attachments), renderedHTML: html,
                                      plainText: "Ben Carter has invited you.", blockedRemoteImageCount: blockedImages,
                                      invitation: invitation ?? self.invitation()), for: messageID)
        try prepare(store)
        let engine = MailEngine(store: store, tokenStore: InMemoryTokenStore(), tokenProvider: DemoTokenProvider(),
                                authenticator: DemoAuthenticator(), sanitizer: HTMLSanitizer(), providerFactory: { _ in provider },
                                attachmentCacheDirectory: folder.appendingPathComponent("attachments", isDirectory: true))
        self.engine = engine
        engine.start()
        let reader = ConversationViewController(client: engine)
        _ = reader.view
        try open(conversation, in: reader)
        return reader
    }

    /// Shows `id` and waits until the slot on screen holds it rendered. A show soon after another is debounced, so the
    /// slot is looked up again on every turn.
    private func open(_ id: ConversationID, in reader: ConversationViewController) throws {
        reader.show(id)
        XCTAssertTrue(ListTestSupport.spin(until: {
            guard let slot = reader.pool.current else { return false }
            return slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == id
        }, timeout: 10), "the conversation rendered")
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

    /// The numbers a script returns as an array.
    private func numbers(_ script: String, in reader: ConversationViewController) -> [Double] {
        let json = evaluate("JSON.stringify(\(script))", in: reader)
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [NSNumber])?.map(\.doubleValue) ?? []
    }

    /// Whether the message under the card (the first sheet holding one) is folded, as the shell holds it.
    private let messageFolded = "document.querySelector('.ss-card.ss-mfold').classList.contains('ss-mfolded')"
    private let messageMark = "document.querySelector('.ss-card.ss-mfold .ss-mrow .ss-elide')"

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
        XCTAssertEqual(evaluate(messageFolded, in: reader), "true", "answered, the message stays folded under the card")
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
                              toBe: "Answer invitations: Paper needs permission to update your calendar.", in: reader, timeout: 10))
        XCTAssertTrue(provider.answers.isEmpty, "nothing goes out without the permission")
        XCTAssertEqual(evaluate(messageFolded, in: reader), "true", "with the notice, the message stays folded under the card")
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
        XCTAssertEqual(evaluate(messageFolded, in: reader), "true", "a cancellation folds its message too")
        XCTAssertEqual(evaluate("\(messageMark).textContent", in: reader), "Show message")
    }

    // MARK: The message under the card (spec §5.14, §5.15)

    /// The body under a card is most often the sender's own rendering of the same invitation: it starts folded behind the
    /// elision mark, where it would start, 16 pt under the card. Unfolded it shows whole, 12 pt under the mark; the mark,
    /// "." and the attachments below behave as they do for quoted text.
    func testTheMessageStartsFoldedUnderTheCardAndUnfoldsWithTheMark() throws {
        let agenda = AttachmentInfo(id: "att-1", filename: "agenda.pdf", mimeType: "application/pdf", sizeBytes: 24_000, isInline: false)
        let reader = try showInvitation(provider: InvitationProvider(accountID: account.id), attachments: [agenda])
        XCTAssertEqual(evaluate(messageFolded, in: reader), "true", "folded at open")
        XCTAssertEqual(evaluate("\(messageMark).textContent", in: reader), "Show message")
        XCTAssertEqual(evaluate("\(messageMark).title", in: reader), "Show Message  .")
        XCTAssertEqual(evaluate("\(messageMark).getAttribute('aria-pressed')", in: reader), "false")
        XCTAssertEqual(evaluate("\(messageMark).classList.contains('ss-on')", in: reader), "false")
        XCTAssertEqual(evaluate("getComputedStyle(document.querySelector('.ss-frame')).visibility", in: reader), "hidden")
        XCTAssertEqual(evaluate("document.querySelector('.ss-frame').hasAttribute('inert')", in: reader), "true",
                       "out of the Tab order and from VoiceOver")
        // The body is loaded and measured under the fold, so unfolding goes straight to its height.
        XCTAssertTrue(waitFor("window.ss.cardStates()[0].hasFrame && window.ss.measureAll()[0] > 0", toBe: "true", in: reader))
        let geometry = """
            (function () {
              var c = document.querySelector('.ss-card'), head = c.querySelector('.ss-head').getBoundingClientRect();
              var card = c.querySelector('.ss-invite').getBoundingClientRect(), mark = c.querySelector('.ss-mrow .ss-elide').getBoundingClientRect();
              var body = c.querySelector('.ss-body').getBoundingClientRect(), chip = c.querySelector('.ss-chip').getBoundingClientRect();
              return [mark.left - head.left, mark.top - card.bottom, mark.height, body.height, chip.top - mark.bottom, chip.height,
                      chip.top - body.bottom, body.top - mark.bottom];
            })()
            """
        let folded = numbers(geometry, in: reader)
        XCTAssertEqual(folded.count, 8)
        guard folded.count == 8 else { return }
        XCTAssertEqual(folded[0], 48, accuracy: 0.5, "at the indent")
        XCTAssertEqual(folded[1], 16, accuracy: 0.5, "where the body would start, the card's gap below unchanged")
        XCTAssertEqual(folded[2], 24, accuracy: 0.5, "the elision mark's height")
        XCTAssertEqual(folded[3], 0, accuracy: 0.5, "nothing of the body shows")
        XCTAssertEqual(folded[4], 16, accuracy: 0.5, "the attachments stay, 16 pt under the mark")
        XCTAssertEqual(folded[5], 44, accuracy: 0.5)

        _ = evaluate("\(messageMark).click()", in: reader)
        XCTAssertTrue(waitFor(messageFolded, toBe: "false", in: reader), "the mark unfolds it")
        XCTAssertEqual(evaluate("\(messageMark).textContent", in: reader), "Hide message")
        XCTAssertEqual(evaluate("\(messageMark).title", in: reader), "Hide Message  .")
        XCTAssertEqual(evaluate("\(messageMark).getAttribute('aria-pressed')", in: reader), "true")
        XCTAssertEqual(evaluate("\(messageMark).classList.contains('ss-on')", in: reader), "true")
        XCTAssertEqual(evaluate("document.querySelector('.ss-frame').hasAttribute('inert')", in: reader), "false")
        XCTAssertEqual(evaluate("document.querySelector('.ss-card iframe').contentDocument.body.textContent", in: reader),
                       "Ben Carter has invited you.", "the whole body, as it shows without a card")
        let open = numbers(geometry, in: reader)
        XCTAssertEqual(open.count, 8)
        guard open.count == 8 else { return }
        XCTAssertEqual(open[1], 16, accuracy: 0.5, "the mark stays where it was")
        XCTAssertGreaterThan(open[3], 0, "the body shows")
        XCTAssertEqual(open[7], 12, accuracy: 0.5, "12 pt under the mark")
        XCTAssertEqual(open[6], 16, accuracy: 0.5, "the attachments 16 pt under the body")
        XCTAssertEqual(evaluate("getComputedStyle(document.querySelector('.ss-frame')).visibility", in: reader), "visible")

        // "." (View › Show Quoted Text) folds and unfolds it on the target message.
        reader.toggleQuotedText(nil)
        XCTAssertTrue(waitFor(messageFolded, toBe: "true", in: reader), "\".\" folds it again")
        reader.toggleQuotedText(nil)
        XCTAssertTrue(waitFor(messageFolded, toBe: "false", in: reader), "and unfolds it")

        // Pressing the focused mark rebuilds it; the new one keeps the focus, so the next press folds back. The keys
        // themselves, through the app's monitors, are testSpaceAndReturnOnTheFocusedMarkReachIt's.
        _ = evaluate("\(messageMark).focus()", in: reader)
        _ = evaluate("document.activeElement.click()", in: reader)
        XCTAssertEqual(evaluate(messageFolded, in: reader), "true")
        XCTAssertEqual(evaluate("document.activeElement === \(messageMark)", in: reader), "true", "the focus stays on the mark")
        _ = evaluate("document.activeElement.click()", in: reader)
        XCTAssertEqual(evaluate(messageFolded, in: reader), "false")
    }

    /// The app sees every key before the page: in the reader Space is Quick Look and ↩ is Open (spec §6). A Google
    /// invitation keeps its invite.ics as a chip, so Space would preview it. On a focused elision mark both keys are the
    /// mark's (§5.15): the shell says where focus is, the router's Open and Quick Look let the keys go, and the page
    /// presses the mark with them, for the message under the card and then for its own quoted text. With focus off the
    /// marks, both keys mean what they did.
    func testSpaceAndReturnOnTheFocusedMarkReachIt() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let ics = AttachmentInfo(id: "att-ics", filename: "invite.ics", mimeType: "application/ics", sizeBytes: 1_200, isInline: false)
        let html = "<p>Ben Carter has invited you.</p><div class=\"ss-quote\"><p>Earlier</p></div>"
        let store = harness.environment.store
        try store.upsertMessages([MessageMetadata(
            id: messageID, conversationID: conversation, subject: "Invitation: Design review", snippet: "Ben Carter has invited you",
            from: EmailAddress(name: "Ben Carter", address: "ben@contoso.test"), to: [EmailAddress(address: account.email)],
            date: Date().addingTimeInterval(120), roles: [.inbox], isRead: true, isStarred: false, hasAttachments: true
        )])
        try store.saveBody(StoredBody(body: MessageBody(html: html, text: nil, attachments: [ics]), renderedHTML: html,
                                      plainText: "Ben Carter has invited you.", hasQuotedContent: true, invitation: invitation()),
                           for: messageID)
        let list = harness.list
        XCTAssertTrue(ListTestSupport.spin(until: { list.conversations.contains { $0.id == self.conversation } }, timeout: 5))
        list.selectedConversationID = conversation
        list.onSelectionChange?(conversation)
        let reader = harness.reader
        XCTAssertTrue(ListTestSupport.spin(until: {
            guard let slot = reader.pool.current else { return false }
            return slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == self.conversation
        }, timeout: 10), "the invitation rendered")
        XCTAssertTrue(waitFor("!!\(messageMark)", toBe: "true", in: reader))
        reader.attachmentPreview.presentsPanel = false
        // On screen (off to the side): WebKit takes keys only in a window that is. A test's window is seldom key, and the
        // app's monitors act only in the key window, so what they call for these keys (Open, Space's Quick Look) is
        // asked directly before the keys go to the page.
        let window = try XCTUnwrap(harness.controller.window)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let webView = try XCTUnwrap(reader.pool.current?.webView)
        XCTAssertTrue(window.makeFirstResponder(webView))
        XCTAssertTrue(harness.controller.isReaderFocused)
        XCTAssertFalse(reader.isMarkFocused, "nothing in the page has focus yet")

        _ = evaluate("\(messageMark).focus()", in: reader)
        XCTAssertTrue(ListTestSupport.spin(until: { reader.isMarkFocused }, timeout: 5), "the shell says the mark has focus")
        XCTAssertFalse(harness.controller.perform(.open), "↩ goes on to the page instead of Open")
        XCTAssertFalse(reader.openQuickLookForSelectedMessage(), "Space goes on to the page instead of previewing invite.ics")

        // The keys as the window then delivers them to the page.
        try press("\r", keyCode: 36, in: window)
        XCTAssertTrue(waitFor(messageFolded, toBe: "false", in: reader), "↩ unfolds the message")
        XCTAssertEqual(evaluate("document.activeElement === \(messageMark)", in: reader), "true", "the mark keeps the focus")
        try press(" ", keyCode: 49, in: window)
        XCTAssertTrue(waitFor(messageFolded, toBe: "true", in: reader), "Space folds it again")
        try press(" ", keyCode: 49, in: window)
        XCTAssertTrue(waitFor(messageFolded, toBe: "false", in: reader))

        // Its own quoted text, by the same keys on its own toggle.
        let quotesShown = "document.querySelector('.ss-card iframe').contentDocument.body.classList.contains('ss-show-quotes')"
        _ = evaluate("document.querySelector('.ss-toggle-quote').focus()", in: reader)
        XCTAssertTrue(ListTestSupport.spin(until: { reader.isMarkFocused }, timeout: 5))
        XCTAssertFalse(reader.openQuickLookForSelectedMessage())
        try press(" ", keyCode: 49, in: window)
        XCTAssertTrue(waitFor(quotesShown, toBe: "true", in: reader), "Space shows the quoted text")
        XCTAssertFalse(harness.controller.perform(.open))
        try press("\r", keyCode: 36, in: window)
        XCTAssertTrue(waitFor(quotesShown, toBe: "false", in: reader), "↩ hides it")

        // Focus off the marks: the keys are Open's and Quick Look's again.
        _ = evaluate("document.querySelector('.ss-card').focus()", in: reader)
        XCTAssertTrue(ListTestSupport.spin(until: { !reader.isMarkFocused }, timeout: 5), "the shell says the mark lost focus")
        XCTAssertTrue(harness.controller.perform(.open), "↩ is Open's again")
        _ = evaluate("\(messageMark).focus()", in: reader)
        XCTAssertTrue(ListTestSupport.spin(until: { reader.isMarkFocused }, timeout: 5))
        XCTAssertTrue(window.makeFirstResponder(harness.list.tableView))
        XCTAssertFalse(reader.isMarkFocused, "the page's focus counts only while the reader has the window's")
    }

    /// A plain key as the window delivers it, down then up: a button takes Space on its release.
    private func press(_ characters: String, keyCode: UInt16, in window: NSWindow) throws {
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
            NSApp.sendEvent(event)
        }
    }

    /// Unfolded, the body shows exactly as it would without a card: its own quoted text folded under its own toggle,
    /// which names no key, since "." folds the message there.
    func testItsOwnQuotedTextStaysFoldedUnderItsOwnToggle() throws {
        let html = "<p>Ben Carter has invited you.</p><div class=\"ss-quote\"><p>Earlier</p></div>"
        let reader = try showInvitation(provider: InvitationProvider(accountID: account.id), html: html) { store in
            var body = try XCTUnwrap(store.body(for: self.messageID))
            body.hasQuotedContent = true
            try store.saveBody(body, for: self.messageID)
        }
        let quoteRow = "getComputedStyle(document.querySelector('.ss-qrow')).display"
        let quotesShown = "document.querySelector('.ss-card iframe').contentDocument.body.classList.contains('ss-show-quotes')"
        XCTAssertEqual(evaluate(quoteRow, in: reader), "none", "folded with the message")
        _ = evaluate("\(messageMark).click()", in: reader)
        XCTAssertTrue(waitFor(messageFolded, toBe: "false", in: reader))
        XCTAssertNotEqual(evaluate(quoteRow, in: reader), "none")
        XCTAssertEqual(evaluate("document.querySelector('.ss-toggle-quote').textContent", in: reader), "Show quoted text")
        XCTAssertEqual(evaluate("document.querySelector('.ss-toggle-quote').title", in: reader), "Show Quoted Text")
        XCTAssertEqual(evaluate(quotesShown, in: reader), "false", "its quoted text still folded")

        _ = evaluate("document.querySelector('.ss-toggle-quote').focus()", in: reader)
        _ = evaluate("document.activeElement.click()", in: reader)
        XCTAssertEqual(evaluate(quotesShown, in: reader), "true", "and unfolded by its own toggle")
        XCTAssertEqual(evaluate("document.activeElement === document.querySelector('.ss-toggle-quote')", in: reader), "true",
                       "which keeps the focus a Space or ↩ gave it")

        reader.toggleQuotedText(nil)
        XCTAssertTrue(waitFor(messageFolded, toBe: "true", in: reader), "\".\" folds the message, not its quote")
        XCTAssertEqual(evaluate(quotesShown, in: reader), "true")
        XCTAssertEqual(evaluate("document.activeElement === \(messageMark)", in: reader), "true",
                       "the focus the fold hid moves to the mark rather than falling to the page")

        // Focus in the body itself (a link, with Full Keyboard Access) moves to the mark too, never left on the inert frame.
        reader.toggleQuotedText(nil)
        XCTAssertTrue(waitFor(messageFolded, toBe: "false", in: reader))
        _ = evaluate("document.querySelector('.ss-card iframe').focus()", in: reader)
        XCTAssertEqual(evaluate("document.activeElement.tagName", in: reader), "IFRAME")
        reader.toggleQuotedText(nil)
        XCTAssertTrue(waitFor(messageFolded, toBe: "true", in: reader))
        XCTAssertEqual(evaluate("document.activeElement === \(messageMark)", in: reader), "true")
    }

    /// Everything that reads the body works with it folded, as with folded quoted text: its banners stay in view, 12 pt
    /// under the mark where the body starts, so Load images (the banner's link, ⇧⌘I, More) answers where it can be seen,
    /// loads the message's images under the fold and leaves it folded, and they are there when it unfolds.
    func testImagesLoadUnderTheFold() throws {
        // A parked image whose source is data, so loading it reaches no network.
        let parked = "<img data-ss-src=\"data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7\" alt=\"\">"
        let reader = try showInvitation(provider: InvitationProvider(accountID: account.id),
                                        html: "<p>Ben Carter has invited you.</p>" + parked, blockedImages: 1)
        XCTAssertEqual(evaluate("window.ss.targetState().imagesBlocked", in: reader), "true", "the More menu offers Load Images")
        XCTAssertEqual(evaluate("getComputedStyle(document.querySelector('.ss-load-images')).visibility", in: reader), "visible",
                       "its banner stays in view over the folded body, as over folded quoted text")
        let geometry = "(function () { var mark = \(messageMark).getBoundingClientRect();"
            + " var banner = document.querySelector('.ss-banners .ss-banner').getBoundingClientRect();"
            + " var frame = document.querySelector('.ss-frame').getBoundingClientRect();"
            + " var foot = document.querySelector('.ss-card .ss-foot').getBoundingClientRect();"
            + " return [banner.top - mark.bottom, frame.height, foot.top - banner.bottom]; })()"
        let folded = numbers(geometry, in: reader)
        XCTAssertEqual(folded.count, 3)
        if folded.count == 3 {
            XCTAssertEqual(folded[0], 12, accuracy: 0.5, "12 pt under the mark, where the body starts")
            XCTAssertEqual(folded[1], 0, accuracy: 0.5, "the body itself folded")
            XCTAssertEqual(folded[2], 16, accuracy: 0.5, "the footer 16 pt under it, as under the mark alone")
        }
        XCTAssertEqual(evaluate("(function () { document.querySelector('.ss-load-images').click();"
                                + " var b = document.querySelector('.ss-banners .ss-banner');"
                                + " return b.textContent + ' | ' + getComputedStyle(b).visibility; })()", in: reader),
                       "Loading 1 image\u{2026} | visible", "its progress shows where it can be seen")
        XCTAssertTrue(waitFor("window.ss.cardStates()[0].imagesLoaded", toBe: "true", in: reader))
        XCTAssertEqual(evaluate(messageFolded, in: reader), "true", "loading images does not unfold it, as it leaves quoted text folded")
        XCTAssertTrue(waitFor("(function () { var f = document.querySelector('.ss-card iframe'); var d = f && f.contentDocument;"
                              + " var i = d && d.querySelector('img'); return !!i && (i.getAttribute('src') || '').indexOf('data:') === 0; })()",
                              toBe: "true", in: reader), "the image is restored in the folded body")
        _ = evaluate("\(messageMark).click()", in: reader)
        XCTAssertTrue(waitFor(messageFolded, toBe: "false", in: reader))
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-load-images').length", in: reader), "0", "no images left to load")
        XCTAssertEqual(evaluate("window.ss.targetState().imagesBlocked", in: reader), "false")
    }

    /// The fold is remembered and forgotten as the quoted-text toggle's is: per message, through the store's re-renders
    /// (an answer, the mark-read), kept while the reader still holds the conversation and forgotten once it renders it
    /// afresh. A message without a card in the same conversation shows as before, with no mark.
    func testTheFoldIsRememberedAndForgottenAsQuotedTextIs() throws {
        let quoted = MessageID(accountID: account.id, providerID: "msg-quoted")
        let others = (1...3).map { ConversationID(accountID: account.id, providerID: "thread-other-\($0)") }
        let reader = try showInvitation(provider: InvitationProvider(accountID: account.id)) { store in
            let quotedHTML = "<p>Does Tuesday work?</p><div class=\"ss-quote\"><p>Earlier</p></div>"
            try store.upsertMessages([MessageMetadata(
                id: quoted, conversationID: self.conversation, subject: "Design review", snippet: "Does Tuesday work?",
                from: EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test"), to: [EmailAddress(address: self.account.email)],
                date: Date().addingTimeInterval(-3_600), roles: [.inbox], isRead: false, isStarred: false, hasAttachments: false
            )])
            try store.saveBody(StoredBody(body: MessageBody(html: quotedHTML, text: nil), renderedHTML: quotedHTML,
                                          plainText: "Does Tuesday work?", hasQuotedContent: true), for: quoted)
            for (index, other) in others.enumerated() {
                let id = MessageID(accountID: self.account.id, providerID: "msg-other-\(index)")
                try store.upsertMessages([MessageMetadata(
                    id: id, conversationID: other, subject: "Other \(index)", snippet: "Other",
                    from: EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test"), to: [EmailAddress(address: self.account.email)],
                    date: Date().addingTimeInterval(-7_200 - Double(index)), roles: [.inbox], isRead: true, isStarred: false,
                    hasAttachments: false
                )])
                try store.saveBody(StoredBody(body: MessageBody(html: "<p>Other</p>", text: nil), renderedHTML: "<p>Other</p>",
                                              plainText: "Other"), for: id)
            }
        }
        let states = "JSON.stringify(window.ss.cardStates().map(function (s) { return [s.foldsMessage, s.messageShown, s.quotesShown]; }))"
        XCTAssertEqual(evaluate(states, in: reader), "[[false,false,false],[true,false,false]]",
                       "the earlier message has no card and no fold; the invitation's is folded")
        XCTAssertEqual(evaluate("getComputedStyle(document.querySelectorAll('.ss-card')[0].querySelector('.ss-mrow')).display", in: reader),
                       "none", "no mark without a card")
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-card')[0].querySelector('.ss-toggle-quote').title", in: reader),
                       "Show Quoted Text  .", "\".\" still names quoted text where there is no card")

        _ = evaluate("document.querySelector('.ss-toggle-quote').click()", in: reader)
        _ = evaluate("\(messageMark).click()", in: reader)
        XCTAssertEqual(evaluate(states, in: reader), "[[false,false,true],[true,true,false]]")

        // The store renders the conversation again with the answer (and the mark-read): both stay as the user set them.
        _ = evaluate("document.querySelector('.ss-ans[data-response=\"accepted\"]').click()", in: reader)
        XCTAssertTrue(ListTestSupport.spin(until: { reader.pool.current?.renderedInputs?.messages.last?.invitationReply == .accepted },
                                           timeout: 5), "rendered again with the answer")
        XCTAssertTrue(waitFor("document.querySelector('.ss-ans.ss-chosen').dataset.response", toBe: "accepted", in: reader))
        XCTAssertEqual(evaluate(states, in: reader), "[[false,false,true],[true,true,false]]", "kept through the store's re-render")

        // Shown again while the reader still holds it: kept, as the shown quote is.
        try open(others[0], in: reader)
        try open(conversation, in: reader)
        XCTAssertEqual(evaluate(states, in: reader), "[[false,false,true],[true,true,false]]", "kept, like the quote")

        // Rendered afresh once the reader has let it go: forgotten, as the shown quote is.
        for other in others { try open(other, in: reader) }
        try open(conversation, in: reader)
        XCTAssertEqual(evaluate(states, in: reader), "[[false,false,false],[true,false,false]]", "forgotten, like the quote")
    }

    // MARK: The overlap line (spec §5.14)

    /// 10:00 two days ahead on this Mac's clock, so the times a line names are whole minutes on one day.
    private lazy var meeting: Date = {
        let day = Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date()
        return Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
    }()

    /// The invitation from 10:00 to 11:00.
    private func meetingInvitation() -> CalendarInvitation {
        var invitation = invitation()
        invitation.start = meeting
        invitation.end = meeting.addingTimeInterval(3_600)
        return invitation
    }

    /// An event of the account's calendar `minutes` long from `offset` minutes after the meeting starts.
    private func calendarEvent(_ id: String, _ title: String, at offset: Double, minutes: Double, isFree: Bool = false,
                               response: CalendarEvent.Response = .accepted, uid: String? = nil) -> CalendarEvent {
        let start = meeting.addingTimeInterval(offset * 60)
        return CalendarEvent(id: CalendarEvent.localID(accountID: account.id, providerID: id), accountID: account.id, providerID: id,
                             title: title, start: start, end: start.addingTimeInterval(minutes * 60), response: response, isFree: isFree,
                             invitationUID: uid)
    }

    /// The calendar's copy of the invitation, as Google adds it.
    private func ownCopy(_ response: CalendarEvent.Response = .needsAction) -> CalendarEvent {
        calendarEvent("own", "Design review", at: 0, minutes: 60, response: response, uid: "uid-1@google.com")
    }

    /// What a read of the account's calendar found, as the engine writes it.
    private func read(_ events: [CalendarEvent], into store: InMemoryMailStore) throws {
        try store.replaceCalendarEvents(events, accountID: account.id,
                                        window: DateInterval(start: meeting.addingTimeInterval(-7 * 86_400), duration: 14 * 86_400))
    }

    /// “10:30” as the When line writes a time on this Mac: its zone, its locale's 12- or 24-hour clock.
    private func clock(_ offset: Double) -> String {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        return formatter.string(from: meeting.addingTimeInterval(offset * 60))
    }

    private let overlapLine = "document.querySelector('.ss-invite .ss-iover') ? document.querySelector('.ss-invite .ss-iover').textContent : ''"

    func testTheCardSaysWhatItOverlapsAndFollowsTheCalendar() throws {
        var store: InMemoryMailStore?
        let sam = calendarEvent("sam", "1:1 with Sam", at: 30, minutes: 60)
        let reader = try showInvitation(meetingInvitation(), provider: InvitationProvider(accountID: account.id)) { prepared in
            store = prepared
            try self.read([self.ownCopy(), sam], into: prepared)
        }
        let calendar = try XCTUnwrap(store)
        XCTAssertEqual(evaluate(overlapLine, in: reader), "Overlaps 1:1 with Sam, \(clock(30)) - \(clock(60))",
                       "the time the two share, never the invitation's own copy")
        XCTAssertEqual(evaluate("document.querySelector('.ss-iover > .ss-sym').classList.contains('ss-sym-' + '\(Quire.Icon.warning)'.split('.').join('-'))",
                                in: reader), "true", "the warning glyph")
        let colours = """
            (function () {
              var probe = document.createElement('div'); document.body.appendChild(probe);
              probe.style.color = 'var(--q-warning)'; var warning = getComputedStyle(probe).color;
              probe.style.color = 'var(--q-ink)'; var ink = getComputedStyle(probe).color; probe.remove();
              var line = document.querySelector('.ss-iover');
              return [getComputedStyle(line.querySelector('.ss-sym')).backgroundColor === warning,
                      getComputedStyle(line.querySelector('span')).color === ink].join();
            })()
            """
        XCTAssertEqual(evaluate(colours, in: reader), "true,true", "the glyph in warning, the words in ink")
        // Read right after When (the document's order, which VoiceOver follows), drawn under the details.
        XCTAssertEqual(evaluate("document.querySelector('.ss-iover').previousElementSibling.className", in: reader), "ss-iwhen")
        let edges = numbers("""
            [document.querySelector('.ss-idet').getBoundingClientRect().bottom, document.querySelector('.ss-iover').getBoundingClientRect().top,
             document.querySelector('.ss-iover').getBoundingClientRect().bottom, document.querySelector('.ss-iacts').getBoundingClientRect().top]
            """, in: reader)
        XCTAssertEqual(edges.count, 4)
        if edges.count == 4 {
            XCTAssertEqual(edges[1] - edges[0], Quire.Layout.Invitation.detailsTop, accuracy: 0.5, "detailsTop under the details")
            XCTAssertGreaterThan(edges[3], edges[2], "the answers stay below it")
        }

        // Let anything the open set off land, then count renders.
        ListTestSupport.spin(for: 0.5)
        let slot = try XCTUnwrap(reader.pool.current)
        let rendered = slot.tracker.generation

        // Writes that leave the line's words as they are: a free event in the hour, the invitation's own copy answered,
        // an event on another day (outside what the reader watches). None renders the conversation again.
        let focus = calendarEvent("focus", "Focus time", at: 0, minutes: 60, isFree: true)
        let tomorrow = calendarEvent("tomorrow", "Standup", at: 24 * 60, minutes: 15)
        try read([ownCopy(.accepted), sam, focus, tomorrow], into: calendar)
        ListTestSupport.spin(for: 0.5)
        XCTAssertEqual(slot.tracker.generation, rendered, "an unrelated calendar write renders nothing")
        XCTAssertEqual(evaluate(overlapLine, in: reader), "Overlaps 1:1 with Sam, \(clock(30)) - \(clock(60))")

        // An overlapping event arrives: the line names the first by start and counts the rest, rendered once, in place.
        let hiring = calendarEvent("hiring", "Hiring sync", at: -30, minutes: 45)
        try read([ownCopy(.accepted), sam, focus, tomorrow, hiring], into: calendar)
        XCTAssertTrue(waitFor(overlapLine, toBe: "Overlaps Hiring sync, \(clock(0)) - \(clock(15)), and 1 more", in: reader))
        XCTAssertEqual(slot.tracker.generation, rendered + 1, "one render in place")
        XCTAssertTrue(reader.pool.current === slot)

        // Nothing overlaps any more: the line goes and the card stays.
        try read([ownCopy(.accepted), focus, tomorrow], into: calendar)
        XCTAssertTrue(waitFor(overlapLine, toBe: "", in: reader))
        XCTAssertEqual(evaluate("document.querySelector('.ss-invite .ss-ititle').textContent", in: reader), "Design review")
    }

    func testDecliningTakesTheLineAwayAndAnsweringAgainBringsItBack() throws {
        let sam = calendarEvent("sam", "1:1 with Sam", at: 30, minutes: 60)
        let reader = try showInvitation(meetingInvitation(), provider: InvitationProvider(accountID: account.id)) { store in
            try self.read([sam], into: store)
        }
        let line = "Overlaps 1:1 with Sam, \(clock(30)) - \(clock(60))"
        XCTAssertEqual(evaluate(overlapLine, in: reader), line)
        _ = evaluate("document.querySelector('.ss-ans[data-response=\"declined\"]').click()", in: reader)
        XCTAssertTrue(waitFor(overlapLine, toBe: "", in: reader), "it goes the moment the user declines")
        _ = evaluate("document.querySelector('.ss-ans[data-response=\"accepted\"]').click()", in: reader)
        XCTAssertTrue(waitFor(overlapLine, toBe: line, in: reader), "and comes back when they answer again")
    }

    /// A conversation kept rendered off screen while the calendar changed is brought up to it as it comes back on screen.
    func testAKeptRenderCatchesUpWithTheCalendarWhenShownAgain() throws {
        let other = ConversationID(accountID: account.id, providerID: "thread-other")
        var store: InMemoryMailStore?
        let reader = try showInvitation(meetingInvitation(), provider: InvitationProvider(accountID: account.id)) { prepared in
            store = prepared
            let id = MessageID(accountID: self.account.id, providerID: "msg-other")
            try prepared.upsertMessages([MessageMetadata(
                id: id, conversationID: other, subject: "Other", snippet: "Other",
                from: EmailAddress(name: "Ada Lovelace", address: "ada@contoso.test"), to: [EmailAddress(address: self.account.email)],
                date: Date().addingTimeInterval(-7_200), roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false
            )])
            try prepared.saveBody(StoredBody(body: MessageBody(html: "<p>Other</p>", text: nil), renderedHTML: "<p>Other</p>",
                                             plainText: "Other"), for: id)
        }
        XCTAssertEqual(evaluate(overlapLine, in: reader), "", "nothing on the calendar yet")
        let held = try XCTUnwrap(reader.pool.current)
        try open(other, in: reader)
        XCTAssertFalse(reader.pool.current === held)

        try read([calendarEvent("sam", "1:1 with Sam", at: 30, minutes: 60)], into: try XCTUnwrap(store))
        try open(conversation, in: reader)
        XCTAssertTrue(reader.pool.current === held, "the kept render is shown again")
        XCTAssertTrue(waitFor(overlapLine, toBe: "Overlaps 1:1 with Sam, \(clock(30)) - \(clock(60))", in: reader))
    }

    /// The shell's stylesheet lives in PaperCore, which cannot read the tokens; this holds the overlap line's numbers to
    /// `layout.invitation`, and its glyph to `icon.warning`.
    func testTheOverlapLinesMetricsAreTheTokens() {
        let invitation = Quire.Layout.Invitation.self
        let css = ConversationShellAssets.css
        func px(_ value: CGFloat) -> String { "\(Int(value))px" }
        XCTAssertTrue(css.contains(".ss-iover { order: 1; margin-top: \(px(invitation.detailsTop)); display: flex; align-items: flex-start; gap: \(px(invitation.kickerGap));"))
        XCTAssertTrue(css.contains(".ss-iover > .ss-sym { font-size: \(px(invitation.answerGlyph)); width: \(px(invitation.answerGlyph)); height: \(px(invitation.answerGlyph)); margin-top: calc((1lh - \(px(invitation.answerGlyph))) / 2); color: var(--q-warning); }"))
        XCTAssertTrue(ConversationShellAssets.js.contains("sym('\(Quire.Icon.warning)')"))
        XCTAssertTrue(ConversationShellAssets.symbols.contains(Quire.Icon.warning), "a glyph the reader rasterises")
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
