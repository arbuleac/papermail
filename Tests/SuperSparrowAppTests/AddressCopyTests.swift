import AppKit
import ObjectiveC
import OSLog
import SSCore
import WebKit
import XCTest
@testable import SSDesign
@testable import SuperSparrowApp

/// Copying an address from a sheet header (spec §5.14), in the app: the shell names a position, the reader reads the
/// address from the store and writes the pasteboard, then has the shell show the mark and VoiceOver say it. Every copy
/// goes to a private pasteboard, never the user's; the window is a throwaway store's, off screen.
@MainActor
final class AddressCopyTests: XCTestCase {
    private var harness: MainWindowHarness!
    private var pasteboard: NSPasteboard!
    private var spoken: [String] = []

    private let ben = EmailAddress(name: "Ben Carter", address: "ben@contoso.test")
    private let priya = EmailAddress(name: "Priya Raman", address: "priya@contoso.test")
    private let tom = EmailAddress(address: "tom@contoso.test")
    private let dana = EmailAddress(name: "Dana Wu", address: "dana@contoso.test")
    private let hidden = EmailAddress(name: "Quiet One", address: "quiet@contoso.test")
    /// An address no message can go to: a local name with no domain.
    private let desk = EmailAddress(name: "Ops desk", address: "ops-desk")
    private var me: EmailAddress { EmailAddress(name: ListTestSupport.accountA.displayName, address: ListTestSupport.accountA.email) }
    private var conversation: ConversationID { ConversationID(accountID: ListTestSupport.accountA.id, providerID: "thread-copy") }
    private var received: MessageID { MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-received") }
    private var sent: MessageID { MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-sent") }

    override func setUpWithError() throws {
        harness = try MainWindowHarness()
        pasteboard = NSPasteboard.withUniqueName()
        harness.reader.pasteboard = pasteboard
        spoken = []
        QuireAccessibility.observer = { [weak self] _, text in if let text { self?.spoken.append(text) } }
        let now = Date().addingTimeInterval(120)
        try harness.environment.store.upsertMessages([
            MessageMetadata(id: received, conversationID: conversation, subject: "The plan", snippet: "Here it is",
                            from: ben, to: [me, priya, desk], cc: [tom], bcc: [hidden], date: now.addingTimeInterval(-60),
                            roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false),
            MessageMetadata(id: sent, conversationID: conversation, subject: "Re: The plan", snippet: "Thanks",
                            from: me, to: [ben], bcc: [dana], date: now, roles: [.inbox, .sent], isRead: true, isStarred: false,
                            hasAttachments: false),
        ])
        for id in [received, sent] {
            try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: "<p>Hi</p>", text: "Hi"), renderedHTML: "<p>Hi</p>",
                                                              plainText: "Hi"), for: id)
        }
        let id = conversation
        harness.spin(until: { self.harness.list.conversations.contains { $0.id == id } })
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        XCTAssertTrue(ListTestSupport.spin(until: {
            guard let slot = self.harness.reader.pool.current else { return false }
            return slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == id
        }, timeout: 10), "the conversation renders")
    }

    override func tearDownWithError() throws {
        QuireAccessibility.observer = nil
        pasteboard.releaseGlobally()
        harness.close()
        harness = nil
    }

    // MARK: The copy

    /// A position reads back to the stored address and the pasteboard takes it as plain text alone: the sender, a
    /// recipient, Bcc on the user's own mail only. A position that names nothing writes nothing and says nothing.
    func testACopyWritesTheStoredAddressAsPlainText() {
        let reader = harness.reader
        XCTAssertTrue(reader.copyAddress(.sender, of: received, form: .address))
        XCTAssertEqual(pasteboard.string(forType: .string), "ben@contoso.test")
        let plain: Set<NSPasteboard.PasteboardType> = [.string, NSPasteboard.PasteboardType("NSStringPboardType")]
        XCTAssertTrue(Set(pasteboard.types ?? []).isSubset(of: plain), "plain text only, no RTF, no link: \(pasteboard.types ?? [])")
        XCTAssertTrue(reader.copyAddress(HeaderAddress(field: .to, index: 1), of: received, form: .address))
        XCTAssertEqual(pasteboard.string(forType: .string), "priya@contoso.test")
        XCTAssertTrue(reader.copyAddress(HeaderAddress(field: .cc, index: 0), of: received, form: .address))
        XCTAssertEqual(pasteboard.string(forType: .string), "tom@contoso.test")
        XCTAssertTrue(reader.copyAddress(HeaderAddress(field: .bcc, index: 0), of: sent, form: .address))
        XCTAssertEqual(pasteboard.string(forType: .string), "dana@contoso.test", "Bcc on mail the user sent")

        let before = pasteboard.changeCount
        XCTAssertFalse(reader.copyAddress(HeaderAddress(field: .bcc, index: 0), of: received, form: .address),
                       "Bcc on someone else's mail is no header's")
        XCTAssertFalse(reader.copyAddress(HeaderAddress(field: .to, index: 9), of: received, form: .address), "out of range")
        XCTAssertEqual(pasteboard.changeCount, before, "nothing written")
        XCTAssertEqual(spoken, ["Copied ben@contoso.test.", "Copied priya@contoso.test.", "Copied tom@contoso.test.",
                                "Copied dana@contoso.test."])
    }

    /// A copy the pasteboard refuses beeps once, though ⌘C reaches it through the web view, and shows and says nothing;
    /// ⌘C on a position that names nothing any more beeps once too.
    func testACopyThatCannotBeMadeBeepsOnce() throws {
        let reader = harness.reader
        var beeps = 0
        reader.beep = { beeps += 1 }
        let slot = try XCTUnwrap(reader.pool.current)
        let webView = try XCTUnwrap(slot.webView as? ReaderWebView)
        _ = evaluate(openList(of: received) + "card.querySelector('.ss-rp[data-addr=\"to:1\"]').focus(); true", in: webView)
        XCTAssertTrue(ListTestSupport.spin(until: { slot.focusedAddress != nil }, timeout: 5))

        // AppKit hands pasteboards out from a factory, so the private one takes a refusing subclass's class for the write.
        object_setClass(pasteboard, RefusingPasteboard.self)
        let handled = NSApp.sendAction(#selector(NSText.copy(_:)), to: webView, from: nil)
        object_setClass(pasteboard, NSPasteboard.self)
        XCTAssertTrue(handled)
        XCTAssertEqual(beeps, 1, "one refusal, one beep")
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertEqual(spoken, [], "nothing is announced")
        ListTestSupport.spin(for: 0.2)
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-mark').length", in: webView) as? Int, 0, "and no mark shows")

        slot.focusedAddress = ConversationScriptMessage.FocusedAddress(messageID: received, address: HeaderAddress(field: .to, index: 9))
        XCTAssertTrue(NSApp.sendAction(#selector(NSText.copy(_:)), to: webView, from: nil))
        XCTAssertEqual(beeps, 2, "⌘C on a position that names nothing beeps once")
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    /// The app copies only what the page was given: a message in the Trash beside one still in the Inbox, or one in Spam,
    /// has no sheet, so a position on it copies nothing and opens no menu, though the store holds it.
    func testAMessageThePageDoesNotShowCopiesNothing() throws {
        let store = harness.environment.store
        let trashed = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-trashed")
        let spam = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-spam")
        let now = Date()
        try store.upsertMessages([
            MessageMetadata(id: trashed, conversationID: conversation, subject: "Re: The plan", snippet: "Old", from: dana, to: [me],
                            date: now.addingTimeInterval(-30), roles: [.trash], isRead: true, isStarred: false, hasAttachments: false),
            MessageMetadata(id: spam, conversationID: conversation, subject: "Re: The plan", snippet: "Win", from: desk, to: [me],
                            date: now.addingTimeInterval(-20), roles: [.spam], isRead: true, isStarred: false, hasAttachments: false),
        ])
        XCTAssertEqual(try store.messages(in: conversation).count, 4)
        ListTestSupport.spin(for: 0.3)
        let reader = harness.reader
        let before = pasteboard.changeCount
        for id in [trashed, spam] {
            XCTAssertFalse(reader.copyAddress(.sender, of: id, form: .address), id.providerID)
            XCTAssertFalse(reader.copyAddress(HeaderAddress(field: .to, index: 0), of: id, form: .nameAndAddress), id.providerID)
            XCTAssertNil(reader.makePersonMenu(for: .sender, of: id), id.providerID)
        }
        XCTAssertEqual(pasteboard.changeCount, before, "nothing written")
        XCTAssertEqual(spoken, [])
        XCTAssertTrue(reader.copyAddress(.sender, of: received, form: .address), "the messages it shows still copy")
    }

    /// Copy Name and Address writes the address as the composer's tokens copy it; for the user it is the name the header
    /// gives, never “me”.
    func testCopyNameAndAddressWritesTheFormattedAddress() {
        let reader = harness.reader
        XCTAssertTrue(reader.copyAddress(HeaderAddress(field: .to, index: 1), of: received, form: .nameAndAddress))
        XCTAssertEqual(pasteboard.string(forType: .string), "Priya Raman <priya@contoso.test>")
        XCTAssertTrue(reader.copyAddress(HeaderAddress(field: .to, index: 0), of: received, form: .nameAndAddress))
        XCTAssertEqual(pasteboard.string(forType: .string), "Alex Morgan <alex@contoso.test>")
        XCTAssertEqual(spoken.last, "Copied Alex Morgan, alex@contoso.test.")
    }

    /// A click in the page posts the position; the app writes the pasteboard, and only then the mark shows.
    func testAClickInThePageCopiesThroughTheApp() throws {
        let webView = try XCTUnwrap(harness.reader.pool.current?.webView)
        _ = evaluate(openList(of: received) + "card.querySelector('.ss-rp[data-addr=\"cc:0\"]').click(); true", in: webView)
        XCTAssertTrue(ListTestSupport.spin(until: { self.pasteboard.string(forType: .string) == "tom@contoso.test" }, timeout: 5))
        XCTAssertTrue(ListTestSupport.spin(until: {
            (self.evaluate(self.openCard(of: self.received) + "card.querySelectorAll('.ss-rp[data-addr=\"cc:0\"] .ss-copied').length", in: webView)
                as? Int) == 1
        }, timeout: 5), "the mark shows once the pasteboard has it")
        XCTAssertEqual(spoken, ["Copied tom@contoso.test."])
    }

    /// More › Copy Sender Address takes the click's path: the mark shows on the sender's address and VoiceOver hears it.
    func testMoreCopySenderAddressShowsTheMark() throws {
        let reader = harness.reader
        let webView = try XCTUnwrap(reader.pool.current?.webView)
        _ = evaluate("window.ss.expandAll(); true", in: webView)
        reader.setTarget(received)
        let menu = reader.makeMoreMenu(for: received, shellState: [:])
        let item = try XCTUnwrap(menu.items.first { $0.title == "Copy Sender Address" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(pasteboard.string(forType: .string), "ben@contoso.test")
        XCTAssertEqual(spoken, ["Copied ben@contoso.test."])
        XCTAssertTrue(ListTestSupport.spin(until: {
            (self.evaluate(self.openCard(of: self.received) + "card.querySelectorAll('.ss-addr .ss-copied').length", in: webView) as? Int) == 1
        }, timeout: 5))
    }

    /// Edit › Copy (and ⌘C, its key equivalent) is enabled while keyboard focus is on a recipient, with nothing selected,
    /// and copies it; with focus elsewhere it is WebKit's.
    func testEditCopyCopiesTheFocusedAddress() throws {
        let slot = try XCTUnwrap(harness.reader.pool.current)
        let webView = try XCTUnwrap(slot.webView as? ReaderWebView)
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        _ = evaluate("window.getSelection().removeAllRanges(); true", in: webView)
        XCTAssertFalse(webView.hasFocusedAddress(), "focus on no address: Edit › Copy is WebKit's")

        _ = evaluate(openList(of: received) + "card.querySelector('.ss-rp[data-addr=\"to:1\"]').focus(); true", in: webView)
        XCTAssertTrue(ListTestSupport.spin(until: { slot.focusedAddress != nil }, timeout: 5))
        XCTAssertEqual(slot.focusedAddress?.address, HeaderAddress(field: .to, index: 1))
        XCTAssertTrue(slot.addressesFocused)
        XCTAssertTrue(webView.validateUserInterfaceItem(copy), "enabled with a recipient focused")
        XCTAssertTrue(NSApp.sendAction(#selector(NSText.copy(_:)), to: webView, from: copy))
        XCTAssertEqual(pasteboard.string(forType: .string), "priya@contoso.test")
    }

    // MARK: The person menu

    /// Items that do not apply are hidden: Copy Name and Address without a name, New Message for an address no message
    /// can go to. Its commands copy, write and search through the app.
    func testThePersonMenuHidesWhatDoesNotApply() throws {
        let reader = harness.reader
        func titles(_ address: HeaderAddress) -> [String]? {
            reader.makePersonMenu(for: address, of: received)?.items.map { $0.isSeparatorItem ? "—" : $0.title }
        }
        XCTAssertEqual(titles(HeaderAddress(field: .to, index: 1)),
                       ["Copy Address", "Copy Name and Address", "—", "New Message", "Show Mail from This Person"])
        XCTAssertEqual(titles(HeaderAddress(field: .cc, index: 0)), ["Copy Address", "—", "New Message", "Show Mail from This Person"],
                       "no name apart from the address")
        XCTAssertEqual(titles(HeaderAddress(field: .to, index: 2)),
                       ["Copy Address", "Copy Name and Address", "—", "Show Mail from This Person"], "no message can go to it")
        XCTAssertNil(titles(HeaderAddress(field: .to, index: 7)), "a position that names nothing opens no menu")

        var actions: [ConversationAction] = []
        let original = reader.onAction
        reader.onAction = { actions.append($0) }
        defer { reader.onAction = original }
        let menu = try XCTUnwrap(reader.makePersonMenu(for: HeaderAddress(field: .to, index: 1), of: received))
        for title in ["Copy Name and Address", "New Message", "Show Mail from This Person"] {
            let item = try XCTUnwrap(menu.items.first { $0.title == title })
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        }
        XCTAssertEqual(pasteboard.string(forType: .string), "Priya Raman <priya@contoso.test>")
        guard actions.count == 2, case let .newMessage(to, account) = actions[0], case let .showMail(from) = actions[1] else {
            return XCTFail("New Message and Show Mail from This Person go to the window: \(actions)")
        }
        XCTAssertEqual(to, priya)
        XCTAssertEqual(account, ListTestSupport.accountA.id, "from the conversation's account")
        XCTAssertEqual(from, "priya@contoso.test")
    }

    /// Show Mail from This Person: the search field takes `from:` the address, runs it as if typed, and the list takes the
    /// keyboard with the query kept.
    func testShowMailFromThisPersonSearchesAndGivesTheListTheKeyboard() throws {
        let controller = harness.controller
        controller.handle(.showMail(from: "ben@contoso.test"))
        XCTAssertEqual(controller.listPane.searchText, "from:ben@contoso.test")
        XCTAssertEqual(harness.list.query.search?.text, "from:ben@contoso.test", "run as if typed, without waiting for the debounce")
        XCTAssertTrue(controller.window?.firstResponder is NSTableView, "the list takes the keyboard")
        controller.handle(.showMail(from: "odd name@contoso.test"))
        XCTAssertEqual(controller.listPane.searchText, "from:\"odd name@contoso.test\"", "quoted only when it holds a space")
    }

    /// From a reader window, the person menu's Show Mail from This Person brings the main window forward with the search.
    func testShowMailFromAReaderWindowComesToTheMainWindow() throws {
        let controller = harness.controller
        var brought: [NSWindowController] = []
        controller.bringForward = { brought.append($0) }
        controller.openSelectionInNewWindow(nil)
        let window = try XCTUnwrap(controller.readerWindows.first { $0.conversationID == conversation })
        brought = []
        let reader = window.conversation
        let rendered = conversation
        XCTAssertTrue(ListTestSupport.spin(until: { reader.pool.current?.renderedID == rendered && reader.pool.current?.isReady == true },
                                           timeout: 10))
        let menu = try XCTUnwrap(reader.makePersonMenu(for: .sender, of: received))
        let item = try XCTUnwrap(menu.items.first { $0.title == "Show Mail from This Person" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertTrue(brought.contains { $0 === controller }, "the main window comes forward")
        XCTAssertEqual(controller.listPane.searchText, "from:ben@contoso.test")
        window.close()
    }

    // MARK: Keys

    /// With focus in the open list Esc folds it first (§6.1 row 10), the next returns to the list; ↩ and ← are the page's
    /// there, as Space is.
    func testEscFoldsTheListBeforeTheReaderLetsGo() throws {
        let controller = harness.controller
        let slot = try XCTUnwrap(harness.reader.pool.current)
        let webView = slot.webView
        XCTAssertTrue(controller.window?.makeFirstResponder(webView) ?? false)
        _ = evaluate(openList(of: received) + "card.querySelector('.ss-rp').focus(); true", in: webView)
        XCTAssertTrue(ListTestSupport.spin(until: { slot.addressesFocused }, timeout: 5))
        XCTAssertTrue(harness.reader.isMarkFocused, "↩ and Space are the page's on a recipient")
        XCTAssertFalse(controller.perform(.open), "↩ copies in the page instead of opening")
        XCTAssertFalse(controller.perform(.back), "← moves along the recipients in the page")
        XCTAssertFalse(harness.reader.openQuickLookForSelectedMessage(), "Space is no Quick Look there")

        XCTAssertTrue(controller.perform(.clearSearch))
        XCTAssertTrue(ListTestSupport.spin(until: {
            (self.evaluate("[!!document.querySelector('.ss-rcx'), document.activeElement.classList.contains('ss-rc')].join()", in: webView)
                as? String) == "false,true"
        }, timeout: 5), "the first Esc folds the list onto its toggle")
        XCTAssertTrue(controller.isReaderFocused, "and the reader keeps the keyboard")
        XCTAssertTrue(ListTestSupport.spin(until: { !slot.addressesFocused && slot.markFocused }, timeout: 5),
                      "the toggle takes ↩ and Space")
        XCTAssertTrue(controller.perform(.clearSearch))
        XCTAssertFalse(controller.isReaderFocused, "the next returns to the list")
    }

    // MARK: Privacy

    /// No address reaches the log at info or above along any path: a copy, a copy that names nothing, the person menu,
    /// More › Copy Sender Address and Show Mail from This Person.
    func testNoAddressReachesTheLogAboveDebug() throws {
        let start = Date()
        let reader = harness.reader
        reader.copyAddress(HeaderAddress(field: .to, index: 1), of: received, form: .address)
        reader.copyAddress(HeaderAddress(field: .to, index: 1), of: received, form: .nameAndAddress)
        reader.copyAddress(HeaderAddress(field: .to, index: 40), of: received, form: .address)
        let menu = try XCTUnwrap(reader.makePersonMenu(for: HeaderAddress(field: .cc, index: 0), of: received))
        let copy = try XCTUnwrap(menu.items.first { $0.title == "Copy Address" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(copy.action), to: copy.target, from: copy))
        reader.setTarget(received)
        let more = reader.makeMoreMenu(for: received, shellState: [:])
        let sender = try XCTUnwrap(more.items.first { $0.title == "Copy Sender Address" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(sender.action), to: sender.target, from: sender))
        harness.controller.handle(.showMail(from: "priya@contoso.test"))
        // A line the capture must find, so an empty capture never passes for a clean one.
        let sentinel = "address log check \(UUID().uuidString)"
        ConversationSignposts.log.notice("\(sentinel, privacy: .public)")
        ListTestSupport.spin(for: 0.3)

        let store = try OSLogStore(scope: .currentProcessIdentifier)
        let entries = try store.getEntries(at: store.position(date: start.addingTimeInterval(-1)),
                                           matching: NSPredicate(format: "subsystem == %@", ConversationSignposts.subsystem))
        let loud = entries.compactMap { $0 as? OSLogEntryLog }.filter { $0.level != .debug && $0.level != .undefined }
        XCTAssertTrue(loud.contains { $0.composedMessage == sentinel }, "the capture sees this process's lines")
        let leaks = loud.map(\.composedMessage).filter { $0.contains("contoso.test") }
        XCTAssertEqual(leaks, [], "no address at info or above")
    }

    // MARK: Drift

    /// The shell's own numbers are the tokens': the cap and the hit, the pitch and the face the CSS sets.
    func testTheShellsMetricsAreTheTokens() {
        let reader = Quire.Layout.Reader.self
        let script = ConversationShellAssets.js
        XCTAssertTrue(script.contains("var RECIPIENT_LINES = \(Int(reader.recipientsMaxLines));"))
        XCTAssertTrue(script.contains("var MIN_HIT = \(Int(Quire.Layout.Button.minHit));"))
        let css = ConversationShellAssets.css
        XCTAssertTrue(css.contains("height: calc(\(Int(reader.recipientPitch))px + var(--q-step-snippet, 0px)); vertical-align: top;"))
        XCTAssertTrue(css.contains(".ss-rp > .ss-face { height: calc(\(Int(reader.recipientFace))px + var(--q-step-snippet, 0px));"))
        XCTAssertTrue(css.contains(".ss-rcx { margin-top: \(Int(reader.recipientsTop))px;"))
        XCTAssertTrue(css.contains("padding: 0 0 \(Int(reader.recipientsToggleHitBelow))px; margin-bottom: -\(Int(reader.recipientsToggleHitBelow))px;"))
        XCTAssertTrue(css.contains("margin: -\(Int(reader.senderAddressHitAbove))px 0 0 2px; padding-top: \(Int(reader.senderAddressHitAbove))px;"))
        XCTAssertTrue(css.contains(".ss-unsub + .ss-addr { flex-shrink: 1000; margin-left: \(Int(reader.unsubscribeHitGap))px; }"))
        XCTAssertTrue(css.contains(".ss-namet + .ss-unsub { margin-left: \(Int(reader.unsubscribeHitGap + reader.recipientPadX))px; }"),
                      "the name's hit reaches the face's padding past its text")
        XCTAssertTrue(css.contains("display: block; padding: 0 \(Int(reader.recipientPadX))px; border-radius: var(--q-r-sm);"))
        XCTAssertEqual(reader.recipientRadius, Quire.Radius.sm)
        XCTAssertTrue(css.contains(".ss-mark > .ss-sym { width: \(Int(reader.copiedGlyph))px; height: \(Int(reader.copiedGlyph))px; }"))
        XCTAssertTrue(css.contains("display: flex; align-items: center; gap: \(Int(reader.copiedGap))px;"))
    }

    /// A pasteboard that refuses every write.
    private final class RefusingPasteboard: NSPasteboard {
        override func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool { false }
    }

    /// Script that finds `id`'s card as `card`, every message open.
    private func openCard(of id: MessageID) -> String {
        "window.ss.expandAll(); var card = document.querySelector('.ss-card[data-id=' + JSON.stringify("
            + ConversationShellAssets.jsStringLiteral(RenderPayload.messageKey(for: id)) + ") + ']'); "
    }

    /// The same, with the card's list of recipients open.
    private func openList(of id: MessageID) -> String {
        openCard(of: id) + "if (!card.querySelector('.ss-rcx')) { card.querySelector('.ss-rc').click(); } "
    }

    private func evaluate(_ script: String, in webView: WKWebView) -> Any? {
        var result: Any?
        var done = false
        webView.evaluateJavaScript(script) { value, error in
            result = error == nil ? value : nil
            done = true
        }
        ListTestSupport.spin(until: { done }, timeout: 5)
        return result
    }
}
