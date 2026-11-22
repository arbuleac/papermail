import AppKit
import PaperCore
import XCTest
@testable import PaperApp

/// Multi-selection in the list (spec §3.4, §5.7): ⇧J / ⇧K grow and give back rows around where they started,
/// and the selection is kept by id across refreshes, paging and rows that leave.
@MainActor
final class MessageListMultiSelectionTests: XCTestCase {
    private typealias Support = ListTestSupport

    private func hostMulti(threads: Int = 12) throws -> (MessageListViewController, NSWindow, InMemoryMailStore) {
        let store = try Support.store(threads: threads, spacing: 600)
        let (list, window) = Support.host(store: store, settings: Support.settings())
        list.allowsMultipleSelection = true
        return (list, window, store)
    }

    /// Applies `change` the way the engine does: one queued operation per account, applied to the store.
    private func apply(_ change: MetadataChange, to ids: [ConversationID], in store: InMemoryMailStore) throws {
        let messages = try ids.flatMap { try store.messages(in: $0) }.map(\.id)
        for (account, targets) in Dictionary(grouping: messages, by: \.accountID) {
            try store.enqueue(Operation(accountID: account, change: change, targets: targets))
        }
    }

    func testShiftJGrowsAndShiftKGivesBackRows() throws {
        let (list, _, _) = try hostMulti()
        let ids = list.conversations.map(\.id)
        var sets: [[ConversationID]] = []
        list.onSelectionSetChange = { sets.append($0) }
        list.selectedConversationID = ids[2]
        list.extendSelection(by: 1)
        list.extendSelection(by: 1)
        XCTAssertEqual(list.selectedConversationIDs, Array(ids[2...4]))
        XCTAssertEqual(list.selectedConversationID, ids[4], "the lead follows the extension")
        XCTAssertEqual(list.tableView.selectedRowIndexes.count, 3)
        list.extendSelection(by: -1)
        XCTAssertEqual(list.selectedConversationIDs, Array(ids[2...3]), "moving back toward the anchor gives a row back")
        list.extendSelection(by: -1)
        list.extendSelection(by: -1)
        XCTAssertEqual(list.selectedConversationIDs, [ids[1], ids[2]], "past the anchor it grows the other way")
        XCTAssertEqual(sets.last, [ids[1], ids[2]])
        list.selectNext()
        XCTAssertEqual(list.selectedConversationIDs, [ids[2]], "j collapses the selection")
    }

    func testTheSelectionSurvivesARefresh() throws {
        let (list, _, store) = try hostMulti()
        let ids = list.conversations.map(\.id)
        list.selectedConversationID = ids[3]
        list.extendSelection(by: 1)
        list.extendSelection(by: 1)
        // A new message elsewhere refreshes the rows.
        let other = list.conversations[8]
        try store.upsertMessages([MessageMetadata(
            id: MessageID(accountID: other.id.accountID, providerID: "refresh"), conversationID: other.id, subject: other.subject,
            snippet: "", from: Support.senders[0], date: Date(), roles: [.inbox], isRead: false, isStarred: false, hasAttachments: false
        )])
        Support.spin(until: { list.conversations.first?.id == other.id }, timeout: 2)
        XCTAssertEqual(Set(list.selectedConversationIDs), Set(ids[3...5]))
        XCTAssertEqual(list.tableView.selectedRowIndexes.count, 3)
    }

    func testRowsThatLeaveLeaveTheSelectionAndTheLeadMovesToTheRest() throws {
        let (list, _, store) = try hostMulti()
        let ids = list.conversations.map(\.id)
        var sets: [[ConversationID]] = []
        list.onSelectionSetChange = { sets.append($0) }
        list.selectedConversationID = ids[1]
        list.extendSelection(by: 1)
        list.extendSelection(by: 1)
        // The lead (ids[3]) is archived on its own: the lead moves to the first of the others still selected.
        try apply(.archive, to: [ids[3]], in: store)
        Support.spin(until: { !list.conversations.contains { $0.id == ids[3] } }, timeout: 2)
        XCTAssertEqual(list.selectedConversationIDs, [ids[1], ids[2]])
        XCTAssertEqual(list.selectedConversationID, ids[1])
        XCTAssertEqual(sets.last, [ids[1], ids[2]])
        // Archiving the rest hands one row the selection, as archiving one does.
        try apply(.archive, to: [ids[1], ids[2]], in: store)
        Support.spin(until: { !list.conversations.contains { $0.id == ids[1] } }, timeout: 2)
        XCTAssertEqual(list.selectedConversationIDs.count, 1)
        XCTAssertEqual(list.selectedConversationID, ids[4])
    }

    func testASelectionMadeAheadOfItsRowsLandsAsTheyArrive() throws {
        let (list, _, store) = try hostMulti()
        let ids = list.conversations.map(\.id)
        let gone = [ids[0], ids[1]]
        try apply(.archive, to: gone, in: store)
        Support.spin(until: { list.conversations.first?.id == ids[2] }, timeout: 2)
        list.selectConversations(gone, lead: gone.last)
        XCTAssertTrue(list.tableView.selectedRowIndexes.isEmpty, "nothing to highlight until the rows come back")
        try apply(.moveToInbox, to: gone, in: store)
        Support.spin(until: { list.conversations.first?.id == ids[0] }, timeout: 2)
        XCTAssertEqual(list.selectedConversationIDs, gone)
    }

