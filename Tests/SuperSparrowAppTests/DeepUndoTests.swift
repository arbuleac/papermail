import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// ⌘Z walks back through the last 50 steps however old they are (spec §6.1): archives, stars and moves to the Trash taken
/// one by one come back newest first long after their toasts and grace, Edit › Undo names each, Z still stops at the
/// grace, a step whose mail is gone gives way to the one behind it, and a step taken in a reader window closed long ago
/// comes back in the main window. The undo center's clock is moved past the grace rather than waited out.
@MainActor
final class DeepUndoTests: XCTestCase {
    /// The undo center's clock, which the tests move.
    private final class Clock {
        var now = Date()
    }

    private func harness(_ clock: Clock) throws -> MainWindowHarness {
        let harness = try MainWindowHarness()
        harness.controller.undoCenter.now = { clock.now }
        return harness
    }

    private func store(_ harness: MainWindowHarness) -> MailStoring { harness.environment.store }

    private func select(_ id: ConversationID, _ harness: MainWindowHarness) {
        harness.spin { harness.list.conversations.contains { $0.id == id } }
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
    }

    private func inInbox(_ id: ConversationID, _ harness: MainWindowHarness) throws -> Bool {
        try store(harness).messages(in: id).contains(where: \.isInInbox)
    }

    private func isStarred(_ id: ConversationID, _ harness: MainWindowHarness) throws -> Bool {
        try store(harness).messages(in: id).contains(where: \.isStarred)
    }

    /// Edit › Undo as the menu validates it: whether it is enabled, and its title.
    private func editUndo(_ harness: MainWindowHarness) -> (enabled: Bool, title: String) {
        let item = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        let enabled = harness.controller.validateEditUndo(item)
        return (enabled, item.title)
    }

    private func openInWindow(_ id: ConversationID, _ harness: MainWindowHarness) throws -> ReaderWindowController {
        select(id, harness)
        harness.controller.openSelectionInNewWindow(nil)
        return try XCTUnwrap(harness.controller.readerWindows.first { $0.conversationID == id })
    }

    // MARK: Walking back

    func testCommandZBringsBackArchiveStarAndTrashNewestFirstLongAfter() throws {
        let clock = Clock()
        let harness = try harness(clock)
        defer { harness.close() }
        let ids = harness.list.conversations.prefix(4).map(\.id)
        // Threads 1 to 3 are not starred (every fifth is).
        let (archived, starred, trashed) = (ids[1], ids[2], ids[3])
        XCTAssertFalse(try isStarred(starred, harness))

        select(archived, harness)
        XCTAssertTrue(harness.controller.perform(.archive))
        XCTAssertEqual(harness.toastMessage, "Archived")
        harness.toasts.dismiss()
        clock.now += 60
        select(starred, harness)
        XCTAssertTrue(harness.controller.perform(.toggleStar))
        XCTAssertFalse(harness.toasts.isVisible, "a star is shown by the row itself and never gets a toast")
        clock.now += 60
        select(trashed, harness)
        XCTAssertTrue(harness.controller.perform(.trash))
        XCTAssertEqual(harness.toastMessage, "Moved to Trash")
        harness.toasts.dismiss()

        // Views, scopes and searches never clear the history.
        XCTAssertTrue(harness.controller.perform(.goTo(.starred)))
        harness.controller.strip.select(.account(ListTestSupport.accountA.id), notify: true)
        harness.controller.listPane.runSearch("quarterly")
        harness.controller.listPane.clearSearch()
        harness.controller.strip.select(.unified, notify: true)
        XCTAssertTrue(harness.controller.perform(.goTo(.inbox)))
        clock.now += 3_600

        XCTAssertEqual(harness.controller.zTarget, .nothing, "Z does not change: every grace is long over")
        harness.controller.undoMailAction(nil)
        XCTAssertFalse(try inInbox(trashed, harness), "Z did nothing")

        XCTAssertEqual(editUndo(harness).title, "Undo Move to Trash")
        harness.controller.performEditUndo()
        XCTAssertTrue(try inInbox(trashed, harness))
        XCTAssertFalse(try store(harness).messages(in: trashed).contains { $0.roles.contains(.trash) })
        XCTAssertEqual(harness.toastMessage, "Undid Move to Trash")

        XCTAssertEqual(editUndo(harness).title, "Undo Star")
        harness.controller.performEditUndo()
        XCTAssertFalse(try isStarred(starred, harness))
        XCTAssertEqual(harness.toastMessage, "Undid Star")

        XCTAssertEqual(editUndo(harness).title, "Undo Archive")
        XCTAssertTrue(editUndo(harness).enabled)
        harness.controller.performEditUndo()
        XCTAssertTrue(try inInbox(archived, harness))
        XCTAssertEqual(harness.toastMessage, "Undid Archive")

        let last = editUndo(harness)
        XCTAssertFalse(last.enabled)
        XCTAssertEqual(last.title, "Can't Undo")
        XCTAssertEqual(harness.controller.commandZTarget(textCanUndo: false), .nothing)
    }

