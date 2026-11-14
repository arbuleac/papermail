import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// A two-finger swipe on a row (spec §5.7, Swipe): Archive on the trailing edge and Mark as Read or Unread on the
/// leading one, each the key's change (E, U) on that one row through the key's path (store first, queued, the toast,
/// coalescing and Undo), offered only where the key would change the row; the same actions for VoiceOver.
///
/// No test can move fingers on a trackpad, so the table's delegate is asked for its buttons as AppKit asks, and a
/// button is pressed by calling the handler AppKit calls for a click or a swipe carried across the row.
@MainActor
final class SwipeToArchiveTests: XCTestCase {
    // MARK: Helpers

    private func actions(forConversation index: Int, edge: NSTableView.RowActionEdge,
                         in harness: MainWindowHarness) throws -> [NSTableViewRowAction] {
        let list = harness.list
        let row = try XCTUnwrap(list.layout.row(ofConversation: index))
        return list.tableView(list.tableView, rowActionsForRow: row, edge: edge)
    }

    private func action(forConversation index: Int, edge: NSTableView.RowActionEdge, in harness: MainWindowHarness,
                        file: StaticString = #filePath, line: UInt = #line) throws -> NSTableViewRowAction {
        let offered = try actions(forConversation: index, edge: edge, in: harness)
        XCTAssertEqual(offered.count, 1, "one button per edge", file: file, line: line)
        return try XCTUnwrap(offered.first, file: file, line: line)
    }

    /// What AppKit does when the button is clicked or the swipe is carried across the row. The handler is not public
    /// API; AppKit keeps it behind `_handler`, which key-value coding reaches.
    private func press(_ action: NSTableViewRowAction, row: Int = 0) throws {
        guard action.responds(to: NSSelectorFromString("_handler")) else {
            throw XCTSkip("this AppKit keeps a row action's handler elsewhere")
        }
        typealias Handler = @convention(block) (NSTableViewRowAction, Int) -> Void
        let block = try XCTUnwrap(action.value(forKey: "handler") as AnyObject?)
        unsafeBitCast(block, to: Handler.self)(action, row)
    }

    private func cell(forConversation index: Int, in harness: MainWindowHarness) throws -> ConversationCellView {
        let row = try XCTUnwrap(harness.list.layout.row(ofConversation: index))
        return try XCTUnwrap(harness.list.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ConversationCellView)
    }

    private func inInbox(_ id: ConversationID, _ harness: MainWindowHarness) throws -> Bool {
        try harness.environment.store.messages(in: id).contains(where: \.isInInbox)
    }

    private func queued(_ change: MetadataChange, _ harness: MainWindowHarness) throws -> Set<MessageID> {
        let store = harness.environment.store
        let all = try [ListTestSupport.accountA.id, ListTestSupport.accountB.id].flatMap { try store.pendingOperations(accountID: $0, limit: 100) }
        return Set(all.filter { $0.change == change }.flatMap(\.targets))
    }

    private func select(_ id: ConversationID, _ harness: MainWindowHarness) {
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
    }

    // MARK: Archive

    func testATrailingSwipeArchivesTheRowAsEDoes() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        select(harness.list.conversations[0].id, harness)
        let id = harness.list.conversations[2].id
        let archive = try action(forConversation: 2, edge: .trailing, in: harness)
        XCTAssertEqual(archive.title, "Archive", "the menu's command, a verb (§4.13)")
        XCTAssertEqual(archive.style, .regular, "no destructive animation: the list never animates a row leaving")
        XCTAssertEqual(archive.backgroundColor, .controlAccentColor, "a native control on the app's accent asset (§3.1)")

