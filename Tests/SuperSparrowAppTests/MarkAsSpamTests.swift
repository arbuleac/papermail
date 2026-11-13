import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// Mark as spam (roadmap Q2.3, spec “Mark as spam”): ! routed as # is, Message › Mark as Spam and the context menu's
/// item, the cheat sheet's row, the rows leaving the list with a toast and an undo that brings them back where they were
/// (to Later, snoozed as before, and under Today with their Back tag), and nothing done in the Trash and Drafts.
@MainActor
final class MarkAsSpamTests: XCTestCase {
    private func messages(_ id: ConversationID, _ harness: MainWindowHarness) throws -> [MessageMetadata] {
        try harness.environment.store.messages(in: id)
    }

    private func queued(_ account: AccountID, _ harness: MainWindowHarness) throws -> [MetadataChange] {
        try harness.environment.store.pendingOperations(accountID: account, limit: 100).map(\.change)
    }

    private func select(_ id: ConversationID, _ harness: MainWindowHarness) {
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
    }

    private func listed(_ id: ConversationID, _ harness: MainWindowHarness) -> Bool {
        harness.list.conversations.contains { $0.id == id }
    }

    private var menuItem: NSMenuItem {
        NSMenuItem(title: "Mark as Spam", action: #selector(MainWindowController.markSelectionSpam(_:)), keyEquivalent: "!")
    }

    // MARK: Keys and menus

    func testBangIsRoutedAsHashIs() {
        func command(_ characters: String, _ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags, reader: Bool = false) -> KeyCommand? {
            KeyboardRouter.command(characters: characters, keyCode: keyCode, modifiers: modifiers, pendingG: false, readerFocused: reader).command
        }
        XCTAssertEqual(command("!", 18, .shift), .markSpam, "⇧1 on a US layout")
        XCTAssertEqual(command("!", 30, []), .markSpam, "read from the character, so a layout with ! on a key of its own works")
        XCTAssertEqual(command("!", 18, .shift, reader: true), .markSpam, "with focus in the reader too")
        XCTAssertNil(command("!", 18, [.command, .shift]), "⇧⌘1 is not it")
        XCTAssertEqual(command("1", 18, []), nil, "nor is a plain 1")
        XCTAssertNil(KeyboardRouter.sequenceView(characters: "!"), "there is no Spam view to go to")
    }

    /// Message › Mark as Spam ! sits after Move to Trash with its symbol; the cheat sheet lists ! after # in Act, which
    /// keeps nine rows by handing “Show · hide quoted text” to View, where its menu item lives.
    func testTheMessageMenuAndTheCheatSheetCarryIt() throws {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        let message = try XCTUnwrap(bar.items.first { $0.submenu?.title == "Message" }?.submenu)
        let trash = try XCTUnwrap(message.items.firstIndex { $0.action == #selector(MainWindowController.trashSelection(_:)) })
        let spam = message.items[trash + 1]
        XCTAssertEqual(spam.title, "Mark as Spam")
        XCTAssertEqual(spam.action, #selector(MainWindowController.markSelectionSpam(_:)))
        XCTAssertEqual(spam.keyEquivalent, "!")
        XCTAssertEqual(spam.keyEquivalentModifierMask, [])
        XCTAssertNotNil(spam.image, "with its symbol")
        XCTAssertEqual(Quire.Icon.spam, "xmark.bin")

        let act = try XCTUnwrap(Quire.cheatSheet.first { $0.title == "Act" }?.rows)
        let hash = try XCTUnwrap(act.firstIndex { $0.keys == "#" })
        XCTAssertEqual(act[hash + 1].keys, "!")
        XCTAssertEqual(act[hash + 1].label, "Mark as spam")
        XCTAssertEqual(act.count, 9, "the first band keeps its height, so the sheet still fits the default window whole")
        let view = try XCTUnwrap(Quire.cheatSheet.first { $0.title == "View" }?.rows)
        XCTAssertTrue(view.contains { $0.keys == "." && $0.label == "Show · hide quoted text" })
    }

    func testTheContextMenuOffersItAfterMoveToTrash() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[0].id
        select(id, harness)
        let menu = harness.controller.selectionContextMenu()
        menu.update()
        let trash = try XCTUnwrap(menu.items.firstIndex { $0.title == "Move to Trash" })
        let item = menu.items[trash + 1]
        XCTAssertEqual(item.title, "Mark as Spam")
        XCTAssertEqual(item.keyEquivalent, "!")
        XCTAssertNotNil(item.image)
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        XCTAssertTrue(try messages(id, harness).allSatisfy { $0.roles == [.spam] })
        XCTAssertEqual(harness.toastMessage, "Marked as spam")
    }

    // MARK: Acting

    /// Store first and queued, the row leaves, the toast offers Undo, and Z brings it back to the Inbox, selected.
    func testBangMarksTheSelectionAsSpamAndZBringsItBack() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[1].id
        XCTAssertEqual(harness.controller.accounts.first { $0.id == id.accountID }?.kind, .microsoft)
        select(id, harness)
        XCTAssertTrue(harness.controller.validateMenuItem(menuItem))

        XCTAssertTrue(harness.controller.perform(.markSpam))
        XCTAssertTrue(try messages(id, harness).allSatisfy { $0.roles == [.spam] }, "applied before anything reaches the network")
        XCTAssertEqual(try queued(id.accountID, harness).last, .markSpam)
        XCTAssertEqual(harness.toastMessage, "Marked as spam")
        harness.spin { !self.listed(id, harness) }
        XCTAssertFalse(listed(id, harness))
        XCTAssertNotEqual(harness.list.selectedConversationID, id, "the selection moves on, as after #")
        XCTAssertEqual(harness.controller.undoMenuTitle(for: harness.controller.zTarget), "Undo Mark as Spam")

        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertEqual(harness.toastMessage, "Undid Mark as Spam")
        XCTAssertTrue(try messages(id, harness).allSatisfy { $0.roles == [.inbox] })
        XCTAssertEqual(try queued(id.accountID, harness).suffix(2), [.markSpam, .markNotSpam])
        harness.spin { self.listed(id, harness) }
        XCTAssertEqual(harness.list.selectedConversationIDs, [id], "back, and selected")
    }

    func testSeveralSelectedMakeOneToastAndOneUndo() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.selectFirst(3)
        let ids = harness.list.selectedConversationIDs
        XCTAssertEqual(ids.count, 3)
        XCTAssertTrue(harness.controller.perform(.markSpam))
        XCTAssertEqual(harness.toastMessage, "Marked 3 as spam")
        harness.spin { ids.allSatisfy { !self.listed($0, harness) } }
        XCTAssertTrue(harness.controller.perform(.undo))
        harness.spin { ids.allSatisfy { self.listed($0, harness) } }
        XCTAssertTrue(ids.allSatisfy(harness.list.selectedConversationIDs.contains))
        for id in ids { XCTAssertTrue(try messages(id, harness).allSatisfy(\.isInInbox)) }
    }

    /// From an archived conversation (All Mail), the undo puts it back in the archive, not the Inbox.
    func testTheUndoPutsArchivedMailBackInTheArchive() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[2].id
        try harness.environment.engine.perform(.archive, on: id)
        XCTAssertTrue(harness.controller.perform(.goTo(.all)))
        harness.spin { harness.list.query.view == .all && self.listed(id, harness) }
        select(id, harness)
        XCTAssertTrue(harness.controller.perform(.markSpam))
        harness.spin { !self.listed(id, harness) }
        XCTAssertTrue(harness.controller.perform(.undo))
        harness.spin { self.listed(id, harness) }
        XCTAssertTrue(try messages(id, harness).allSatisfy { $0.roles.isEmpty }, "archived again, out of Spam and the Inbox")
    }