    /// The 51st step drops the oldest: 50 presses walk back to the state after the first step, which stays.
    func testFiftyOneStepsLeaveFiftyForCommandZ() throws {
        let clock = Clock()
        let harness = try harness(clock)
        defer { harness.close() }
        let id = harness.list.conversations[1].id
        XCTAssertFalse(try isStarred(id, harness))
        for step in 1...51 {
            harness.controller.handle(.star(id, step % 2 == 1))
            clock.now += 2
        }
        XCTAssertTrue(try isStarred(id, harness))
        XCTAssertEqual(harness.controller.undoCenter.history.groups.count, 50)
        clock.now += 3_600
        XCTAssertEqual(harness.controller.zTarget, .nothing)
        for step in stride(from: 51, through: 2, by: -1) {
            XCTAssertEqual(editUndo(harness).title, step % 2 == 1 ? "Undo Star" : "Undo Unstar", "step \(step)")
            harness.controller.performEditUndo()
            XCTAssertEqual(try isStarred(id, harness), step % 2 == 0, "back to how step \(step - 1) left it")
        }
        XCTAssertEqual(editUndo(harness).title, "Can't Undo")
        XCTAssertFalse(editUndo(harness).enabled)
        XCTAssertTrue(try isStarred(id, harness), "the first step fell out of the history and stays")
    }

    /// The visible toast keeps its promise: ⌘Z reverts its step first, even when an older quiet step came after it, and the
    /// quiet one is next.
    func testTheVisibleToastStillComesFirst() throws {
        let clock = Clock()
        let harness = try harness(clock)
        defer { harness.close() }
        let ids = harness.list.conversations.prefix(3).map(\.id)
        select(ids[1], harness)
        XCTAssertTrue(harness.controller.perform(.archive))
        clock.now += 0.5
        harness.controller.handle(.star(ids[2], true))
        XCTAssertEqual(harness.toastMessage, "Archived")
        XCTAssertEqual(editUndo(harness).title, "Undo Archive")
        harness.controller.performEditUndo()
        XCTAssertTrue(try inInbox(ids[1], harness))
        XCTAssertEqual(editUndo(harness).title, "Undo Star")
    }

    // MARK: What can no longer be put back

