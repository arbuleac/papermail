import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// Several selected conversations end to end (spec §5.19, §5.12): the reader's selection state, keys and
/// header actions on all of them with one coalesced toast and one undo, and replies doing nothing.
@MainActor
final class MainWindowSelectionTests: XCTestCase {
    func testSeveralSelectedShowTheReadersSelectionState() throws {
        let harness = try MainWindowHarness()
        harness.selectFirst(3)
        let ids = Array(harness.list.conversations.prefix(3).map(\.id))
        XCTAssertEqual(harness.reader.selection, .several(ids))
        XCTAssertEqual(ConversationViewController.severalSentence(3), "Three conversations, one keystroke.")
        // j collapses back to one conversation, which the reader shows.
        _ = harness.controller.perform(.next)
        XCTAssertEqual(harness.reader.selection, .one(harness.list.conversations[3].id))
        harness.close()
    }

    func testArchivingSeveralMakesOneToastAndOneUndo() throws {
        let harness = try MainWindowHarness()
        harness.selectFirst(3)
        let ids = Array(harness.list.conversations.prefix(3).map(\.id))
        XCTAssertTrue(harness.controller.perform(.archive))
        XCTAssertEqual(harness.toastMessage, "Archived 3 conversations")
        harness.spin { !harness.list.conversations.contains { ids.contains($0.id) } }
        XCTAssertFalse(harness.list.conversations.contains { ids.contains($0.id) })
        XCTAssertEqual(harness.controller.zTarget, harness.controller.commandZTarget(textCanUndo: false))
        // One Z brings all three back, selected.
        XCTAssertTrue(harness.controller.perform(.undo))
        harness.spin { ids.allSatisfy { id in harness.list.conversations.contains { $0.id == id } } }
        XCTAssertEqual(harness.list.selectedConversationIDs, ids)
        XCTAssertEqual(harness.toastMessage, "Undid Archive")
        XCTAssertEqual(harness.controller.zTarget, .nothing, "nothing left to undo")
        harness.close()
    }

    func testHeaderActionsApplyToTheWholeSelection() throws {
        let harness = try MainWindowHarness()
        harness.selectFirst(2)
        let ids = Array(harness.list.conversations.prefix(2).map(\.id))
        harness.controller.handle(.applyToSelection(.trash, ids))
        XCTAssertEqual(harness.toastMessage, "Moved 2 conversations to Trash")
        harness.spin { !harness.list.conversations.contains { ids.contains($0.id) } }
        XCTAssertFalse(harness.list.conversations.contains { ids.contains($0.id) })
        let trashed = try ids.allSatisfy { try harness.environment.store.messages(in: $0).allSatisfy { $0.roles.contains(.trash) } }
        XCTAssertTrue(trashed)
        harness.close()
    }

    func testStarFollowsTheAllStarredRule() throws {
        let harness = try MainWindowHarness()
        // Thread 0 is starred (every fifth is), 1 and 2 are not: S stars all, then unstars all.
        harness.selectFirst(3)
        let ids = Array(harness.list.conversations.prefix(3).map(\.id))
        XCTAssertTrue(harness.controller.perform(.toggleStar))
        harness.spin { harness.list.conversations.prefix(3).allSatisfy(\.isStarred) }
        XCTAssertTrue(harness.list.conversations.filter { ids.contains($0.id) }.allSatisfy(\.isStarred))
        // Thread 0 was starred already, so two rows changed.
        XCTAssertEqual(harness.toastMessage, "Starred 2 conversations", "changing several rows at once gets a toast")
        XCTAssertTrue(harness.controller.perform(.toggleStar))
        harness.spin { !harness.list.conversations.prefix(3).contains(where: \.isStarred) }
        XCTAssertFalse(harness.list.conversations.filter { ids.contains($0.id) }.contains(where: \.isStarred))
        harness.close()
    }

    func testRepliesDoNothingWithSeveralSelected() throws {
        let harness = try MainWindowHarness()
        harness.selectFirst(2)
        let before = ComposeWindowRegistry.shared.openControllers.count
        XCTAssertTrue(harness.controller.perform(.reply), "the key is spent")
        XCTAssertTrue(harness.controller.perform(.forward))
        XCTAssertEqual(ComposeWindowRegistry.shared.openControllers.count, before)
        let item = NSMenuItem(title: "Reply", action: #selector(MainWindowController.replyToSelection(_:)), keyEquivalent: "")
        XCTAssertFalse(harness.controller.validateMenuItem(item))
        harness.close()
    }
}

/// One undo history for the main window (spec §6.1): Edit › Undo is titled by its target, and the composer's
/// “Draft discarded” toast joins the same order as the mail actions.
@MainActor
final class MainWindowUndoTests: XCTestCase {
    private func editUndoItem() -> NSMenuItem {
        NSMenuItem(title: "Undo", action: NSSelectorFromString("undo:"), keyEquivalent: "z")
    }

    func testEditUndoIsTitledByItsTarget() throws {
        let harness = try MainWindowHarness()
        let item = editUndoItem()
        XCTAssertFalse(harness.controller.validateEditUndo(item))
        XCTAssertEqual(item.title, "Can't Undo")
        harness.selectFirst(1)
        XCTAssertTrue(harness.controller.perform(.archive))
        XCTAssertTrue(harness.controller.validateEditUndo(item))
        XCTAssertEqual(item.title, "Undo Archive")
        let message = NSMenuItem(title: "Undo", action: #selector(MainWindowController.undoMailAction(_:)), keyEquivalent: "z")
        harness.controller.window?.makeFirstResponder(nil)
        XCTAssertTrue(harness.controller.validateMenuItem(message))
        XCTAssertEqual(message.title, "Undo Archive")
        // Esc dismisses the toast; Z keeps reaching its action for the grace period.
        harness.toasts.dismiss()
        XCTAssertTrue(harness.controller.validateEditUndo(item))
        harness.controller.performEditUndo()
        XCTAssertEqual(harness.toastMessage, "Undid Archive")
        harness.close()
    }

    func testTheDraftDiscardedToastIsInTheSameHistory() throws {
        let harness = try MainWindowHarness()
        var reopened = 0
        let undo = ComposeDraftUndo { reopened += 1 }
        NotificationCenter.default.post(name: ComposeWindowController.draftDiscardedNotification, object: nil,
                                        userInfo: [ComposeWindowController.draftUndoKey: undo])
        XCTAssertEqual(harness.toastMessage, "Draft discarded")
        let item = editUndoItem()
        XCTAssertTrue(harness.controller.validateEditUndo(item))
        XCTAssertEqual(item.title, "Undo Discard Draft")
        XCTAssertTrue(harness.controller.perform(.undo), "Z reaches it")
        XCTAssertEqual(reopened, 1)
        XCTAssertEqual(harness.controller.zTarget, .nothing)
        harness.close()
    }
}