        try press(archive)
        XCTAssertFalse(try inInbox(id, harness), "archived in the store at once")
        let wanted = Set(try harness.environment.store.messages(in: id).map(\.id))
        XCTAssertTrue(wanted.isSubset(of: try queued(.archive, harness)), "and queued for the engine")
        XCTAssertEqual(harness.toastMessage, "Archived", "E's toast")
        let undo = try XCTUnwrap(harness.controller.listPane.toastView.slip?.actionButton)
        XCTAssertEqual(undo.title, "Undo")
        XCTAssertEqual(undo.keycap, "Z")
        harness.spin { !harness.list.conversations.contains { $0.id == id } }
        XCTAssertFalse(harness.list.conversations.contains { $0.id == id }, "the row leaves the Inbox")
        XCTAssertEqual(harness.list.selectedConversationID, harness.list.conversations[0].id,
                       "a swipe acts on its own row and leaves the selection where it was")

        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(undo.action), to: undo.target, from: undo), "the toast's Undo")
        XCTAssertTrue(try inInbox(id, harness), "Undo brings the mail back")
        XCTAssertEqual(harness.toastMessage, "Undid Archive")
        harness.spin { harness.list.conversations.contains { $0.id == id } }
        XCTAssertEqual(harness.list.selectedConversationID, id, "and selects it, as an undo of E does")
    }

    func testSwipingTheSelectedRowMovesTheSelectionOnAsE() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[1].id
        let next = harness.list.conversations[2].id
        select(id, harness)
        try press(try action(forConversation: 1, edge: .trailing, in: harness))
        harness.spin { harness.list.selectedConversationID != id }
        XCTAssertEqual(harness.list.selectedConversationID, next, "the row below takes the selection")
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Archive", "Z reaches it")
    }

    /// Several swipes within the coalescing window are one step, as several presses of E are (§5.30).
    func testSwipesInQuickSuccessionAreOneToastAndOneUndo() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let ids = [harness.list.conversations[1].id, harness.list.conversations[3].id]
        let first = try action(forConversation: 1, edge: .trailing, in: harness)
        let second = try action(forConversation: 3, edge: .trailing, in: harness)
        try press(first)
        try press(second)
        XCTAssertEqual(harness.toastMessage, "Archived 2 conversations")
        harness.spin { !harness.list.conversations.contains { ids.contains($0.id) } }
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertTrue(try ids.allSatisfy { try inInbox($0, harness) }, "one Z brings both back")
    }

    /// The button keys to its conversation: a refresh that moves the row between the reveal and the click archives
    /// the conversation the button was shown on, never whatever row now has its number.
    func testTheButtonActsOnItsConversationAfterRowsMove() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[3].id
        let archive = try action(forConversation: 3, edge: .trailing, in: harness)
        try harness.environment.engine.perform(.archive, on: harness.list.conversations[0].id)
        harness.spin { harness.list.conversations.firstIndex { $0.id == id } == 2 }
        try press(archive, row: 3)
        XCTAssertFalse(try inInbox(id, harness))
        XCTAssertTrue(try inInbox(harness.list.conversations[3].id, harness), "the row now fourth is left alone")
    }

    // MARK: Where E would change nothing

    func testTheTrashOffersNoArchive() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[0].id
        try harness.environment.engine.perform(.trash, on: id)
        XCTAssertTrue(harness.controller.perform(.goTo(.trash)))
        harness.spin { harness.list.query.view == .trash && harness.list.conversations.contains { $0.id == id } }
        let index = try XCTUnwrap(harness.list.conversations.firstIndex { $0.id == id })
        XCTAssertEqual(try actions(forConversation: index, edge: .trailing, in: harness), [], "E beeps there, so no button")
        XCTAssertEqual(try actions(forConversation: index, edge: .leading, in: harness).count, 1, "U works in the Trash")
        XCTAssertEqual(try cell(forConversation: index, in: harness).accessibilityCustomActions()?.map(\.name),
                       [try action(forConversation: index, edge: .leading, in: harness).title], "nor for VoiceOver")
    }

    func testHeadsAndTheTailOfferNothing() throws {
        let harness = try MainWindowHarness(threads: 40)
        defer { harness.close() }
        let list = harness.list
        let others = list.layout.items.indices.filter { list.layout.conversationIndex(atRow: $0) == nil }
        XCTAssertFalse(others.isEmpty, "a running head at least")
        for row in others {
            for edge in [NSTableView.RowActionEdge.leading, .trailing] {
                XCTAssertEqual(list.tableView(list.tableView, rowActionsForRow: row, edge: edge), [], "row \(row)")
            }
        }
    }

    /// In Later E ends the snooze and leaves the mail archived; the swipe's Archive does the same.
    func testInLaterArchiveEndsTheSnooze() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[1].id
        let store = harness.environment.store
        let targets = try store.messages(in: id).filter(\.isInInbox).map(\.id)
        try store.setSnoozes([Snooze.Change(conversationID: id, until: Date().addingTimeInterval(86_400))],
                             enqueueing: [SSCore.Operation(accountID: id.accountID, change: .archive, targets: targets)], at: Date())
        harness.spin { harness.controller.snoozes.count == 1 }
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.query.view == .later && harness.list.conversations.count == 1 }

        let archive = try action(forConversation: 0, edge: .trailing, in: harness)
        XCTAssertEqual(archive.title, "Archive")
        try press(archive)
        XCTAssertEqual(try store.snoozes().count, 0, "the snooze ends")
        XCTAssertFalse(try inInbox(id, harness), "and the mail stays archived")
        XCTAssertEqual(harness.toastMessage, "Archived", "E's toast in Later")
        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [id], "Undo puts the snooze back")
    }

    // MARK: Read and unread

    func testALeadingSwipeMarksReadOrUnreadAsUDoes() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        // Every third thread is unread: the first is, the second is not.
        let unread = harness.list.conversations[0]
        let read = harness.list.conversations[1]
        XCTAssertGreaterThan(unread.unreadCount, 0)
        XCTAssertEqual(read.unreadCount, 0)

        let markRead = try action(forConversation: 0, edge: .leading, in: harness)
        XCTAssertEqual(markRead.title, "Mark as Read")
        XCTAssertEqual(try action(forConversation: 1, edge: .leading, in: harness).title, "Mark as Unread")
        try press(markRead)
        XCTAssertTrue(try harness.environment.store.messages(in: unread.id).allSatisfy(\.isRead), "read in the store at once")
        XCTAssertNil(harness.toastMessage, "as with U, the row itself shows the change")
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Mark as Read", "Z still reaches it")
        harness.spin { harness.list.conversations.first { $0.id == unread.id }?.unreadCount == 0 }
        XCTAssertEqual(try action(forConversation: 0, edge: .leading, in: harness).title, "Mark as Unread", "the button follows the row")
    }

    // MARK: Scrolling

    /// The swipe is the table's own handling of a sideways scroll, so the list must still scroll up and down, and a
    /// sideways scroll that is no swipe (a wheel's tilt) must not move it sideways.
    func testTheListStillScrollsAndNeverSideways() throws {
        let harness = try MainWindowHarness(threads: 40)
        defer { harness.close() }
        let list = harness.list
        let clip = list.scrollView.contentView
        XCTAssertGreaterThan(list.tableView.bounds.height, clip.bounds.height, "a list taller than its pane")
        func wheel(dx: Int32, dy: Int32) throws -> NSEvent {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0))
            event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            return try XCTUnwrap(NSEvent(cgEvent: event))
        }
        list.tableView.scrollWheel(with: try wheel(dx: -80, dy: 0))
        XCTAssertEqual(clip.bounds.origin.x, 0, "never sideways")
        XCTAssertEqual(clip.bounds.origin.y, 0)
        list.tableView.scrollWheel(with: try wheel(dx: 0, dy: -120))
        harness.spin { clip.bounds.origin.y > 0 }
        XCTAssertGreaterThan(clip.bounds.origin.y, 0, "down the list")
        XCTAssertEqual(clip.bounds.origin.x, 0)
    }

    // MARK: VoiceOver

    func testTheRowsVoiceOverActionsAreTheSwipes() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[1].id
        let actions = try XCTUnwrap(try cell(forConversation: 1, in: harness).accessibilityCustomActions())
        XCTAssertEqual(actions.map(\.name), ["Archive", "Mark as Unread"], "Archive first")
        XCTAssertEqual(actions[0].handler?(), true)
        XCTAssertFalse(try inInbox(id, harness), "archived through E's path")
        XCTAssertEqual(harness.toastMessage, "Archived")
    }

    /// The list on its own, with no host to apply them, offers neither a swipe nor a VoiceOver action.
    func testAListWithoutAHostOffersNothing() throws {
        let store = try ListTestSupport.store(threads: 6)
        let (list, _) = ListTestSupport.host(store: store, settings: ListTestSupport.settings())
        let row = try XCTUnwrap(list.layout.row(ofConversation: 0))
        XCTAssertEqual(list.tableView(list.tableView, rowActionsForRow: row, edge: .trailing), [])
        let cell = try XCTUnwrap(list.tableView.view(atColumn: 0, row: row, makeIfNecessary: true) as? ConversationCellView)
        XCTAssertNil(cell.accessibilityCustomActions())
    }
}