    /// A step whose mail was deleted since is dropped when ⌘Z reaches it, and the next ⌘Z reaches the step behind it; a
    /// removed account's steps leave the history at once, its toast with them.
    func testStepsWhoseMailIsGoneGiveWayToTheOnesBehind() throws {
        let clock = Clock()
        let harness = try harness(clock)
        defer { harness.close() }
        let ids = harness.list.conversations.prefix(3).map(\.id)
        let (starredA, otherB, archivedA) = (ids[0], ids[1], ids[2])
        XCTAssertEqual(otherB.accountID, ListTestSupport.accountB.id)
        XCTAssertEqual(archivedA.accountID, ListTestSupport.accountA.id)

        select(archivedA, harness)
        XCTAssertTrue(harness.controller.perform(.archive))
        harness.toasts.dismiss()
        clock.now += 60
        // Thread 0 is starred: unstar it, then its mail is deleted for good elsewhere.
        harness.controller.handle(.star(starredA, false))
        clock.now += 60
        try store(harness).deleteMessages(try store(harness).messages(in: starredA).map(\.id))
        select(otherB, harness)
        XCTAssertTrue(harness.controller.perform(.archive))
        XCTAssertEqual(harness.toastMessage, "Archived")
        XCTAssertEqual(harness.controller.undoCenter.history.groups.count, 3)

        try store(harness).deleteAccount(ListTestSupport.accountB.id)
        harness.controller.refreshAccounts()
        XCTAssertEqual(harness.controller.undoCenter.history.groups.count, 2, "the removed account's step left the history")
        XCTAssertFalse(harness.toasts.isVisible, "and the toast offering it")
        clock.now += 3_600

        XCTAssertEqual(editUndo(harness).title, "Undo Unstar")
        harness.controller.performEditUndo()
        XCTAssertEqual(harness.controller.undoCenter.history.groups.count, 1, "nothing to put back: the step is dropped")
        XCTAssertTrue(try store(harness).messages(in: starredA).isEmpty, "and nothing comes back from nowhere")
        XCTAssertEqual(editUndo(harness).title, "Undo Archive")
        harness.controller.performEditUndo()
        XCTAssertTrue(try inInbox(archivedA, harness))
        XCTAssertEqual(editUndo(harness).title, "Can't Undo")
    }

    /// A step that is not a mail action (a snooze) whose conversation was deleted since: ⌘Z drops it without confirming
    /// anything or selecting a conversation that is gone, and the next ⌘Z reaches the step behind it.
    func testASnoozeWhoseConversationIsGoneGivesWayToTheStepBehind() throws {
        let clock = Clock()
        let harness = try harness(clock)
        defer { harness.close() }
        let ids = harness.list.conversations.prefix(3).map(\.id)
        let (starred, snoozed) = (ids[1], ids[2])
        XCTAssertFalse(try isStarred(starred, harness))
        harness.controller.handle(.star(starred, true))
        clock.now += 60
        harness.controller.snooze([snoozed], until: Date().addingTimeInterval(86_400))
        XCTAssertEqual(harness.controller.undoCenter.history.groups.count, 2)
        harness.toasts.dismiss()
        try store(harness).deleteMessages(try store(harness).messages(in: snoozed).map(\.id))
        clock.now += 3_600

        XCTAssertEqual(editUndo(harness).title, "Undo Snooze")
        harness.controller.performEditUndo()
        XCTAssertFalse(harness.toasts.isVisible, "nothing was put back, so nothing is confirmed")
        XCTAssertNotEqual(harness.list.selectedConversationID, snoozed, "and no emptied conversation is selected")
        XCTAssertEqual(editUndo(harness).title, "Undo Star")
        harness.controller.performEditUndo()
        XCTAssertFalse(try isStarred(starred, harness))
        XCTAssertEqual(harness.toastMessage, "Undid Star")
    }

    // MARK: Reader windows