    /// The Trash and Drafts take no Mark as Spam: the menu items are disabled and ! beeps, changing nothing.
    func testNothingIsMarkedAsSpamFromTheTrashOrDrafts() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[0].id
        try harness.environment.engine.perform(.trash, on: id)
        XCTAssertTrue(harness.controller.perform(.goTo(.trash)))
        harness.spin { self.listed(id, harness) }
        select(id, harness)
        XCTAssertFalse(harness.controller.validateMenuItem(menuItem), "disabled in the Trash")
        let before = try queued(id.accountID, harness)
        XCTAssertTrue(harness.controller.perform(.markSpam), "the key is spent, with a beep")
        XCTAssertEqual(try queued(id.accountID, harness), before)
        XCTAssertTrue(try messages(id, harness).allSatisfy { $0.roles == [.trash] })

        XCTAssertTrue(harness.controller.perform(.goTo(.drafts)))
        harness.spin { harness.list.query.view == .drafts }
        XCTAssertFalse(harness.controller.validateMenuItem(menuItem))
    }

    // MARK: Later

    func testInLaterTheSnoozeEndsAndUndoPutsItBack() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let store = harness.environment.store
        let id = harness.list.conversations[0].id
        let targets = try messages(id, harness).filter(\.isInInbox).map(\.id)
        try store.setSnoozes([Snooze.Change(conversationID: id, until: Date().addingTimeInterval(86_400))],
                             enqueueing: [SSCore.Operation(accountID: id.accountID, change: .archive, targets: targets)], at: Date())
        harness.spin { harness.controller.snoozes.count == 1 }
        XCTAssertTrue(harness.controller.perform(.goTo(.later)))
        harness.spin { harness.list.query.view == .later && self.listed(id, harness) }
        select(id, harness)

        XCTAssertTrue(harness.controller.perform(.markSpam))
        XCTAssertEqual(harness.toastMessage, "Marked as spam")
        XCTAssertTrue(try store.snoozes().isEmpty, "out of Later: nothing would come back")
        harness.spin { harness.list.query.view == .inbox }

        XCTAssertTrue(harness.controller.perform(.undo))
        XCTAssertEqual(try store.snoozes().map(\.conversationID), [id], "snoozed as before")
        XCTAssertTrue(try messages(id, harness).allSatisfy { $0.roles.isEmpty }, "archived, out of Spam")
        harness.spin { harness.list.query.view == .later }
        XCTAssertEqual(harness.list.query.view, .later)
    }

    /// A conversation back from Later loses its place under Today as it leaves the Inbox; Z puts it back there.
    func testAnUndoPutsAReturnedRowBackUnderToday() throws {
        let harness = try MainWindowHarness(threads: 10, spacing: 86_400)
        defer { harness.close() }
        let store = harness.environment.store
        let old = harness.list.conversations[8].id
        let targets = try messages(old, harness).map(\.id)
        try store.setSnoozes([Snooze.Change(conversationID: old, until: Date().addingTimeInterval(-60))],
                             enqueueing: [SSCore.Operation(accountID: old.accountID, change: .archive, targets: targets)],
                             at: Date().addingTimeInterval(-600))
        let now = Date()
        try store.returnDueSnoozes(at: now, limit: 10) { id, messages in
            [SSCore.Operation(accountID: id.accountID, change: .moveToInbox, targets: messages.map(\.id), createdAt: now)]
        }
        harness.spin { harness.list.conversations.first?.id == old }
        let mark = try XCTUnwrap(harness.list.conversations.first?.returnedAt)
        // Selected without opening, as a drop would act, so the row stays as it came back.
        harness.list.selectedConversationID = old

        XCTAssertTrue(harness.controller.perform(.markSpam))
        harness.spin { harness.list.conversations.first?.id != old }
        XCTAssertTrue(harness.controller.perform(.undo))
        harness.spin { harness.list.conversations.first?.id == old }
        XCTAssertEqual(harness.list.conversations.first?.id, old, "back first")
        XCTAssertEqual(harness.list.conversations.first?.returnedAt, mark, "with its mark")
    }
}
