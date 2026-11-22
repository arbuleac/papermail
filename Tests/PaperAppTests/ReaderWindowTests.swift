import AppKit
import PaperCore
import PaperDesign
import XCTest
@testable import PaperApp

/// A conversation in its own window (spec §5.49) through the app harness: ↩, a double-click and ⌘O, the window's chrome
/// and web view, its keys and menus acting on its conversation, Esc closing it while its quick reply holds nothing, steps
/// that close it with their toast in the main window and an undo that opens it again, steps that keep it with their toast
/// in it, one undo history across windows, and its quick reply's text, countdown and sends outliving it. Drafts go to a
/// temporary folder.
@MainActor
final class ReaderWindowTests: XCTestCase {
    private static let sizeKey = "ReaderWindowSize"
    private var folder: URL!
    private var savedUndoWindow: TimeInterval = 5

    override func setUp() {
        super.setUp()
        // A size an earlier test left would stand in for the default.
        UserDefaults.standard.removeObject(forKey: Self.sizeKey)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperReaderWindow-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated {
            ComposeDraftStore.shared.useDirectory(folder)
            savedUndoWindow = ConversationViewController.undoWindow
        }
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.sizeKey)
        MainActor.assumeIsolated {
            ConversationViewController.undoWindow = savedUndoWindow
            KeyboardRouter.keyWindowForTests = nil
            for panel in ComposeWindowRegistry.shared.livePanels { panel.orderOut(nil); ComposeWindowRegistry.shared.unregister(panel) }
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Helpers

    private func inInbox(_ id: ConversationID, _ harness: MainWindowHarness) throws -> Bool {
        try harness.environment.store.messages(in: id).contains(where: \.isInInbox)
    }

    private func select(_ index: Int, _ harness: MainWindowHarness) {
        let id = harness.list.conversations[index].id
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
    }

    /// Opens the conversation at `index` with ⌘O, as File › Open in New Window does.
    private func open(_ index: Int, _ harness: MainWindowHarness, file: StaticString = #filePath,
                      line: UInt = #line) throws -> (ConversationID, ReaderWindowController) {
        select(index, harness)
        let id = harness.list.conversations[index].id
        harness.controller.openSelectionInNewWindow(nil)
        let reader = try XCTUnwrap(harness.controller.readerWindows.first { $0.conversationID == id }, file: file, line: line)
        return (id, reader)
    }

    private func openItem() -> NSMenuItem {
        NSMenuItem(title: "Open in New Window", action: #selector(MainWindowController.openSelectionInNewWindow(_:)), keyEquivalent: "o")
    }

    private func message(in reader: ReaderWindowController) -> String? {
        reader.toastView.slip?.message
    }

    private func menuItem(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    /// Moves the conversation at `index` to the Trash from the main window and opens it from the Trash view.
    private func openFromTrash(_ index: Int, _ harness: MainWindowHarness) throws -> (ConversationID, ReaderWindowController) {
        select(index, harness)
        let id = harness.list.conversations[index].id
        XCTAssertTrue(harness.controller.perform(.trash))
        _ = harness.controller.perform(.goTo(.trash))
        harness.spin { harness.list.conversations.contains { $0.id == id } }
        let row = try XCTUnwrap(harness.list.conversations.firstIndex { $0.id == id })
        return try open(row, harness)
    }

    /// A key as `window` delivers it: through the app, whose local monitors (each window's router) see it first. A test's
    /// window is seldom key, and the routers act only in the key window, so they are told which one is (`key`). `repeated`
    /// is the key's repeat while it is held down.
    private func press(_ characters: String, keyCode: UInt16, in window: NSWindow, key: NSWindow? = nil, repeated: Bool = false) throws {
        KeyboardRouter.keyWindowForTests = key ?? window
        defer { KeyboardRouter.keyWindowForTests = nil }
        NSApp.sendEvent(try keyEvent(characters, keyCode: keyCode, in: window, repeated: repeated))
    }

    private func keyEvent(_ characters: String, keyCode: UInt16, in window: NSWindow, repeated: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: characters,
                                       charactersIgnoringModifiers: characters, isARepeat: repeated, keyCode: keyCode))
    }

    private func pendingSend(_ harness: MainWindowHarness) throws -> PendingSend? {
        try harness.environment.store.pendingSends().first
    }

    // MARK: Opening

    func testCommandOOpensTheSelectedConversationInAWindowOfItsOwn() throws {
        let harness = try MainWindowHarness()
        select(0, harness)
        XCTAssertTrue(harness.controller.validateMenuItem(openItem()))
        let (id, reader) = try open(0, harness)
        let window = try XCTUnwrap(reader.window)
        XCTAssertTrue(window is ReaderWindow)
        XCTAssertTrue(reader.place.window === reader)
        XCTAssertEqual(reader.conversation.selection, .one(id), "the reader stands without the split")
        XCTAssertEqual(window.title, "Project update 0 and the quarterly planning document", "the subject names the window")
        // The main window's chrome, so the header's first row sits on the lights' centre line.
        XCTAssertNotNil(window.toolbar)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.contentMinSize, NSSize(width: 520, height: 420))
        XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.size, NSSize(width: 840, height: 800))
        XCTAssertEqual(window.tabbingMode, .disallowed)
        let metrics = QuireWindowChrome.metrics(of: window)
        XCTAssertEqual(metrics.lightsCenterY, Quire.Layout.ReaderHeader.kickerCenterY, accuracy: Quire.Layout.TrafficLights.tolerance)
        let header = reader.conversation.header
        header.layoutSubtreeIfNeeded()
        let kicker = try XCTUnwrap(header.subviews.first { $0 is ReaderKickerView })
        XCTAssertGreaterThanOrEqual(kicker.frame.minX, metrics.lightsEnd + Quire.Layout.Rail.lightsClearance, "the kicker clears the lights")
        XCTAssertEqual(kicker.frame.minX, max(metrics.mastheadMinimalX, ReaderColumn.frame(readerWidth: header.bounds.width).x))
        // One web view of its own, outside the main window's pool: one more WebContent process.
        XCTAssertEqual(reader.conversation.pool.slots.count, 1)
        XCTAssertFalse(reader.conversation.pool.configuration === harness.reader.pool.configuration)
        XCTAssertFalse(reader.conversation.pool.configuration.userContentController === harness.reader.pool.configuration.userContentController,
                       "its page's messages come to its own pool")
        // On the app's one WebKit process pool, which reads the installed fonts for its processes once; a pool of its own
        // read them all again in every ⌘O. Read by key: the property is deprecated, and the build treats that as an error.
        let readerProcessPool = try XCTUnwrap(reader.conversation.pool.configuration.value(forKey: "processPool") as? NSObject)
        let mainProcessPool = try XCTUnwrap(harness.reader.pool.configuration.value(forKey: "processPool") as? NSObject)
        XCTAssertTrue(readerProcessPool === mainProcessPool, "one process pool for every reader")
        XCTAssertNotNil(window.initialFirstResponder)
        XCTAssertTrue(window.initialFirstResponder === reader.conversation.pool.slots[0].webView,
                      "the page, not the quick reply's field, takes the keyboard, so single keys act")
        XCTAssertTrue(harness.controller.undoCenter.readers().contains { $0 === reader.conversation },
                      "its quick reply's countdown is one ⌘Z can reach")
        XCTAssertEqual(harness.list.selectedConversationID, id, "the selection stays")
        harness.close()
        XCTAssertNil(reader.place.window, "the mailbox's windows go with it")
    }

    func testOpeningAConversationAlreadyOpenBringsItsWindowForward() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try open(0, harness)
        harness.controller.openSelectionInNewWindow(nil)
        XCTAssertEqual(harness.controller.readerWindows.count, 1, "one window per conversation")
        XCTAssertTrue(harness.controller.readerWindows[0] === reader)
        let (_, second) = try open(1, harness)
        XCTAssertEqual(harness.controller.readerWindows.count, 2)
        // Each cascades from the one before it.
        let first = try XCTUnwrap(reader.window).frame
        let next = try XCTUnwrap(second.window).frame
        XCTAssertGreaterThan(next.minX, first.minX)
        XCTAssertLessThan(next.maxY, first.maxY)
        harness.close()
    }

    /// A double-click on a row opens that row's conversation in a window of its own, ⌘ held or not (the ⌘-double-click
    /// that used to be the only way still is one), whatever the clicks did to the selection; again, it brings the same
    /// window forward.
    func testADoubleClickOpensTheClickedRowInAWindow() throws {
        let harness = try MainWindowHarness()
        var brought: [NSWindowController] = []
        harness.controller.bringForward = { brought.append($0) }
        select(0, harness)
        let selected = harness.list.conversations[0].id
        let clicked = harness.list.conversations[2].id
        let row = try XCTUnwrap(harness.list.layout.row(ofConversation: 2))
        harness.list.rowDoubleClicked(row)
        XCTAssertEqual(harness.controller.readerWindows.map(\.conversationID), [clicked])
        let reader = try XCTUnwrap(harness.controller.readerWindows.first)
        XCTAssertTrue(brought.last === reader, "the window comes forward")
        XCTAssertEqual(harness.list.selectedConversationID, selected, "opening the window selects nothing itself")
        XCTAssertEqual(harness.reader.currentConversationID, selected, "and the main window's reader stays where it was")
        brought = []
        harness.list.rowDoubleClicked(row)
        XCTAssertEqual(harness.controller.readerWindows.count, 1, "one window per conversation")
        XCTAssertTrue(brought.last === reader, "the open one comes forward again")
        harness.close()
    }

    /// ↩ on the list opens the selected conversation in a window of its own, as ⌘O does, through the main window's router
    /// as the app delivers the key; ↩ (here keypad Enter) again, with the main window key once more, brings that window
    /// forward rather than opening a second.
    func testReturnOnTheListOpensTheSelectedConversationInAWindow() throws {
        let harness = try MainWindowHarness()
        var brought: [NSWindowController] = []
        harness.controller.bringForward = { brought.append($0) }
        select(1, harness)
        let id = harness.list.conversations[1].id
        let mainWindow = try XCTUnwrap(harness.controller.window)
        XCTAssertTrue(mainWindow.makeFirstResponder(harness.list.tableView))
        XCTAssertFalse(harness.controller.isReaderFocused)
        try press("\r", keyCode: 36, in: mainWindow)
        XCTAssertEqual(harness.controller.readerWindows.map(\.conversationID), [id])
        let reader = try XCTUnwrap(harness.controller.readerWindows.first)
        XCTAssertTrue(brought.last === reader, "the window comes forward")
        XCTAssertEqual(harness.list.selectedConversationID, id, "the selection stays")
        brought = []
        try press("\u{3}", keyCode: 76, in: mainWindow)
        XCTAssertEqual(harness.controller.readerWindows.count, 1, "one window per conversation")
        XCTAssertTrue(brought.last === reader, "the open one comes forward again")
        harness.close()
    }

    /// ↩ opens a window only from the list (§5.49): with Full Keyboard Access on a button outside the reader that does not
    /// claim the key (here compose), or with nothing focused, ↩ goes on to the control or the window, and the selected
    /// conversation stays where it is; back on the list's table, ↩ opens it.
    func testReturnOpensAWindowOnlyFromTheList() throws {
        let harness = try MainWindowHarness()
        select(1, harness)
        let id = harness.list.conversations[1].id
        let mainWindow = try XCTUnwrap(harness.controller.window)
        let compose = harness.controller.listPane.header.compose
        XCTAssertTrue(mainWindow.makeFirstResponder(compose))
        XCTAssertFalse(harness.controller.isListFocused)
        XCTAssertFalse(harness.controller.isReaderFocused)
        try press("\r", keyCode: 36, in: mainWindow)
        try press("\u{3}", keyCode: 76, in: mainWindow)
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "↩ on compose opens no window")
        XCTAssertTrue(mainWindow.makeFirstResponder(nil))
        try press("\r", keyCode: 36, in: mainWindow)
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "nor with nothing focused")

        XCTAssertTrue(mainWindow.makeFirstResponder(harness.list.tableView))
        XCTAssertTrue(harness.controller.isListFocused)
        try press("\r", keyCode: 36, in: mainWindow)
        XCTAssertEqual(harness.controller.readerWindows.map(\.conversationID), [id], "the list's ↩ opens it")
        harness.close()
    }

    /// → keeps the conversation in the main window: its reader shows it and takes the keyboard, and no window opens (§6).
    /// ↩ with the reader focused then opens nothing new either: it stays the page's Open (§5.15).
    func testRightOpensInTheMainWindowsReaderAndOpensNoWindow() throws {
        let harness = try MainWindowHarness()
        select(2, harness)
        let id = harness.list.conversations[2].id
        harness.spin { harness.reader.pool.current?.renderedID == id }
        let mainWindow = try XCTUnwrap(harness.controller.window)
        XCTAssertTrue(mainWindow.makeFirstResponder(harness.list.tableView))
        try press("\u{F703}", keyCode: 124, in: mainWindow)
        XCTAssertTrue(harness.controller.isReaderFocused, "the reader takes the keyboard")
        XCTAssertEqual(harness.reader.currentConversationID, id)
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "no window opens")
        try press("\r", keyCode: 36, in: mainWindow)
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "↩ in the reader opens no window")
        XCTAssertTrue(harness.controller.isReaderFocused)
        harness.close()
    }

    /// Nothing opens with several selected (↩ is spent, ⌘O disabled), with nothing selected, from a row that is not a
    /// conversation's, or in Drafts by ⌘O (↩ and a double-click continue editing there, `DraftsViewTests`).
    func testNothingOpensWithSeveralSelectedNothingSelectedOrInDrafts() throws {
        let harness = try MainWindowHarness()
        XCTAssertFalse(harness.controller.validateMenuItem(openItem()), "nothing selected")
        XCTAssertFalse(harness.controller.perform(.openInWindow), "↩ with nothing selected goes on")
        harness.selectFirst(2)
        XCTAssertFalse(harness.controller.validateMenuItem(openItem()), "a window holds one conversation")
        harness.controller.openSelectionInNewWindow(nil)
        XCTAssertTrue(harness.controller.perform(.openInWindow), "↩ with several selected is spent")
        XCTAssertTrue(harness.controller.readerWindows.isEmpty)
        // A running head (the list opens on “Today”) has no conversation to open.
        let table = harness.list.tableView
        let head = try XCTUnwrap((0..<table.numberOfRows).first { harness.list.layout.conversationIndex(atRow: $0) == nil })
        harness.list.rowDoubleClicked(head)
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "a double-click on a head opens nothing")
        _ = harness.controller.perform(.goTo(.drafts))
        XCTAssertFalse(harness.controller.validateMenuItem(openItem()), "a draft opens in its composer")
        harness.close()
    }

    // MARK: Steps that close the window

    func testArchiveClosesTheWindowAndItsUndoOpensItAgainWhereItWas() throws {
        let harness = try MainWindowHarness()
        let (id, reader) = try open(0, harness)
        let window = try XCTUnwrap(reader.window)
        let frame = NSRect(x: -19_000, y: -19_000, width: 700, height: 600)
        window.setFrame(frame, display: false)
        XCTAssertTrue(reader.perform(.archive))
        XCTAssertFalse(try inInbox(id, harness))
        XCTAssertNil(reader.place.window, "the conversation left the desk, and the window with it")
        XCTAssertTrue(harness.controller.readerWindows.isEmpty)
        XCTAssertTrue(harness.toasts.isVisible(in: harness.controller.listPane.toastView), "the toast shows in the main window")
        XCTAssertEqual(harness.toastMessage, "Archived")
        // Z in the main window: the conversation comes back, in its window, where it was.
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertTrue(try inInbox(id, harness))
        let reopened = try XCTUnwrap(harness.controller.readerWindows.first)
        XCTAssertEqual(reopened.conversationID, id)
        XCTAssertEqual(reopened.window?.frame, frame)
        XCTAssertEqual(message(in: reopened), "Undid Archive", "undone where it was taken")
        XCTAssertFalse(harness.toasts.isVisible(in: harness.controller.listPane.toastView))
        harness.close()
    }

    func testOnlyAStepThatChangesSomethingClosesTheWindow() throws {
        let harness = try MainWindowHarness()
        let (id, reader) = try open(0, harness)
        // Already archived elsewhere: E changes nothing, beeps, and the window stays.
        let targets = try harness.environment.store.messages(in: id).map(\.id)
        try harness.environment.engine.perform(.archive, on: targets)
        XCTAssertTrue(reader.perform(.archive))
        XCTAssertTrue(reader.place.window === reader)
        XCTAssertEqual(harness.controller.readerWindows.count, 1)
        // # still takes it to the Trash, and the window goes.
        XCTAssertTrue(reader.perform(.trash))
        XCTAssertTrue(try harness.environment.store.messages(in: id).allSatisfy { $0.roles.contains(.trash) })
        XCTAssertTrue(harness.controller.readerWindows.isEmpty)
        XCTAssertEqual(harness.toastMessage, "Moved to Trash")
        harness.close()
    }

    func testLaterFromTheWindowSnoozesItAndItsUndoOpensItAgain() throws {
        let harness = try MainWindowHarness()
        var popped: NSMenu?
        harness.controller.popUpLaterMenu = { menu, _, _ in popped = menu }
        let (id, reader) = try open(1, harness)
        XCTAssertTrue(reader.perform(.later))
        let menu = try XCTUnwrap(popped, "L pops the Later menu from the window's header")
        menu.update()
        let item = try XCTUnwrap(menu.items.first { $0.action == #selector(ReaderWindowController.snoozeSelectionUntil(_:)) })
        XCTAssertTrue(item.target === reader)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertEqual(try harness.environment.store.snoozes().map(\.conversationID), [id])
        XCTAssertTrue(harness.controller.readerWindows.isEmpty)
        XCTAssertTrue(harness.toastMessage?.hasPrefix("Snoozed until") == true || harness.toastMessage?.hasPrefix("Until") == true)
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertTrue(try harness.environment.store.snoozes().isEmpty)
        XCTAssertTrue(try inInbox(id, harness))
        XCTAssertEqual(harness.controller.readerWindows.map(\.conversationID), [id])
        harness.close()
    }

    /// ! in a window takes the conversation out of every view, as # takes it to the Trash: the window closes with its toast
    /// in the main window, and Z opens it again where it was (spec, Reader window (Q3.5), Mark as spam (Q2.3)).
    func testMarkAsSpamClosesTheWindowAndItsUndoOpensItAgain() throws {
        let harness = try MainWindowHarness()
        let (id, reader) = try open(0, harness)
        let subject = try XCTUnwrap(reader.window?.title)
        XCTAssertNotEqual(subject, "No subject")
        XCTAssertTrue(reader.validateMenuItem(menuItem(#selector(ReaderWindowController.markSelectionSpam(_:)))))
        XCTAssertTrue(reader.perform(.markSpam))
        XCTAssertTrue(try harness.environment.store.messages(in: id).contains { $0.roles.contains(.spam) })
        XCTAssertFalse(try inInbox(id, harness))
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "the conversation left the desk, and the window with it")
        XCTAssertEqual(harness.toastMessage, "Marked as spam")
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertTrue(try inInbox(id, harness))
        XCTAssertEqual(harness.controller.readerWindows.map(\.conversationID), [id])
        // Opened before the mail was out of Spam, the window was named "No subject" for good.
        let reopened = try XCTUnwrap(harness.controller.readerWindows.first)
        XCTAssertEqual(reopened.window?.title, subject, "named by its subject")
        XCTAssertFalse(reopened.conversation.currentMessages.isEmpty, "showing its mail")
        XCTAssertEqual(message(in: reopened), "Undid Mark as Spam", "undone where it was taken")
        harness.close()
    }

    /// Opened from the Trash, ! does nothing but beep, as in the main window.
    func testMarkAsSpamIsRefusedInATrashWindow() throws {
        let harness = try MainWindowHarness()
        let (id, reader) = try openFromTrash(0, harness)
        XCTAssertFalse(reader.validateMenuItem(menuItem(#selector(ReaderWindowController.markSelectionSpam(_:)))))
        XCTAssertTrue(reader.perform(.markSpam))
        XCTAssertFalse(try harness.environment.store.messages(in: id).contains { $0.roles.contains(.spam) })
        XCTAssertTrue(reader.place.window === reader)
        harness.close()
    }

    /// M in a window opened from the Inbox mutes the conversation and archives it as E would, so the window closes; the
    /// undo unmutes it and opens the window again (spec, Mute (Q3.7)).
    func testMuteFromAnInboxWindowClosesItAndItsUndoOpensItAgain() throws {
        let harness = try MainWindowHarness()
        let (id, reader) = try open(0, harness)
        let item = menuItem(#selector(ReaderWindowController.toggleMuteSelection(_:)))
        XCTAssertTrue(reader.validateMenuItem(item))
        XCTAssertEqual(item.title, "Mute")
        XCTAssertTrue(reader.perform(.toggleMute))
        XCTAssertTrue(try harness.environment.store.isMuted(id))
        XCTAssertFalse(try inInbox(id, harness))
        XCTAssertTrue(harness.controller.readerWindows.isEmpty)
        XCTAssertEqual(harness.toastMessage, "Muted")
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertFalse(try harness.environment.store.isMuted(id))
        XCTAssertTrue(try inInbox(id, harness))
        let reopened = try XCTUnwrap(harness.controller.readerWindows.first)
        XCTAssertEqual(message(in: reopened), "Undid Mute")
        harness.close()
    }

    /// A sender rule set from a window's menu is that window's step: its toast shows there and the window stays, since the
    /// rule is about the sender, not the conversation (spec, Sender rules (Q4.2)).
    func testASenderRuleFromTheWindowToastsInIt() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try open(0, harness)
        let target = try XCTUnwrap(reader.conversation.senderRuleTarget, "mail from someone else")
        let address = SenderRule.normalizedAddress(try XCTUnwrap(target.from?.address))
        let block = menuItem(#selector(ReaderWindowController.blockSender(_:)))
        XCTAssertTrue(reader.validateMenuItem(block))
        reader.blockSender(nil)
        // Set once the account's grant answers (no request); the harness's made-up servers grant it.
        harness.spin { (try? harness.environment.store.senderRules().isEmpty) == false }
        XCTAssertEqual(try harness.environment.store.senderRules().map(\.address), [address])
        XCTAssertTrue(reader.place.window === reader)
        let kind = try XCTUnwrap(harness.controller.accountsByID[target.id.accountID]).kind
        XCTAssertEqual(message(in: reader), SenderRuleCopy.toast(.trash, address: address, kind: kind))
        XCTAssertFalse(reader.validateMenuItem(block), "the rule the sender has is checked and has nothing to do")
        XCTAssertEqual(block.state, .on)
        XCTAssertTrue(reader.perform(.undo))
        XCTAssertTrue(try harness.environment.store.senderRules().isEmpty)
        harness.close()
    }

    /// On an account that has not let Paper save rules on the server, the rule's alert asks on the window the rule
    /// was chosen in, and once Continue's sign-in has granted the permission the rule is that window's step, its toast there.
    func testTheRulesAlertAsksOnTheWindowAndTheRuleIsItsStep() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try open(0, harness)
        let target = try XCTUnwrap(reader.conversation.senderRuleTarget, "mail from someone else")
        let account = try XCTUnwrap(harness.controller.accountsByID[target.id.accountID])
        var granted = false
        harness.controller.hasRulesPermission = { _ in granted }
        var askedOn: NSWindow?
        var connected: [AccountID] = []
        harness.controller.onConnectRules = { account, done in
            connected.append(account.id)
            granted = true
            done(true)
        }
        harness.controller.presentAlert = { _, window, done in
            askedOn = window
            done(0)
        }
        reader.blockSender(nil)
        harness.spin { (try? harness.environment.store.senderRules().isEmpty) == false }
        XCTAssertTrue(askedOn === reader.window, "asked where it was chosen")
        XCTAssertEqual(connected, [account.id])
        XCTAssertEqual(try harness.environment.store.senderRules().map(\.sync), [.creating])
        let address = SenderRule.normalizedAddress(try XCTUnwrap(target.from?.address))
        XCTAssertEqual(message(in: reader), SenderRuleCopy.toast(.trash, address: address, kind: account.kind), "the window's step")
        XCTAssertTrue(reader.perform(.undo))
        XCTAssertTrue(try harness.environment.store.senderRules().isEmpty)
        harness.close()
    }

    /// A Send Later scheduled from a window's quick reply toasts in that window, and its undo confirms there.
    func testSendLaterFromTheWindowsQuickReplyToastsInIt() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try open(0, harness)
        let account = try XCTUnwrap(harness.controller.accounts.first)
        let message = OutgoingMessage(accountID: account.id, to: [EmailAddress(address: "ben@example.com")], subject: "Later",
                                      html: "<p>Hi</p>", text: "Hi")
        let date = Date().addingTimeInterval(86_400)
        let sendID = try harness.environment.engine.scheduleSend(message, at: date, draftID: nil)
        var undone = false
        SendLaterScheduled(sendID: sendID, date: date) {
            undone = true
            return true
        }.post(from: reader.conversation)
        XCTAssertTrue(self.message(in: reader)?.hasPrefix("Sends") == true, "the window's step: \(String(describing: self.message(in: reader)))")
        XCTAssertFalse(harness.toasts.isVisible(in: harness.controller.listPane.toastView))
        XCTAssertTrue(reader.perform(.undo))
        XCTAssertTrue(undone)
        harness.close()
    }

    /// A reply scheduled from a window's quick reply, the window closed with ⌘W and Z pressed in the main window within
    /// the grace: the text comes into the main window's reader showing the conversation; showing another, its strip says
    /// the reply was not sent, and the text is there when the conversation is. It was parked out of sight, and nothing on
    /// screen showed the undo.
    func testUndoingAWindowsSendLaterAfterItClosedBringsTheTextBack() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let date = Date().addingTimeInterval(86_400)
        let (id, reader) = try open(0, harness)
        harness.spin { harness.reader.currentConversationID == id }
        reader.conversation.sendQuickReplyLater("See you Tuesday", mode: .reply, at: date)
        XCTAssertEqual(try harness.environment.store.pendingSends().count, 1)
        XCTAssertTrue(message(in: reader)?.hasPrefix("Sends") == true)
        reader.close()
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertTrue(try harness.environment.store.pendingSends().isEmpty, "the schedule is taken back")
        XCTAssertEqual(harness.reader.quickReplyBar.text, "See you Tuesday", "in the main window's reader, which shows it")

        // Showing another conversation: the strip says so, and the text waits for the conversation.
        harness.reader.quickReplyBar.text = ""
        let (other, second) = try open(1, harness)
        select(2, harness)
        let third = harness.list.conversations[2].id
        harness.spin { harness.reader.currentConversationID == third }
        second.conversation.sendQuickReplyLater("For the second", mode: .reply, at: date)
        second.close()
        XCTAssertTrue(harness.controller.perform(.undo))
        guard case .notSent? = harness.reader.quickReplyBar.stripState else {
            return XCTFail("the main window's reader says it was not sent: \(String(describing: harness.reader.quickReplyBar.stripState))")
        }
        select(1, harness)
        harness.spin { harness.reader.currentConversationID == other }
        XCTAssertEqual(harness.reader.quickReplyBar.text, "For the second")
    }

    /// The reader's own commands reach a window's conversation from the menus: Download Attachments, Print, and Find in
    /// Conversation with Find Next and Find Previous.
    func testTheWindowAnswersTheReadersCommands() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try open(0, harness)
        for selector in [#selector(ReaderWindowController.downloadAttachments(_:)), #selector(ReaderWindowController.printConversation(_:)),
                         #selector(ReaderWindowController.findInConversation(_:)), #selector(ReaderWindowController.findNextMatch(_:)),
                         #selector(ReaderWindowController.findPreviousMatch(_:))] {
            XCTAssertTrue(reader.responds(to: selector), "\(selector)")
            XCTAssertEqual(reader.validateMenuItem(menuItem(selector)), reader.conversation.validateMenuItem(menuItem(selector)),
                           "validated by its reader: \(selector)")
        }
        harness.close()
    }

    /// ⌘+ and ⌘− reach a reader window: the reader's own size is the app's, so the window's reader and the main window's
    /// step together (spec §4.15), and the menu items read its limits there too.
    func testTextSizeStepsFromAWindowAndEveryReaderFollows() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try open(0, harness)
        let start = harness.settings.readerSize
        let bigger = menuItem(#selector(ReaderWindowController.makeReaderTextBigger(_:)))
        let smaller = menuItem(#selector(ReaderWindowController.makeReaderTextSmaller(_:)))
        XCTAssertEqual(reader.validateMenuItem(bigger), start.larger != nil)
        reader.makeReaderTextBigger(bigger)
        let stepped = try XCTUnwrap(start.larger)
        XCTAssertEqual(harness.settings.readerSize, stepped)
        harness.spin { reader.conversation.header.textSize == stepped && harness.reader.header.textSize == stepped }
        XCTAssertEqual(reader.conversation.header.textSize, stepped, "the window's reader")
        XCTAssertEqual(harness.reader.header.textSize, stepped, "and the main window's")
        XCTAssertTrue(reader.validateMenuItem(smaller))
        reader.makeReaderTextSmaller(smaller)
        harness.spin { reader.conversation.header.textSize == start }
        XCTAssertEqual(harness.settings.readerSize, start)
        harness.close()
    }

    // MARK: Steps that keep the window

    func testMoveToInboxKeepsTheWindowWithItsToastAndUndoInIt() throws {
        let harness = try MainWindowHarness()
        select(0, harness)
        let id = harness.list.conversations[0].id
        XCTAssertTrue(harness.controller.perform(.trash))
        _ = harness.controller.perform(.goTo(.trash))
        harness.spin { harness.list.conversations.contains { $0.id == id } }
        let index = try XCTUnwrap(harness.list.conversations.firstIndex { $0.id == id })
        let (_, reader) = try open(index, harness)
        XCTAssertEqual(reader.place.view, .trash)
        XCTAssertFalse(reader.validateMenuItem(NSMenuItem(title: "Move to Trash", action: #selector(ReaderWindowController.trashSelection(_:)),
                                                          keyEquivalent: "#")), "already in the Trash")
        XCTAssertTrue(reader.perform(.trash), "# does nothing in the Trash, quietly")
        XCTAssertTrue(reader.place.window === reader)

        XCTAssertTrue(reader.perform(.moveToInbox))
        XCTAssertTrue(try inInbox(id, harness))
        XCTAssertTrue(reader.place.window === reader, "the conversation is still on the desk")
        XCTAssertEqual(message(in: reader), "Moved to Inbox", "the toast shows where the step was taken")
        XCTAssertEqual(reader.place.view, .inbox, "its keys now treat it as an Inbox row")
        // The toast sits at the reader's bottom centre, above the quick reply.
        let content = try XCTUnwrap(reader.window?.contentView)
        content.layoutSubtreeIfNeeded()
        XCTAssertEqual(reader.toastView.frame.minY, Quire.Layout.ReaderHeader.height)
        XCTAssertEqual(reader.toastView.frame.maxY, content.bounds.height - reader.conversation.bottomOverlayHeight)

        // Z in the window undoes it there.
        XCTAssertTrue(reader.perform(.undo))
        XCTAssertFalse(try inInbox(id, harness))
        XCTAssertEqual(message(in: reader), "Undid Move to Inbox")
        XCTAssertTrue(reader.place.window === reader)
        harness.close()
    }

    func testStarAndUnreadInTheWindowHaveNoToastAndZReachesThem() throws {
        let harness = try MainWindowHarness()
        // Thread 0 is starred (every fifth is).
        let (id, reader) = try open(0, harness)
        XCTAssertTrue(reader.validateMenuItem(NSMenuItem(title: "Star", action: #selector(ReaderWindowController.toggleStarSelection(_:)),
                                                         keyEquivalent: "s")))
        XCTAssertTrue(reader.perform(.toggleStar))
        XCTAssertFalse(try harness.environment.store.messages(in: id).contains(where: \.isStarred))
        XCTAssertFalse(harness.toasts.isVisible, "the reader shows the change itself")
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Unstar")
        XCTAssertTrue(reader.perform(.undo))
        XCTAssertTrue(try harness.environment.store.messages(in: id).contains(where: \.isStarred))
        XCTAssertEqual(message(in: reader), "Undid Unstar")
        harness.close()
    }

    func testMarkAsReadInTheWindowHasNoToastAndZReachesIt() throws {
        let harness = try MainWindowHarness()
        // Thread 3 is unread (every third is).
        let (id, reader) = try open(3, harness)
        XCTAssertTrue(reader.perform(.toggleRead))
        XCTAssertTrue(try harness.environment.store.messages(in: id).allSatisfy(\.isRead))
        XCTAssertNil(message(in: reader), "the row's dot is the reader's own: no toast")
        XCTAssertFalse(harness.toasts.isVisible)
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Mark as Read")
        XCTAssertTrue(reader.perform(.undo))
        XCTAssertTrue(try harness.environment.store.messages(in: id).contains { !$0.isRead })
        XCTAssertEqual(message(in: reader), "Undid Mark as Read", "undone where it was taken")
        XCTAssertTrue(reader.place.window === reader)
        harness.close()
    }

    /// Opened from the Trash: ⇧I makes it an Inbox row, and its undo makes it a Trash row again, so the header, the menus
    /// and # agree with where the conversation is.
    func testUndoingMoveToInboxPutsTheViewBack() throws {
        let harness = try MainWindowHarness()
        let (id, reader) = try openFromTrash(0, harness)
        XCTAssertTrue(reader.perform(.moveToInbox))
        XCTAssertEqual(reader.place.view, .inbox)
        XCTAssertTrue(reader.perform(.undo))
        XCTAssertTrue(try harness.environment.store.messages(in: id).allSatisfy { $0.roles.contains(.trash) })
        XCTAssertEqual(reader.place.view, .trash, "back to the view it was opened from")
        XCTAssertEqual(reader.conversation.mailboxView, .trash)
        XCTAssertEqual(reader.conversation.header.content.actions.primary, [.star, .moveToInbox])
        XCTAssertTrue(reader.validateMenuItem(menuItem(#selector(ReaderWindowController.moveSelectionToInbox(_:)))))
        XCTAssertFalse(reader.validateMenuItem(menuItem(#selector(ReaderWindowController.trashSelection(_:)))))
        let groups = harness.controller.undoCenter.history.groups.count
        XCTAssertTrue(reader.perform(.trash), "# does nothing in the Trash, quietly")
        XCTAssertEqual(harness.controller.undoCenter.history.groups.count, groups)
        XCTAssertTrue(reader.place.window === reader)
        harness.close()
    }

    /// Trashed from the main window while it is open from the Inbox: the window reads where its messages are.
    func testATrashedConversationIsATrashRowWhicheverWindowTrashedIt() throws {
        let harness = try MainWindowHarness()
        let (id, reader) = try open(0, harness)
        XCTAssertTrue(harness.controller.perform(.trash))
        harness.spin { reader.conversation.currentMessages.allSatisfy { $0.roles.contains(.trash) } }
        XCTAssertEqual(reader.conversation.header.content.actions.primary, [.star, .moveToInbox])
        XCTAssertFalse(reader.validateMenuItem(menuItem(#selector(ReaderWindowController.trashSelection(_:)))))
        XCTAssertTrue(reader.validateMenuItem(menuItem(#selector(ReaderWindowController.moveSelectionToInbox(_:)))))
        let groups = harness.controller.undoCenter.history.groups.count
        XCTAssertTrue(reader.perform(.trash))
        XCTAssertEqual(harness.controller.undoCenter.history.groups.count, groups, "# does nothing, quietly")
        XCTAssertTrue(reader.place.window === reader)
        XCTAssertTrue(reader.perform(.moveToInbox))
        XCTAssertTrue(try inInbox(id, harness))
        harness.close()
    }

    // MARK: One history

    func testZInAReaderWindowUndoesTheMainWindowsStepThere() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try open(0, harness)
        select(1, harness)
        let archived = harness.list.conversations[1].id
        XCTAssertTrue(harness.controller.perform(.archive))
        XCTAssertEqual(harness.toastMessage, "Archived")
        // The edit menu's Undo, from the reader window, names the main window's step.
        let item = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        XCTAssertTrue(reader.validateEditUndo(item))
        XCTAssertEqual(item.title, "Undo Archive")
        XCTAssertTrue(reader.perform(.undo))
        XCTAssertTrue(try inInbox(archived, harness))
        XCTAssertEqual(harness.toastMessage, "Undid Archive", "the confirmation shows where the step was taken")
        XCTAssertNil(message(in: reader))
        harness.close()
    }

    func testStepsInDifferentWindowsNeverCoalesce() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try open(0, harness)
        select(2, harness)
        XCTAssertTrue(harness.controller.perform(.archive))
        XCTAssertTrue(reader.perform(.archive))
        XCTAssertEqual(harness.toastMessage, "Archived", "not “Archived 2 conversations”")
        XCTAssertEqual(harness.controller.undoCenter.history.groups.count, 2, "one undo per window's step")
        harness.close()
    }

    func testEscInAWindowDismissesOnlyItsOwnToast() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try open(0, harness)
        select(2, harness)
        XCTAssertTrue(harness.controller.perform(.archive))
        XCTAssertTrue(reader.perform(.clearSearch))
        XCTAssertTrue(harness.toasts.isVisible, "the main window's toast is the main window's to dismiss")
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "with nothing of its own to close, Esc closes the window")
        XCTAssertTrue(harness.controller.perform(.clearSearch))
        XCTAssertFalse(harness.toasts.isVisible)
        harness.close()
    }

    func testEscInAWindowDismissesItsToastAndItsUndoStillWorks() throws {
        let harness = try MainWindowHarness()
        let (id, reader) = try openFromTrash(0, harness)
        XCTAssertTrue(reader.perform(.moveToInbox))
        XCTAssertEqual(message(in: reader), "Moved to Inbox")
        XCTAssertTrue(harness.controller.perform(.clearSearch), "Esc in the main window")
        XCTAssertNotNil(message(in: reader), "leaves the window's toast")
        XCTAssertTrue(reader.perform(.clearSearch))
        XCTAssertNil(message(in: reader), "Esc in the window dismisses it")
        XCTAssertTrue(reader.perform(.undo), "Z still reaches it, for the grace period")
        XCTAssertFalse(try inInbox(id, harness))

        // Esc in the quick reply: the toast first, then the page takes the keyboard, the bar keeping its text.
        XCTAssertTrue(reader.perform(.moveToInbox))
        let bar = reader.conversation.quickReplyBar
        bar.text = "Half a thought"
        reader.conversation.onAction?(.escapeQuickReply(repeated: false))
        XCTAssertNil(message(in: reader))
        reader.conversation.onAction?(.escapeQuickReply(repeated: false))
        XCTAssertEqual(bar.text, "Half a thought")
        harness.close()
    }

    // MARK: Esc closes the window

    /// Esc with nothing else in the window for it to close, and nothing typed in its quick reply, closes the window as ⌘W
    /// does (§6.1): the key as the app delivers it, through the window's router, with the page focused. Its size is kept
    /// for the next window and the main window forgets it; the main window itself never closes on Esc.
    func testEscClosesAWindowWhoseQuickReplyHoldsNothing() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try open(0, harness)
        let window = try XCTUnwrap(reader.window)
        XCTAssertTrue(window.makeFirstResponder(reader.conversation.pool.current?.webView))
        reader.conversation.quickReplyBar.text = "  \n "
        XCTAssertFalse(reader.conversation.quickReplyHoldsWork, "blank text is no draft")
        try press("\u{1B}", keyCode: 53, in: window)
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "Esc closes it")
        XCTAssertNil(reader.place.window)
        XCTAssertFalse(window.isVisible)
        XCTAssertNotNil(UserDefaults.standard.string(forKey: Self.sizeKey), "its size is kept, as on ⌘W")

        let mainWindow = try XCTUnwrap(harness.controller.window)
        let mainCloses = XCTNSNotificationExpectation(name: NSWindow.willCloseNotification, object: mainWindow)
        mainCloses.isInverted = true
        XCTAssertTrue(mainWindow.makeFirstResponder(harness.list.tableView))
        try press("\u{1B}", keyCode: 53, in: mainWindow)
        XCTAssertTrue(harness.controller.perform(.clearSearch))
        wait(for: [mainCloses], timeout: 0.1)
        harness.close()
    }

    /// Esc in an empty quick reply closes the window too, once the field has done with the key.
    func testEscInAnEmptyQuickReplyClosesTheWindow() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try open(0, harness)
        let window = try XCTUnwrap(reader.window)
        XCTAssertTrue(reader.conversation.focusQuickReply(all: false))
        XCTAssertTrue(KeyboardRouter.isTextInput(window.firstResponder))
        window.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        harness.spin { harness.controller.readerWindows.isEmpty }
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "Esc in the empty field closes the window")
        XCTAssertNil(reader.place.window)
        harness.close()
    }

    /// Words in the quick reply keep the window: Esc in the field gives the page the keyboard, the words kept, and Esc on
    /// the page then does nothing, without a beep. A reply counting down keeps it too.
    func testEscKeepsAWindowWhoseQuickReplyHoldsTheUsersWork() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try open(0, harness)
        let window = try XCTUnwrap(reader.window)
        let bar = reader.conversation.quickReplyBar
        XCTAssertTrue(reader.conversation.focusQuickReply(all: false))
        bar.text = "Half a thought"
        window.firstResponder?.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        ListTestSupport.spin(for: 0.05)
        XCTAssertTrue(reader.place.window === reader, "the window stays")
        XCTAssertFalse(KeyboardRouter.isTextInput(window.firstResponder), "the page takes the keyboard")
        XCTAssertEqual(bar.text, "Half a thought", "the words stay")
        try press("\u{1B}", keyCode: 53, in: window)
        XCTAssertTrue(reader.perform(.clearSearch), "Esc on the page is taken, so it does not beep")
        ListTestSupport.spin(for: 0.05)
        XCTAssertTrue(reader.place.window === reader, "and closes nothing")
        XCTAssertEqual(bar.text, "Half a thought")

        // A reply counting down is the user's work as well, whatever the box holds since.
        let (_, sending) = try open(1, harness)
        sending.conversation.sendQuickReply("Sounds good", mode: .reply, action: .send)
        XCTAssertNotNil(sending.conversation.liveQuickSend)
        XCTAssertTrue(sending.conversation.quickReplyBar.text.isEmpty)
        XCTAssertTrue(sending.perform(.clearSearch))
        sending.conversation.onAction?(.escapeQuickReply(repeated: false))
        ListTestSupport.spin(for: 0.05)
        XCTAssertTrue(sending.place.window === sending, "Esc never closes a window over its countdown")
        harness.close()
    }

    /// Words in a bar that has hidden, its conversation gone to the Trash from the main window, are out of sight: Esc
    /// closes the window, and the words are parked with the conversation, as on ⌘W.
    func testEscClosesAWindowWhoseBarHidWithWordsInIt() throws {
        let harness = try MainWindowHarness()
        let (id, reader) = try open(0, harness)
        let bar = reader.conversation.quickReplyBar
        bar.text = "Typed before it went"
        XCTAssertTrue(reader.conversation.quickReplyHoldsWork)
        XCTAssertTrue(harness.controller.perform(.trash), "the main window trashes the same conversation")
        harness.spin { bar.isHidden }
        XCTAssertTrue(bar.isHidden, "a Trash row has no quick reply")
        XCTAssertFalse(reader.conversation.quickReplyHoldsWork)
        XCTAssertTrue(reader.perform(.clearSearch))
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "Esc closes the window")
        XCTAssertEqual(harness.controller.quickReplyDrafts.drafts.draft(under: id), "Typed before it went", "the words are kept")
        harness.close()
    }

    /// A toast in the window takes the first Esc and the window the second (§6.1 rows 8 and 13).
    func testEscDismissesTheWindowsToastFirstAndThenClosesIt() throws {
        let harness = try MainWindowHarness()
        let (id, reader) = try openFromTrash(0, harness)
        let window = try XCTUnwrap(reader.window)
        XCTAssertTrue(window.makeFirstResponder(reader.conversation.pool.current?.webView))
        XCTAssertTrue(reader.perform(.moveToInbox))
        XCTAssertEqual(message(in: reader), "Moved to Inbox")
        try press("\u{1B}", keyCode: 53, in: window)
        XCTAssertNil(message(in: reader), "the first Esc dismisses the toast")
        XCTAssertTrue(reader.place.window === reader, "and leaves the window")
        try press("\u{1B}", keyCode: 53, in: window)
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "the second closes it")
        XCTAssertTrue(try inInbox(id, harness), "closing it undoes nothing")
        harness.close()
    }

    /// Holding Esc down never closes a window (§6.1 row 13): the key's repeat still dismisses the window's toast, as every
    /// Esc does, but closes nothing after it; only a fresh press closes the window.
    func testHeldEscNeverClosesTheWindow() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try openFromTrash(0, harness)
        let window = try XCTUnwrap(reader.window)
        XCTAssertTrue(window.makeFirstResponder(reader.conversation.pool.current?.webView))
        XCTAssertTrue(reader.perform(.moveToInbox))
        XCTAssertNotNil(message(in: reader))
        try press("\u{1B}", keyCode: 53, in: window, repeated: true)
        XCTAssertNil(message(in: reader), "a repeat still dismisses the toast")
        for _ in 0..<5 { try press("\u{1B}", keyCode: 53, in: window, repeated: true) }
        ListTestSupport.spin(for: 0.05)
        XCTAssertTrue(reader.place.window === reader, "the repeats close nothing")
        XCTAssertTrue(reader.perform(.escapeRepeat), "a repeat is spent quietly, without a beep")
        try press("\u{1B}", keyCode: 53, in: window)
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "a fresh press closes it")
        harness.close()
    }

    /// Two windows, Esc held in the front one: the press closes it, and the repeats that follow, reaching the window
    /// behind as it becomes key, leave that one open.
    func testHeldEscClosesOneWindowNotTheNext() throws {
        let harness = try MainWindowHarness()
        let (_, first) = try open(1, harness)
        let (_, second) = try open(2, harness)
        let front = try XCTUnwrap(second.window)
        XCTAssertTrue(front.makeFirstResponder(second.conversation.pool.current?.webView))
        try press("\u{1B}", keyCode: 53, in: front)
        XCTAssertEqual(harness.controller.readerWindows.map(\.conversationID), [first.conversationID])
        let back = try XCTUnwrap(first.window)
        XCTAssertTrue(back.makeFirstResponder(first.conversation.pool.current?.webView))
        for _ in 0..<3 { try press("\u{1B}", keyCode: 53, in: back, repeated: true) }
        XCTAssertTrue(first.place.window === first, "the repeat reaching the next window leaves it open")
        harness.close()
    }

    /// The same in the quick reply: the repeat of an Esc held in an empty bar closes nothing, a fresh press closes the window.
    func testHeldEscInAnEmptyQuickReplyNeverClosesTheWindow() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try open(0, harness)
        let window = try XCTUnwrap(reader.window)
        XCTAssertTrue(reader.conversation.focusQuickReply(all: false))
        let field = try XCTUnwrap(window.firstResponder)
        XCTAssertTrue(KeyboardRouter.isTextInput(field))
        for _ in 0..<3 { field.keyDown(with: try keyEvent("\u{1B}", keyCode: 53, in: window, repeated: true)) }
        ListTestSupport.spin(for: 0.05)
        XCTAssertTrue(reader.place.window === reader, "held: the window stays")
        field.keyDown(with: try keyEvent("\u{1B}", keyCode: 53, in: window))
        harness.spin { harness.controller.readerWindows.isEmpty }
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "a fresh press closes it")
        harness.close()
    }

    // MARK: Keys and menus

    /// A reader window has no list to go back to: ← closes the window's toast or its find bar as Esc does, and otherwise
    /// goes on to the page (a chip's or a Download button's ← →, the reply tabs, a wide body's scroll). It was taken
    /// always, so the page never had it.
    func testLeftIsThePagesUnlessTheWindowHasSomethingToClose() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try openFromTrash(0, harness)
        XCTAssertEqual(KeyboardRouter.command(characters: "", keyCode: 123, modifiers: [], pendingG: false,
                                              readerFocused: reader.isReaderFocused).command, .back)
        XCTAssertFalse(reader.perform(.back), "nothing to close: ← goes on to the page")

        XCTAssertTrue(reader.perform(.moveToInbox))
        XCTAssertEqual(message(in: reader), "Moved to Inbox")
        XCTAssertTrue(reader.perform(.back), "the toast takes it first")
        XCTAssertNil(message(in: reader))
        XCTAssertFalse(reader.perform(.back))

        XCTAssertTrue(ListTestSupport.spin(until: { reader.conversation.pool.current?.renderedID == reader.conversationID }, timeout: 10))
        reader.findInConversation(nil)
        XCTAssertTrue(reader.conversation.find.isOpen)
        XCTAssertTrue(reader.perform(.back), "then the find bar")
        XCTAssertFalse(reader.conversation.find.isOpen)
        XCTAssertFalse(reader.perform(.back))
        harness.close()
    }

    /// Download all from a window that closes before the files are in: the download goes on (its task holds the reader),
    /// and its saved toast, with Show in Finder, shows in the main window. It went to the window's controller, gone by
    /// then, and nowhere showed it.
    func testASaveThatEndsAfterItsWindowClosedToastsInTheMainWindow() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        var conversation: ConversationViewController?
        weak var gone: ReaderWindowController?
        try autoreleasepool {
            let (_, reader) = try open(0, harness)
            conversation = reader.conversation
            gone = reader
            reader.close()
        }
        harness.spin { gone == nil }
        XCTAssertNil(gone, "the window's controller has gone")
        let file = folder.appendingPathComponent("plan.pdf")
        let outcome = AttachmentSaveOutcome(requested: 1, saved: [file], unfetched: 0)
        try XCTUnwrap(conversation).onAction?(.attachmentsSaved(outcome))
        XCTAssertEqual(harness.toastMessage, "Saved to Downloads")
        XCTAssertTrue(harness.toasts.isVisible(in: harness.controller.listPane.toastView), "in the main window")
    }

    /// The G-sequence HUD takes the toast's place in a reader window, 16 pt above the quick reply; placed as in the main
    /// window, 44 pt above the bottom of the window for a sync line it does not have, it covered the top of the bar.
    func testTheSequenceHUDSitsAboveTheQuickReply() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let (_, reader) = try open(0, harness)
        let content = try XCTUnwrap(reader.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let bar = reader.conversation.quickReplyBar
        XCTAssertFalse(bar.isHidden)
        let router = KeyboardRouter(target: reader)
        router.showSequenceHUDNow()
        defer { router.disarmSequence(animated: false) }
        let hud = try XCTUnwrap(Self.views(in: content).first { $0 is QuireSequenceHUDView })
        let hudFrame = hud.convert(hud.bounds, to: nil)
        let barFrame = bar.convert(bar.bounds, to: nil)
        XCTAssertEqual(hudFrame.minY - barFrame.maxY, Quire.Layout.Toast.aboveSyncLine, accuracy: 1,
                       "where the toast sits, clear of the bar")
        XCTAssertEqual(hudFrame.midX, content.convert(content.bounds, to: nil).midX, accuracy: 1)
    }

    /// View › Inbox, Starred and the rest, and ⌘0 to ⌘9, act in the main window, which comes forward, as G I and the other
    /// sequences listed beside them do in a reader window (§5.49). A reader window answered none of them, so the items
    /// were disabled there while their keys worked.
    func testTheViewMenusMailboxesAndAccountsWorkFromAWindow() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let (_, reader) = try open(0, harness)
        let viewTag = try XCTUnwrap(MailboxView.allCases.firstIndex(of: .starred))
        let starred = NSMenuItem(title: "Starred", action: #selector(MainWindowController.goToMailboxView(_:)), keyEquivalent: "")
        starred.tag = viewTag
        XCTAssertTrue(reader.responds(to: starred.action), "the window answers the item")
        XCTAssertTrue(reader.validateMenuItem(starred))
        reader.goToMailboxView(starred)
        harness.spin { harness.list.query.view == .starred }
        XCTAssertEqual(harness.list.query.view, .starred)

        let account = NSMenuItem(title: "Account 1", action: #selector(MainWindowController.selectAccountShortcut(_:)), keyEquivalent: "1")
        account.tag = 1
        XCTAssertTrue(reader.responds(to: account.action))
        XCTAssertTrue(reader.validateMenuItem(account))
        reader.selectAccountShortcut(account)
        harness.spin { harness.list.query.accountIDs == [ListTestSupport.accountA.id] }
        XCTAssertEqual(harness.list.query.accountIDs, [ListTestSupport.accountA.id])
        let missing = NSMenuItem(title: "Account 9", action: #selector(MainWindowController.selectAccountShortcut(_:)), keyEquivalent: "9")
        missing.tag = 9
        XCTAssertFalse(reader.validateMenuItem(missing), "an account that is not there, as in the main window")
    }

    /// Find's words are the session's (§5.50), not one reader's: found in the main window, Find Next is enabled in a
    /// reader window opened afterwards and ⌘G there opens the bar with them, as ⌥⌘F does; words typed in a window reach
    /// the main window's ⌘G too. Each reader kept its own, so a new window's Find Next was disabled and ⌘G beeped.
    func testFindsWordsAreTheSessionsInEveryWindow() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        select(0, harness)
        harness.controller.findInConversation(nil)
        harness.reader.find.open(query: "lisbon")
        harness.reader.find.close(returningFocus: false)

        let (_, first) = try open(1, harness)
        XCTAssertTrue(first.validateMenuItem(menuItem(#selector(ReaderWindowController.findNextMatch(_:)))), "Find Next is enabled")
        first.findNextMatch(nil)
        XCTAssertEqual(first.conversation.find.bar?.query, "lisbon", "⌘G opens the bar with the session's words")
        first.conversation.find.close(returningFocus: false)
        first.findInConversation(nil)
        XCTAssertEqual(first.conversation.find.bar?.query, "lisbon", "and so does ⌥⌘F")

        // Typed in a window, the words are the main window's next ⌘G.
        first.conversation.find.open(query: "porto")
        first.conversation.find.close(returningFocus: false)
        XCTAssertEqual(harness.reader.find.stepQuery, "porto")
        harness.controller.findNextMatch(nil)
        XCTAssertEqual(harness.reader.find.bar?.query, "porto")
    }

    /// The quick reply's Reply · Reply all tabs choose with ← →, so the main window lets a focused tab group have them
    /// (`ShellKeyHandling`, asked before the router acts); ← went back to the list instead.
    func testTheReplyTabsKeepTheirArrowsInTheMainWindow() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        select(0, harness)
        let tabs = try XCTUnwrap(Self.views(in: harness.reader.quickReplyBar).compactMap { $0 as? QuireUnderlineTabs }.first)
        func key(_ keyCode: UInt16, _ function: Int, _ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
            let characters = String(UnicodeScalar(function)!)
            return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: 0,
                                                  context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                  isARepeat: false, keyCode: keyCode))
        }
        let handling = tabs as ShellKeyHandling
        XCTAssertTrue(handling.handlesKey(try key(123, NSLeftArrowFunctionKey)), "←")
        XCTAssertTrue(handling.handlesKey(try key(124, NSRightArrowFunctionKey)), "→")
        XCTAssertFalse(handling.handlesKey(try key(123, NSLeftArrowFunctionKey, .shift)))
        XCTAssertFalse(handling.handlesKey(try key(125, NSDownArrowFunctionKey)), "↓ is the list's")
        XCTAssertFalse(handling.handlesKey(try key(14, Int(("e" as Unicode.Scalar).value))))
    }

    private static func views(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { views(in: $0) }
    }

    func testTheWindowsKeysAndMenusActOnItsConversation() throws {
        let harness = try MainWindowHarness()
        // Thread 3 is unread (every third is).
        let (id, reader) = try open(3, harness)
        XCTAssertFalse(reader.perform(.next), "no list to move in: J goes on to the page")
        XCTAssertFalse(reader.perform(.open))
        let unread = NSMenuItem(title: "Mark as Unread", action: #selector(ReaderWindowController.markSelectionUnread(_:)), keyEquivalent: "u")
        XCTAssertTrue(reader.validateMenuItem(unread))
        XCTAssertTrue(reader.perform(.toggleRead))
        XCTAssertTrue(try harness.environment.store.messages(in: id).allSatisfy(\.isRead))
        // U reads the reader's messages, which the store's observation brings.
        harness.spin { reader.conversation.currentMessages.allSatisfy(\.isRead) }
        XCTAssertTrue(reader.perform(.toggleRead))
        XCTAssertTrue(try harness.environment.store.messages(in: id).contains { !$0.isRead })
        // Menus a reader window has no part in stay disabled there; the main window's own are not its.
        XCTAssertFalse(reader.responds(to: #selector(MainWindowController.openSelectionInNewWindow(_:))))
        XCTAssertFalse(reader.validateMenuItem(NSMenuItem(title: "Move to Inbox",
                                                          action: #selector(ReaderWindowController.moveSelectionToInbox(_:)),
                                                          keyEquivalent: "I")), "it is in the Inbox already")
        let menu = reader.contextMenu()
        // The main window's menu (§5.35): Mute and Mark as Spam among the selection's commands, the sender rules after a
        // separator, since someone other than the user wrote this mail.
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "—" : $0.title },
                       ["Reply", "Reply All", "Forward", "—", "Archive", "Later", "Star", "Mark as Unread", "Mute", "Move to Inbox", "—",
                        "Move to Trash", "Mark as Spam", "—", "Always Archive Mail from This Sender", "Block Sender"])
        XCTAssertTrue(menu.items.filter { !$0.isSeparatorItem && $0.title != "Later" }.allSatisfy { $0.target === reader })
        XCTAssertTrue(Quire.cheatSheet.flatMap(\.rows).contains { $0.keys == "↩" && $0.label == "Open in a new window" },
                      "the cheat sheet lists ↩, the key ⌘O is the menu's alternate for")
        harness.close()
    }

    func testTheUndoCenterRanksCommandZForTheUndoSendPanels() throws {
        let harness = try MainWindowHarness()
        XCTAssertTrue(UndoSendPanel.undoKeyArbiter === harness.controller.undoCenter)
        harness.close()
        XCTAssertNil(UndoSendPanel.undoKeyArbiter)
    }

    // MARK: Unsubscribe

    func testUnsubscribeClosesTheWindowAndItsUndoOpensItAgain() throws {
        let harness = try MainWindowHarness()
        harness.controller.openUnsubscribePage = { _ in XCTFail("one click opens no page") }
        let account = ListTestSupport.accountA
        let news = ConversationID(accountID: account.id, providerID: "news")
        let sender = EmailAddress(name: "Frontend Weekly", address: "hello@frontendweekly.test")
        try harness.environment.store.upsertMessages([1, 2].map { n in
            MessageMetadata(id: MessageID(accountID: account.id, providerID: "news-\(n)"), conversationID: news,
                            subject: "Frontend Weekly #12\(n)", snippet: "This week", from: sender,
                            to: [EmailAddress(name: account.displayName, address: account.email)],
                            date: Date().addingTimeInterval(Double(n) - 10), roles: [.inbox], isRead: true, isStarred: false,
                            hasAttachments: false, listUnsubscribe: n == 2 ? "<https://news.example.com/u/42>" : nil,
                            listUnsubscribePost: n == 2 ? "List-Unsubscribe=One-Click" : nil)
        })
        harness.spin { harness.list.conversations.contains { $0.id == news } }
        let reader = try XCTUnwrap(harness.controller.openInNewWindow(news))
        XCTAssertTrue(reader.validateMenuItem(menuItem(#selector(ReaderWindowController.unsubscribeFromConversation(_:)))))
        reader.unsubscribeFromConversation(nil)
        XCTAssertFalse(try inInbox(news, harness))
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "the conversation left the desk, and the window with it")
        XCTAssertEqual(harness.toastMessage, "Unsubscribe sent \u{00B7} Archived", "the toast shows in the main window")

        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertTrue(try inInbox(news, harness))
        let reopened = try XCTUnwrap(harness.controller.readerWindows.first)
        XCTAssertEqual(reopened.conversationID, news)
        XCTAssertEqual(message(in: reopened), "Undid Archive \u{00B7} Unsubscribe stays sent")
        harness.close()
    }

    // MARK: Discard Draft

    /// “Discard draft…” on a draft in the window's page asks on that window, and the confirmed discard is the window's
    /// step: the conversation goes to the Trash and the window with it, its undo opening it again.
    func testDiscardingADraftAsksOnTheWindowAndClosesIt() throws {
        let harness = try MainWindowHarness()
        let account = ListTestSupport.accountA
        let id = harness.list.conversations[0].id
        XCTAssertEqual(id.accountID, account.id)
        try harness.environment.store.upsertMessages([
            MessageMetadata(id: MessageID(accountID: account.id, providerID: "draft-0"), conversationID: id,
                            subject: "Re: Project update 0 and the quarterly planning document", snippet: "Half a reply",
                            from: EmailAddress(name: account.displayName, address: account.email), to: [ListTestSupport.senders[0]],
                            date: Date(), roles: [.drafts], isRead: true, isStarred: false, hasAttachments: false),
        ])
        let (_, reader) = try open(0, harness)
        var askedOn: NSWindow?
        harness.controller.presentAlert = { _, window, done in
            askedOn = window
            done(1)
        }
        reader.conversation.onAction?(.discardDrafts([id]))
        XCTAssertNotNil(askedOn)
        XCTAssertTrue(askedOn === reader.window, "asked where it was clicked")
        XCTAssertTrue(try harness.environment.store.messages(in: id).allSatisfy { $0.roles.contains(.trash) })
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "Move to Trash closes the window")
        XCTAssertEqual(harness.toastMessage, "Draft discarded")
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertFalse(try harness.environment.store.messages(in: id).allSatisfy { $0.roles.contains(.trash) })
        XCTAssertEqual(harness.controller.readerWindows.map(\.conversationID), [id], "its undo opens the window again")

        // Kept: nothing changes, and the window stays.
        let again = try XCTUnwrap(harness.controller.readerWindows.first)
        harness.controller.presentAlert = { _, _, done in done(0) }
        again.conversation.onAction?(.discardDrafts([id]))
        XCTAssertTrue(again.place.window === again)
        harness.close()
    }

    // MARK: The quick reply

    /// Text typed in the window's quick reply outlives the window: the window an undo opens again finds it, and so does
    /// the main window's reader when the user closes the window.
    func testQuickReplyTextComesBackWithTheWindowAnUndoOpens() throws {
        let harness = try MainWindowHarness()
        let (id, reader) = try open(0, harness)
        let bar = reader.conversation.quickReplyBar
        XCTAssertTrue(reader.conversation.focusQuickReply(all: false))
        bar.text = "Tuesday works for me"
        reader.conversation.leaveQuickReply()
        XCTAssertTrue(reader.perform(.archive))
        XCTAssertTrue(harness.controller.readerWindows.isEmpty)
        // The main window's reader, which showed the conversation too, moves on with an empty box.
        harness.spin { harness.reader.currentConversationID != id }
        XCTAssertTrue(harness.controller.perform(.undo))
        let reopened = try XCTUnwrap(harness.controller.readerWindows.first)
        XCTAssertEqual(reopened.conversation.quickReplyBar.text, "Tuesday works for me", "the box holds what was typed")
        harness.close()
    }

    func testQuickReplyTextOfAWindowTheUserClosesWaitsForTheMainWindow() throws {
        let harness = try MainWindowHarness()
        let (id, reader) = try open(0, harness)
        reader.conversation.quickReplyBar.text = "Typed in the window"
        reader.close()
        XCTAssertEqual(harness.reader.currentConversationID, id)
        XCTAssertEqual(harness.reader.quickReplyBar.text, "Typed in the window", "the main window shows the same conversation")

        // Closed while the main window shows another: there when it shows this one.
        let (other, second) = try open(1, harness)
        // Waits for the reader to show the third, not merely to have left the second: it may still show the first.
        let third = harness.list.conversations[2].id
        select(2, harness)
        harness.spin { harness.reader.currentConversationID == third }
        second.conversation.quickReplyBar.text = "For the second"
        second.close()
        XCTAssertEqual(harness.reader.quickReplyBar.text, "")
        select(1, harness)
        harness.spin { harness.reader.currentConversationID == other }
        XCTAssertEqual(harness.reader.quickReplyBar.text, "For the second")
        harness.close()
    }

    /// ⌘Z reaches the window's countdown, from the window and from the main window, and the text goes back in its box.
    func testCommandZCancelsTheWindowsQuickReplySend() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try open(0, harness)
        reader.conversation.sendQuickReply("Sounds good", mode: .reply, action: .send)
        let send = try XCTUnwrap(reader.conversation.liveQuickSend, "the window's strip counts down")
        XCTAssertEqual(harness.controller.undoCenter.commandZTarget(textCanUndo: false), .send(send.id))
        let item = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        XCTAssertTrue(reader.validateEditUndo(item))
        XCTAssertEqual(item.title, "Undo Send")
        reader.performEditUndo()
        XCTAssertNil(reader.conversation.liveQuickSend)
        XCTAssertNil(try pendingSend(harness), "the send was cancelled")
        XCTAssertEqual(reader.conversation.quickReplyBar.text, "Sounds good")

        // From the main window too: the history is the app's.
        reader.conversation.sendQuickReply("Sounds good", mode: .reply, action: .send)
        XCTAssertNotNil(reader.conversation.liveQuickSend)
        harness.controller.performEditUndo()
        XCTAssertNil(reader.conversation.liveQuickSend)
        XCTAssertNil(try pendingSend(harness))
        harness.close()
    }

    /// Closing the window mid-countdown moves the countdown to an undo-send panel, which ⌘Z still reaches.
    func testClosingTheWindowMidCountdownHandsTheSendToAPanel() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try open(0, harness)
        reader.conversation.sendQuickReply("Sounds good", mode: .reply, action: .send)
        let send = try XCTUnwrap(reader.conversation.liveQuickSend)
        reader.close()
        XCTAssertEqual(UndoSendPanel.liveSends, [send], "same send, same start")
        XCTAssertEqual(harness.controller.undoCenter.commandZTarget(textCanUndo: false), .send(send.id))
        harness.controller.performEditUndo()
        XCTAssertTrue(UndoSendPanel.liveSends.isEmpty)
        XCTAssertNil(try pendingSend(harness), "the send was cancelled")
        XCTAssertNotNil(ComposeWindowRegistry.shared.openControllers.first, "the reply comes back in a composer")
        harness.close()
    }

    /// Send and Archive takes the conversation off the desk, as E does: the window closes, its countdown in a panel whose
    /// Undo brings back the reply and the conversation.
    func testSendAndArchiveClosesTheWindowWithItsCountdownInAPanel() throws {
        let harness = try MainWindowHarness()
        let (id, reader) = try open(0, harness)
        reader.conversation.sendQuickReply("Thanks, done", mode: .reply, action: .sendAndArchive)
        let send = try XCTUnwrap(reader.conversation.liveQuickSend)
        XCTAssertFalse(try inInbox(id, harness))
        harness.spin { harness.controller.readerWindows.isEmpty }
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "the window closes with its conversation")
        XCTAssertEqual(UndoSendPanel.liveSends, [send])
        XCTAssertEqual(UndoSendPanel.panel(sendID: send.id)?.undoMenuTitle, "Undo Send and Archive")
        harness.controller.performEditUndo()
        XCTAssertTrue(try inInbox(id, harness), "the undo brings the conversation back")
        XCTAssertNil(try pendingSend(harness))

        // Send alone leaves the conversation, and the window, where they are.
        let (_, kept) = try open(1, harness)
        kept.conversation.sendQuickReply("Noted", mode: .reply, action: .send)
        ListTestSupport.spin(for: 0.1)
        XCTAssertTrue(kept.place.window === kept)
        harness.close()
    }

    /// A reply that fails after its undo window, once its window has closed, still says so, in the main window.
    func testASendThatFailsAfterTheWindowClosedShowsItsErrorToast() throws {
        let harness = try MainWindowHarness()
        let (_, reader) = try open(0, harness)
        ConversationViewController.undoWindow = 0.05
        reader.conversation.sendQuickReply("Thanks, sounds good", mode: .reply, action: .send)
        harness.spin { reader.conversation.liveQuickSend == nil }
        var send = try XCTUnwrap(try pendingSend(harness))
        XCTAssertTrue(reader.conversation.watchedSendIDs.contains(send.id))
        reader.close()
        XCTAssertTrue(harness.reader.watchedSendIDs.contains(send.id), "the main window's reader watches it now")

        send.status = .failed
        send.lastError = "network"
        try harness.environment.store.updateSend(send)
        harness.reader.pollWatchedSends()
        XCTAssertEqual(harness.toastMessage, "Couldn\u{2019}t send your reply")
        ComposeDraftStore.shared.waitForWrites()
        let accounts = [ListTestSupport.accountA, ListTestSupport.accountB]
        XCTAssertEqual(try XCTUnwrap(ComposeDraftStore.shared.keptDrafts(accounts: accounts).first).body.string, "Thanks, sounds good")
        harness.close()
    }

    // MARK: The window's own keys

    /// Keys as the app delivers them: the window's own router takes them in its window, outside text, and leaves them to a
    /// field being typed in.
    func testTheWindowsRouterTakesItsKeysOutsideText() throws {
        let harness = try MainWindowHarness()
        // Thread 0 is starred (every fifth is).
        let (id, reader) = try open(0, harness)
        let window = try XCTUnwrap(reader.window)
        let mainWindow = try XCTUnwrap(harness.controller.window)
        window.makeFirstResponder(reader.conversation.pool.current?.webView)

        // A key in another window is not the reader window's, even while it is key.
        try press("s", keyCode: 1, in: mainWindow, key: window)
        XCTAssertTrue(try harness.environment.store.messages(in: id).contains(where: \.isStarred))
        try press("s", keyCode: 1, in: window)
        XCTAssertFalse(try harness.environment.store.messages(in: id).contains(where: \.isStarred), "S unstars it")

        // Typing in the quick reply: E is an e.
        XCTAssertTrue(reader.conversation.focusQuickReply(all: false))
        XCTAssertTrue(KeyboardRouter.isTextInput(window.firstResponder))
        try press("e", keyCode: 14, in: window)
        XCTAssertTrue(try inInbox(id, harness))
        XCTAssertTrue(reader.place.window === reader)

        // On the page: E archives, and the window goes.
        reader.conversation.leaveQuickReply()
        try press("e", keyCode: 14, in: window)
        XCTAssertFalse(try inInbox(id, harness))
        XCTAssertTrue(harness.controller.readerWindows.isEmpty)
        harness.close()
    }

    // MARK: Accounts

    func testRemovingAnAccountClosesItsConversationsWindows() throws {
        let harness = try MainWindowHarness()
        let (_, first) = try open(0, harness)
        let (other, second) = try open(1, harness)
        XCTAssertEqual(other.accountID, ListTestSupport.accountB.id)
        try harness.environment.store.deleteAccount(ListTestSupport.accountB.id)
        harness.controller.refreshAccounts()
        XCTAssertNil(second.place.window, "the removed account's window goes")
        XCTAssertEqual(harness.controller.readerWindows.map(\.conversationID), [first.conversationID], "the other account's stays")
        harness.close()
    }
}