    /// A step that closed its window, reached by ⌘Z long after: the conversation comes back selected in the main window,
    /// with the confirmation there, and no window springs up where the user left it.
    func testADeepUndoOfAWindowsStepComesBackInTheMainWindow() throws {
        let clock = Clock()
        let harness = try harness(clock)
        defer { harness.close() }
        let id = harness.list.conversations[1].id
        let other = harness.list.conversations[2].id
        let reader = try openInWindow(id, harness)
        XCTAssertTrue(reader.perform(.archive))
        XCTAssertTrue(harness.controller.readerWindows.isEmpty)
        XCTAssertEqual(harness.toastMessage, "Archived")
        harness.toasts.dismiss()
        clock.now += 60
        harness.controller.handle(.star(other, true))
        clock.now += 3_600

        harness.controller.performEditUndo()
        XCTAssertFalse(try isStarred(other, harness))
        XCTAssertEqual(editUndo(harness).title, "Undo Archive")
        harness.controller.performEditUndo()
        XCTAssertTrue(try inInbox(id, harness))
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "no window opens again for a step this old")
        XCTAssertEqual(harness.toastMessage, "Undid Archive", "the confirmation shows in the main window")
        harness.spin { harness.list.selectedConversationIDs == [id] }
        XCTAssertEqual(harness.list.selectedConversationIDs, [id], "the conversation comes back selected in the list")
        XCTAssertEqual(editUndo(harness).title, "Can't Undo")
    }

    /// Within the grace the same step's undo still opens its window again, as today.
    func testARecentUndoOfAWindowsStepStillOpensItAgain() throws {
        let clock = Clock()
        let harness = try harness(clock)
        defer { harness.close() }
        let id = harness.list.conversations[1].id
        let reader = try openInWindow(id, harness)
        XCTAssertTrue(reader.perform(.archive))
        harness.toasts.dismiss()
        clock.now += 5
        harness.controller.performEditUndo()
        XCTAssertTrue(try inInbox(id, harness))
        XCTAssertEqual(harness.controller.readerWindows.map(\.conversationID), [id])
    }

    /// A star taken in a window the user closed since: ⌘Z still reaches it, and its confirmation shows in the main window.
    /// One taken in a window still open is undone there, however old.
    func testAStarFromAWindowIsUndoneWhereverTheWindowIsNow() throws {
        let clock = Clock()
        let harness = try harness(clock)
        defer { harness.close() }
        let closed = harness.list.conversations[1].id
        let open = harness.list.conversations[2].id
        let first = try openInWindow(closed, harness)
        XCTAssertTrue(first.perform(.toggleStar))
        XCTAssertTrue(try isStarred(closed, harness))
        first.close()
        XCTAssertNil(first.place.window)
        clock.now += 60
        let second = try openInWindow(open, harness)
        XCTAssertTrue(second.perform(.toggleStar))
        clock.now += 3_600

        XCTAssertEqual(editUndo(harness).title, "Undo Star")
        harness.controller.performEditUndo()
        XCTAssertFalse(try isStarred(open, harness))
        XCTAssertEqual(second.toastView.slip?.message, "Undid Star", "undone in the window still showing it")
        let item = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        XCTAssertTrue(second.validateEditUndo(item), "the same history from the reader window")
        XCTAssertEqual(item.title, "Undo Star")
        second.performEditUndo()
        XCTAssertFalse(try isStarred(closed, harness))
        XCTAssertEqual(harness.toastMessage, "Undid Star", "the closed window's step confirms in the main window")
        XCTAssertEqual(harness.controller.readerWindows.map(\.conversationID), [open])
    }

    /// A window ↩ opened takes its steps into the one history, and Esc closing it, as ⌘W does, loses none of them and leaves
    /// no place holding the window: long after, ⌘Z from the main window walks back the window's star, confirming in the
    /// main window and opening nothing, and ⌘Z from a window a double-click opened reaches the main window's archive
    /// behind it (§5.49, §6.1).
    func testDeepUndoReachesStepsOfWindowsReturnOpenedAndEscClosed() throws {
        let clock = Clock()
        let harness = try harness(clock)
        defer { harness.close() }
        let ids = harness.list.conversations.prefix(4).map(\.id)
        // Threads 1 to 3 are not starred (every fifth is).
        let (archived, starred, other) = (ids[1], ids[2], ids[3])
        XCTAssertFalse(try isStarred(starred, harness))

        select(archived, harness)
        XCTAssertTrue(harness.controller.perform(.archive))
        harness.toasts.dismiss()
        clock.now += 3_600

        select(starred, harness)
        XCTAssertTrue(harness.controller.perform(.openInWindow), "↩ on the list")
        let reader = try XCTUnwrap(harness.controller.readerWindows.first { $0.conversationID == starred })
        XCTAssertTrue(reader.perform(.toggleStar))
        XCTAssertTrue(try isStarred(starred, harness))
        let star = try XCTUnwrap(harness.controller.undoCenter.history.latest?.id)
        let place = try XCTUnwrap(harness.controller.undoCenter.place(of: star).reader, "the window's step")
        XCTAssertTrue(place.window === reader)

        XCTAssertTrue(reader.perform(.clearSearch), "Esc, with nothing else in the window to close")
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "closes the window")
        XCTAssertNil(place.window, "the step's place lets go of it")
        XCTAssertEqual(harness.controller.undoCenter.history.groups.count, 2, "and the history keeps both steps")
        clock.now += 3_600

        XCTAssertEqual(editUndo(harness).title, "Undo Star")
        harness.controller.performEditUndo()
        XCTAssertFalse(try isStarred(starred, harness))
        XCTAssertEqual(harness.toastMessage, "Undid Star", "the closed window's step confirms in the main window")
        XCTAssertTrue(harness.controller.readerWindows.isEmpty, "a deep ⌘Z opens no window again")

        let index = try XCTUnwrap(harness.list.conversations.firstIndex { $0.id == other })
        harness.list.rowDoubleClicked(try XCTUnwrap(harness.list.layout.row(ofConversation: index)))
        let second = try XCTUnwrap(harness.controller.readerWindows.first { $0.conversationID == other }, "a double-click")
        let item = NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
        XCTAssertTrue(second.validateEditUndo(item))
        XCTAssertEqual(item.title, "Undo Archive", "the main window's step, from the new window")
        second.performEditUndo()
        XCTAssertTrue(try inInbox(archived, harness))
        XCTAssertEqual(harness.controller.readerWindows.map(\.conversationID), [other])
        XCTAssertEqual(editUndo(harness).title, "Can't Undo")
    }

    // MARK: Every way in

    /// A message's own star (its sheet's, More › Star Message) and More › Mark as Unread from Here are mail actions like S
    /// and U: no toast, and ⌘Z reaches them long after.
    func testAMessagesStarAndMarkUnreadFromHereJoinTheHistory() throws {
        let clock = Clock()
        let harness = try harness(clock)
        defer { harness.close() }
        // Thread 1 has two messages, read and not starred.
        let id = harness.list.conversations[1].id
        select(id, harness)
        harness.spin { harness.reader.currentConversationID == id && harness.reader.currentMessages.count == 2 && harness.reader.pool.current != nil }
        let messages = harness.reader.currentMessages.map(\.id)
        XCTAssertEqual(messages.count, 2)
        let target = messages[0]
        harness.reader.setTarget(target)

        let star = try XCTUnwrap(harness.reader.makeMoreMenu(for: target, shellState: [:]).items.first { $0.title.hasPrefix("Star Message") })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(star.action), to: star.target, from: star))
        XCTAssertEqual(try store(harness).message(target)?.isStarred, true)
        XCTAssertEqual(try store(harness).message(messages[1])?.isStarred, false, "only that message")
        XCTAssertFalse(harness.toasts.isVisible, "the sheet and the row show it")
        clock.now += 60

        let unread = try XCTUnwrap(harness.reader.makeMoreMenu(for: target, shellState: [:]).items.first { $0.title == "Mark as Unread from Here" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(unread.action), to: unread.target, from: unread))
        XCTAssertEqual(try messages.map { try store(harness).message($0)?.isRead }, [false, false])
        clock.now += 3_600

        XCTAssertEqual(editUndo(harness).title, "Undo Mark as Unread")
        harness.controller.performEditUndo()
        XCTAssertEqual(try messages.map { try store(harness).message($0)?.isRead }, [true, true])
        XCTAssertEqual(editUndo(harness).title, "Undo Star")
        harness.controller.performEditUndo()
        XCTAssertEqual(try store(harness).message(target)?.isStarred, false)
        XCTAssertEqual(editUndo(harness).title, "Can't Undo")
    }
}
