import AppKit
import SSCore
import SSDesign
import WebKit
import XCTest
@testable import SuperSparrowApp

/// Find in conversation (spec §5.19a) in the real main window: ⌥⌘F opens the bar over the reader with the keyboard in
/// it, typing finds across the conversation and the bar counts, ↩ and ⇧↩ step, ⌘G and ⇧⌘G step from anywhere, Esc
/// closes the bar (from the field, and from the page before Esc returns to the list), another conversation closes it,
/// and ⌘F stays the list's search. The store is a throwaway one; nothing reaches the network.
@MainActor
final class FindInConversationTests: XCTestCase {
    private var harness: MainWindowHarness!
    private let conversation = ConversationID(accountID: ListTestSupport.accountA.id, providerID: "thread-2")

    override func setUpWithError() throws {
        harness = try MainWindowHarness()
        // Thread 2 holds three messages; the middle one quotes the first.
        let bodies = [
            "<p>The Lisbon offsite is on.</p>",
            "<p>Agreed.</p><div class=\"ss-quote\"><p>The Lisbon offsite is on.</p></div>",
            "<p>Lisbon it is. Flights for lisbon are booked.</p>",
        ]
        for (part, html) in bodies.enumerated() {
            let id = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-2-\(part)")
            try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: html, text: nil, attachments: []), renderedHTML: html,
                                                              plainText: ""), for: id)
        }
    }

    override func tearDownWithError() throws {
        harness.close()
        harness = nil
    }

    private var reader: ConversationViewController { harness.reader }
    private var find: ReaderFind { harness.reader.find }

    private func show(_ id: ConversationID) {
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        XCTAssertTrue(ListTestSupport.spin(until: {
            guard let slot = self.reader.pool.current else { return false }
            return slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == id
        }, timeout: 10), "the conversation rendered")
    }

    private func item(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    private func validates(_ action: Selector) -> Bool {
        harness.controller.validateMenuItem(item(action))
    }

    /// Types into the bar's field as the keyboard would, through its field editor.
    private func type(_ text: String) throws {
        let editor = try XCTUnwrap(harness.controller.window?.firstResponder as? NSTextView, "the bar's field has the keyboard")
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
    }

    private func command(_ selector: Selector) throws {
        let editor = try XCTUnwrap(harness.controller.window?.firstResponder as? NSTextView)
        editor.doCommand(by: selector)
    }

    private func waitForCount(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(ListTestSupport.spin(until: { self.find.bar?.countText == text }, timeout: 5),
                      "the bar reads “\(text)”, not “\(find.bar?.countText ?? "nothing")”", file: file, line: line)
    }

    /// Where the search starts depends on what is scrolled past, so only the total is certain.
    private func waitForTotal(_ count: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(ListTestSupport.spin(until: { self.find.result?.count == count && self.find.bar?.countText?.hasSuffix(" of \(count)") == true },
                                           timeout: 5),
                      "the bar counts \(count), not “\(find.bar?.countText ?? "nothing")”", file: file, line: line)
    }

    private func evaluate(_ script: String) -> String {
        guard let webView = reader.pool.current?.webView else { return "" }
        var answer: String?
        webView.evaluateJavaScript("(function () { var v = (\(script)); return v === null || v === undefined ? '' : String(v); })()") { value, _ in
            answer = value as? String ?? ""
        }
        ListTestSupport.spin(until: { answer != nil }, timeout: 5)
        return answer ?? ""
    }

    // MARK: Opening, finding, stepping

    func testTheMenuOpensTheBarAndTypingFindsAcrossTheConversation() throws {
        XCTAssertFalse(validates(#selector(MainWindowController.findInConversation(_:))), "nothing is shown")
        show(conversation)
        XCTAssertTrue(validates(#selector(MainWindowController.findInConversation(_:))))
        XCTAssertFalse(validates(#selector(MainWindowController.findNextMatch(_:))), "nothing to find again yet")

        harness.controller.findInConversation(nil)
        let bar = try XCTUnwrap(find.bar)
        XCTAssertTrue(bar.isDescendant(of: reader.view))
        XCTAssertTrue(bar.isEditing, "the field has the keyboard")
        XCTAssertNil(bar.countText, "nothing typed, nothing counted")
        XCTAssertFalse(bar.nextButton.isEnabled)

        try type("lisbon")
        waitForCount("1 of 4")
        XCTAssertTrue(bar.nextButton.isEnabled)
        XCTAssertEqual(bar.announcement, "Match 1 of 4")
        XCTAssertTrue(validates(#selector(MainWindowController.findNextMatch(_:))))
        XCTAssertEqual(evaluate("window.ss.findState().count"), "4", "the quoted copy counts too")

        try command(#selector(NSResponder.insertNewline(_:)))
        waitForCount("2 of 4")
        harness.controller.findNextMatch(nil)
        waitForCount("3 of 4")
        harness.controller.findPreviousMatch(nil)
        waitForCount("2 of 4")
        harness.controller.findPreviousMatch(nil)
        harness.controller.findPreviousMatch(nil)
        waitForCount("4 of 4")

        // From the last match nothing follows, so a new search goes round to the first.
        try type("lisbon offsite")
        waitForCount("1 of 2")
        harness.controller.findNextMatch(nil)
        waitForCount("2 of 2")
        XCTAssertEqual(evaluate("window.ss.findState().current.quoted"), "true", "the quote holding the current match")
        try type("turbine")
        waitForCount("No matches")
        XCTAssertFalse(bar.nextButton.isEnabled)
        XCTAssertFalse(bar.previousButton.isEnabled)
        try type("  ")
        XCTAssertTrue(ListTestSupport.spin(until: { bar.countText == nil }, timeout: 5), "white space alone finds nothing")
        try type("LISBON")
        waitForTotal(4)
    }

    func testEscInTheFieldClosesTheBarAndTheMarksGo() throws {
        show(conversation)
        harness.controller.findInConversation(nil)
        try type("lisbon")
        waitForCount("1 of 4")
        try command(#selector(NSResponder.cancelOperation(_:)))
        XCTAssertFalse(find.isOpen)
        XCTAssertTrue(harness.controller.window?.firstResponder is WKWebView, "the page has the keyboard again")
        XCTAssertTrue(ListTestSupport.spin(until: { self.evaluate("window.ss.findState().marks") == "0" }, timeout: 5))
        XCTAssertEqual(evaluate("window.ss.findState().query"), "")
        // ⌥⌘F again: the query is kept, selected, and found again.
        harness.controller.findInConversation(nil)
        XCTAssertEqual(find.bar?.query, "lisbon")
        waitForTotal(4)
    }

    func testEscFromThePageClosesTheBarBeforeReturningToTheList() throws {
        show(conversation)
        harness.controller.findInConversation(nil)
        try type("lisbon")
        waitForCount("1 of 4")
        let webView = try XCTUnwrap(reader.pool.current?.webView)
        harness.controller.window?.makeFirstResponder(webView)
        XCTAssertTrue(harness.controller.isReaderFocused)
        XCTAssertTrue(harness.controller.perform(.clearSearch), "Esc")
        XCTAssertFalse(find.isOpen, "the first Esc closes the bar")
        XCTAssertTrue(harness.controller.isReaderFocused, "and the reader keeps the keyboard")
        XCTAssertTrue(harness.controller.perform(.clearSearch))
        XCTAssertFalse(harness.controller.isReaderFocused, "the second returns to the list")
    }

    func testAnotherConversationClosesTheBarAndFindNextFindsTheQueryAgain() throws {
        show(conversation)
        harness.controller.findInConversation(nil)
        try type("lisbon")
        waitForCount("1 of 4")
        let other = ConversationID(accountID: ListTestSupport.accountB.id, providerID: "thread-1")
        show(other)
        XCTAssertFalse(find.isOpen, "the bar belongs to the conversation it searched")
        XCTAssertTrue(validates(#selector(MainWindowController.findNextMatch(_:))), "⌘G has the kept query")
        show(conversation)
        harness.controller.findNextMatch(nil)
        let bar = try XCTUnwrap(find.bar, "⌘G opens the bar with the kept query")
        XCTAssertEqual(bar.query, "lisbon")
        waitForTotal(4)
        // Several selected: nothing to search, so the bar goes.
        harness.selectFirst(2)
        XCTAssertTrue(ListTestSupport.spin(until: { !self.find.isOpen }, timeout: 5))
        XCTAssertFalse(validates(#selector(MainWindowController.findInConversation(_:))))
    }

    func testAStoreChangeUpdatesTheCount() throws {
        show(conversation)
        harness.controller.findInConversation(nil)
        try type("booked")
        waitForCount("1 of 1")
        // A reply arrives in the open conversation.
        let reply = MessageMetadata(
            id: MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-2-new"), conversationID: conversation,
            subject: "Project update 2", snippet: "Booked too", from: EmailAddress(name: "Ada Lovelace", address: "ada@example.com"),
            to: [EmailAddress(address: ListTestSupport.accountA.email)], date: Date(), roles: [.inbox], isRead: false, isStarred: false,
            hasAttachments: false)
        let html = "<p>Hotel booked as well.</p>"
        try harness.environment.store.upsertMessages([reply])
        try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: html, text: nil, attachments: []), renderedHTML: html,
                                                          plainText: ""), for: reply.id)
        waitForCount("1 of 2")
    }

    // MARK: Keys and menus

    func testTheKeysAreTheEditMenusAndCommandFStaysSearch() throws {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        func action(_ characters: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16) throws -> Selector? {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                                       context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                       isARepeat: false, keyCode: keyCode))
            return MainMenuBar.exactItem(for: event, in: bar)?.action
        }
        XCTAssertEqual(try action("f", [.command, .option], keyCode: 3), #selector(MainWindowController.findInConversation(_:)))
        XCTAssertEqual(try action("f", .command, keyCode: 3), #selector(MainWindowController.focusSearchField(_:)), "⌘F is still search")
        XCTAssertEqual(try action("g", .command, keyCode: 5), #selector(MainWindowController.findNextMatch(_:)))
        XCTAssertEqual(try action("G", [.command, .shift], keyCode: 5), #selector(MainWindowController.findPreviousMatch(_:)))
        let edit = try XCTUnwrap(bar.items.first { $0.title == "Edit" }?.submenu)
        let titles = edit.items.map(\.title)
        XCTAssertEqual(Array(titles.drop { $0 != "Find…" }.prefix(4)), ["Find…", "Find in Conversation…", "Find Next", "Find Previous"])

        show(conversation)
        harness.controller.focusSearchField(nil)
        XCTAssertFalse(find.isOpen, "⌘F never opens the find bar")
    }

    func testReturnAndShiftReturnInTheFieldStepBothWays() throws {
        show(conversation)
        let window = try XCTUnwrap(harness.controller.window)
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        harness.controller.findInConversation(nil)
        try type("lisbon")
        waitForCount("1 of 4")
        for (flags, expected) in [(NSEvent.ModifierFlags(), "2 of 4"), ([.shift], "1 of 4"), ([.shift], "4 of 4")] {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = try XCTUnwrap(NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
                    isARepeat: false, keyCode: 36))
                // Through the event queue, as the run loop delivers a key, so the app's current event is this one.
                NSApp.postEvent(event, atStart: true)
                if let next = NSApp.nextEvent(matching: [.keyDown, .keyUp], until: Date(timeIntervalSinceNow: 1), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(next)
                }
            }
            waitForCount(expected)
        }
    }

    // MARK: The bar

    func testTheBarHangsUnderTheHeaderAtTheTrailingEdge() throws {
        show(conversation)
        harness.controller.findInConversation(nil)
        let bar = try XCTUnwrap(find.bar)
        reader.view.layoutSubtreeIfNeeded()
        let f = Quire.Layout.FindBar.self
        let frame = bar.convert(bar.bounds, to: reader.view)
        let header = reader.header.convert(reader.header.bounds, to: reader.view)
        XCTAssertEqual(frame.size, NSSize(width: f.width, height: f.height))
        XCTAssertEqual(reader.view.bounds.maxX - frame.maxX, f.trailing, accuracy: 0.5)
        // The reader's view is not flipped: under the header means below its bottom edge.
        XCTAssertEqual(header.minY - frame.maxY, f.top, accuracy: 0.5)
        let webView = try XCTUnwrap(reader.pool.current?.webView)
        let before = webView.frame
        harness.controller.findInConversation(nil)
        XCTAssertEqual(webView.frame, before, "the bar floats over the page; the web view's frame never changes")
    }
}
