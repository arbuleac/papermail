import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// A conversation in its own window (spec §5.19a) through the app harness: ⌘O and ⌘-double-click, the window's chrome
/// and web view, its keys and menus acting on its conversation, steps that close it with their toast in the main window
/// and an undo that opens it again, steps that keep it with their toast in it, and one undo history across windows.
@MainActor
final class ReaderWindowTests: XCTestCase {
    private static let sizeKey = "ReaderWindowSize"

    override func setUp() {
        super.setUp()
        // A size an earlier test left would stand in for the default.
        UserDefaults.standard.removeObject(forKey: Self.sizeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.sizeKey)
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
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "—" : $0.title },
                       ["Reply", "Reply All", "Forward", "—", "Archive", "Later", "Star", "Mark as Unread", "Move to Inbox", "—", "Move to Trash"])
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
}
