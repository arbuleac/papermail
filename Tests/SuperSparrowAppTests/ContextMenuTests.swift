import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// The context menu on rows and messages (spec §5.35): the Message menu's commands for the selection, a
/// right-click outside the selection selecting first, items that do not apply visible but disabled; and the
/// Trash rules of §5.12.
@MainActor
final class ContextMenuTests: XCTestCase {
    private func titles(_ menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
    }

    func testARightClickedRowIsSelectedAndTheMenuActsOnTheSelection() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.selectFirst(1)
        let second = harness.list.conversations[1].id
        let row = try XCTUnwrap(harness.list.layout.row(ofConversation: 1))
        let menu = try XCTUnwrap(harness.list.contextMenu(forRow: row))
        XCTAssertEqual(harness.list.selectedConversationIDs, [second], "a right-click outside the selection selects that row")
        menu.update()
        XCTAssertEqual(titles(menu), ["Reply", "Reply All", "Forward", "—", "Archive", menu.items[5].title, "Mark as Unread",
                                      "Move to Inbox", "—", "Move to Trash"])
        XCTAssertTrue(["Star", "Unstar"].contains(menu.items[5].title))
        XCTAssertTrue(menu.items.allSatisfy { $0.isSeparatorItem || $0.image != nil }, "every item has its symbol")
        XCTAssertEqual(menu.items[4].keyEquivalent, "e", "and its shortcut")
        let moveToInbox = try XCTUnwrap(menu.items.first { $0.title == "Move to Inbox" })
        XCTAssertFalse(moveToInbox.isEnabled, "already in the Inbox: shown, disabled")
        XCTAssertTrue(try XCTUnwrap(menu.items.first { $0.title == "Archive" }).isEnabled)

        // A right-click inside a several-row selection keeps it; replies do not apply to several.
        harness.selectFirst(3)
        let several = harness.list.selectedConversationIDs
        let inside = try XCTUnwrap(harness.list.layout.row(ofConversation: 1))
        let severalMenu = try XCTUnwrap(harness.list.contextMenu(forRow: inside))
        XCTAssertEqual(harness.list.selectedConversationIDs, several)
        severalMenu.update()
        XCTAssertFalse(try XCTUnwrap(severalMenu.items.first { $0.title == "Reply" }).isEnabled)
    }

    func testRunningHeadsHaveNoMenu() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        guard let head = harness.list.layout.items.firstIndex(where: { if case .head = $0 { return true } else { return false } }) else {
            throw XCTSkip("no running head in this mailbox")
        }
        XCTAssertNil(harness.list.contextMenu(forRow: head))
    }

    func testMoveToTrashDoesNothingInTrash() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let first = harness.list.conversations[0].id
        try harness.environment.engine.perform(.trash, on: first)
        _ = harness.controller.perform(.goTo(.trash))
        harness.spin { harness.list.conversations.contains { $0.id == first } }
        harness.list.selectedConversationID = first
        harness.list.onSelectionChange?(first)
        let trash = NSMenuItem(title: "Move to Trash", action: #selector(MainWindowController.trashSelection(_:)), keyEquivalent: "#")
        XCTAssertFalse(harness.controller.validateMenuItem(trash), "Message › Move to Trash is disabled in Trash")
        let before = try harness.environment.store.pendingOperations(accountID: first.accountID, limit: 100).count
        XCTAssertTrue(harness.controller.perform(.trash), "# is spent, quietly")
        XCTAssertEqual(try harness.environment.store.pendingOperations(accountID: first.accountID, limit: 100).count, before)
    }
}