    func testWithoutMultipleSelectionShiftJIsAPlainMove() throws {
        let store = try Support.store(threads: 6, spacing: 600)
        let (list, _) = Support.host(store: store, settings: Support.settings())
        let ids = list.conversations.map(\.id)
        list.selectedConversationID = ids[0]
        list.extendSelection(by: 1)
        XCTAssertEqual(list.selectedConversationIDs, [ids[1]])
    }
}

/// ⇧J / ⇧K and ⇧↓ / ⇧↑ extend the selection (spec §6).
@MainActor
final class KeyboardRouterExtendTests: XCTestCase {
    /// A key with the list's table holding the keyboard.
    private func command(_ characters: String, keyCode: UInt16 = 0, _ modifiers: NSEvent.ModifierFlags) -> KeyCommand? {
        KeyboardRouter.command(characters: characters, keyCode: keyCode, modifiers: modifiers, pendingG: false, readerFocused: false,
                               listFocused: true).command
    }

    func testShiftJAndShiftKExtend() {
        XCTAssertEqual(command("J", keyCode: 38, .shift), .extendNext)
        XCTAssertEqual(command("K", keyCode: 40, .shift), .extendPrevious)
        XCTAssertEqual(command("", keyCode: 125, .shift), .extendNext)
        XCTAssertEqual(command("", keyCode: 126, .shift), .extendPrevious)
        XCTAssertEqual(command("j", keyCode: 38, []), .next)
        XCTAssertEqual(command("I", keyCode: 34, .shift), .moveToInbox)
    }

    /// § 6: → opens the selected conversation from the list; ← returns from the reader by Esc's path.
    func testRightOpensAndLeftGoesBack() {
        func reader(_ keyCode: UInt16) -> KeyCommand? {
            KeyboardRouter.command(characters: "", keyCode: keyCode, modifiers: [], pendingG: false, readerFocused: true).command
        }
        XCTAssertEqual(command("", keyCode: 124, []), .open)
        XCTAssertNil(command("", keyCode: 123, []), "← on the list does nothing")
        XCTAssertNil(reader(124), "→ in the reader stays the web view's")
        XCTAssertEqual(reader(123), .back, "← in the reader goes back to the list, along Esc's path")
        XCTAssertNil(command("", keyCode: 124, .shift))
    }

    /// § 6, §5.49: ↩ and keypad Enter open the selection in a window of its own from the list, where → opens it in the
    /// main window's reader; in the reader ↩ stays Open, which gives way to what has focus in the page.
    func testReturnOpensInAWindowFromTheListAndIsOpenInTheReader() {
        func reader(_ keyCode: UInt16) -> KeyCommand? {
            KeyboardRouter.command(characters: "\r", keyCode: keyCode, modifiers: [], pendingG: false, readerFocused: true).command
        }
        XCTAssertEqual(command("\r", keyCode: 36, []), .openInWindow)
        XCTAssertEqual(command("\u{3}", keyCode: 76, []), .openInWindow, "keypad Enter")
        XCTAssertEqual(command("", keyCode: 124, []), .open, "→ stays in the main window")
        XCTAssertEqual(reader(36), .open)
        XCTAssertEqual(reader(76), .open)
        XCTAssertNil(command("\r", keyCode: 36, .shift), "⇧↩ is no shortcut")
        XCTAssertNil(KeyboardRouter.command(characters: "\r", keyCode: 36, modifiers: .command, pendingG: false,
                                            readerFocused: false).command, "⌘↩ is the quick reply's send")
    }

    /// §5.49: ↩ opens a window only from the list. With Full Keyboard Access a focused button outside the reader that does
    /// not claim the key (compose, Add Account, a toast's button), or the window itself, keeps ↩: it is no shortcut there,
    /// and the reader's Open stays the reader's wherever the list is.
    func testReturnOpensAWindowOnlyFromTheList() {
        func elsewhere(_ keyCode: UInt16, _ characters: String) -> KeyCommand? {
            KeyboardRouter.command(characters: characters, keyCode: keyCode, modifiers: [], pendingG: false, readerFocused: false,
                                   listFocused: false).command
        }
        XCTAssertNil(elsewhere(36, "\r"), "↩ on a focused control outside the list and the reader")
        XCTAssertNil(elsewhere(76, "\u{3}"), "keypad Enter there")
        XCTAssertEqual(command("\r", keyCode: 36, []), .openInWindow, "the list's table opens a window")
        XCTAssertEqual(KeyboardRouter.command(characters: "\r", keyCode: 36, modifiers: [], pendingG: false, readerFocused: true,
                                              listFocused: false).command, .open, "in the reader ↩ stays Open")
        XCTAssertEqual(elsewhere(124, ""), .open, "→ and the list's other keys are unchanged")
        XCTAssertEqual(elsewhere(38, "j"), .next)
    }

    /// §6.1: Esc's key repeat is a command of its own, so a reader window can tell a held Esc from a fresh press.
    func testEscapesRepeatIsToldApart() {
        XCTAssertEqual(command("\u{1B}", keyCode: 53, []), .clearSearch)
        XCTAssertEqual(KeyboardRouter.command(characters: "\u{1B}", keyCode: 53, modifiers: [], pendingG: false, readerFocused: true,
                                              isRepeat: true).command, .escapeRepeat)
        XCTAssertEqual(KeyboardRouter.command(characters: "j", keyCode: 38, modifiers: [], pendingG: false, readerFocused: false,
                                              isRepeat: true).command, .next, "other keys repeat as they always have")
    }
}
