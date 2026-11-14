import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// A conversation in its own window (spec §5.49) through the app harness: ⌘O and ⌘-double-click, the window's chrome
/// and web view, its keys and menus acting on its conversation, steps that close it with their toast in the main window
/// and an undo that opens it again, steps that keep it with their toast in it, one undo history across windows, and its
/// quick reply's text, countdown and sends outliving it. Drafts go to a temporary folder.
@MainActor
final class ReaderWindowTests: XCTestCase {
    private static let sizeKey = "ReaderWindowSize"
    private var folder: URL!
    private var savedUndoWindow: TimeInterval = 5

    override func setUp() {
        super.setUp()
        // A size an earlier test left would stand in for the default.
        UserDefaults.standard.removeObject(forKey: Self.sizeKey)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowReaderWindow-\(UUID().uuidString)")
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
    /// window is seldom key, and the routers act only in the key window, so they are told which one is (`key`).
    private func press(_ characters: String, keyCode: UInt16, in window: NSWindow, key: NSWindow? = nil) throws {
        KeyboardRouter.keyWindowForTests = key ?? window
        defer { KeyboardRouter.keyWindowForTests = nil }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                   isARepeat: false, keyCode: keyCode))
        NSApp.sendEvent(event)
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

    func testCommandDoubleClickOpensTheClickedRowInAWindow() throws {
        let harness = try MainWindowHarness()
        select(0, harness)
        let selected = harness.list.conversations[0].id
        let clicked = harness.list.conversations[2].id
        let row = try XCTUnwrap(harness.list.layout.row(ofConversation: 2))
        harness.list.rowDoubleClicked(row, modifiers: .command)
        XCTAssertEqual(harness.controller.readerWindows.map(\.conversationID), [clicked])
        XCTAssertEqual(harness.list.selectedConversationID, selected, "opening the window selects nothing itself")
        // Without ⌘ a double-click opens in the reader, as before.
        harness.list.rowDoubleClicked(row, modifiers: [])
        XCTAssertEqual(harness.controller.readerWindows.count, 1)
        harness.close()
    }

    func testNothingOpensWithSeveralSelectedNothingSelectedOrInDrafts() throws {
        let harness = try MainWindowHarness()
        XCTAssertFalse(harness.controller.validateMenuItem(openItem()), "nothing selected")
        harness.selectFirst(2)
        XCTAssertFalse(harness.controller.validateMenuItem(openItem()), "a window holds one conversation")
        harness.controller.openSelectionInNewWindow(nil)
        XCTAssertTrue(harness.controller.readerWindows.isEmpty)
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
        XCTAssertTrue(reader.validateMenuItem(menuItem(#selector(ReaderWindowController.markSelectionSpam(_:)))))
        XCTAssertTrue(reader.perform(.markSpam))
        XCTAssertTrue(try harness.environment.store.messages(in: id).contains { $0.roles.contains(.spam) })
        XCTAssertFalse(try inInbox(id, harness))
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "the conversation left the desk, and the window with it")
        XCTAssertEqual(harness.toastMessage, "Marked as spam")
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertTrue(try inInbox(id, harness))
        XCTAssertEqual(harness.controller.readerWindows.map(\.conversationID), [id])
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
        XCTAssertEqual(try harness.environment.store.senderRules().map(\.address), [address])
        XCTAssertTrue(reader.place.window === reader)
        XCTAssertEqual(message(in: reader), MailActionCopy.senderRuleSet(.trash, address: address))
        XCTAssertFalse(reader.validateMenuItem(block), "the rule the sender has is checked and has nothing to do")
        XCTAssertEqual(block.state, .on)
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
        SendLaterScheduled(sendID: sendID, date: date) { undone = true }.post(from: reader.conversation)
        XCTAssertTrue(self.message(in: reader)?.hasPrefix("Sends") == true, "the window's step: \(String(describing: self.message(in: reader)))")
        XCTAssertFalse(harness.toasts.isVisible(in: harness.controller.listPane.toastView))
        XCTAssertTrue(reader.perform(.undo))
        XCTAssertTrue(undone)
        harness.close()
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
        reader.conversation.onAction?(.escapeQuickReply)
        XCTAssertNil(message(in: reader))
        reader.conversation.onAction?(.escapeQuickReply)
        XCTAssertEqual(bar.text, "Half a thought")
        harness.close()
    }

    // MARK: Keys and menus

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
        XCTAssertTrue(Quire.cheatSheet.flatMap(\.rows).contains { $0.keys == "⌘O" }, "the cheat sheet lists ⌘O")
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
