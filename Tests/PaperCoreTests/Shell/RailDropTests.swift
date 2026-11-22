import XCTest
@testable import PaperCore

/// Which rail folder takes which dragged rows, and what it does with them (spec §5.2).
final class RailDropTests: XCTestCase {
    private let account = AccountID("a")

    private func row(_ id: String, inInbox: Bool = true, starred: Bool = false) -> ConversationSummary {
        ConversationSummary(
            id: ConversationID(accountID: account, providerID: id), subject: "Lisbon", snippet: "", participants: [], latestDate: Date(),
            messageCount: 1, unreadCount: 0, isStarred: starred, hasAttachments: false, inInbox: inInbox, inboxSection: .focused,
            latestMessageID: MessageID(accountID: account, providerID: id + "-m"), hasPendingOperations: false
        )
    }

    private func keptDraft() -> ConversationSummary {
        var draft = row("draft", inInbox: false)
        draft.id = LocalDraftConversation.conversationID(draftID: UUID(), account: account)
        return draft
    }

    func testEachFolderMakesItsKeysChange() {
        XCTAssertEqual(RailDrop.change(for: .inbox), .moveToInbox)
        XCTAssertEqual(RailDrop.change(for: .starred), .setStarred(true), "a drop only ever stars")
        XCTAssertEqual(RailDrop.change(for: .trash), .trash)
        XCTAssertEqual(RailDrop.change(for: .all), .archive)
        XCTAssertNil(RailDrop.change(for: .sent))
        XCTAssertNil(RailDrop.change(for: .drafts))
    }

    func testSentDraftsAndLaterTakeNothing() {
        XCTAssertNil(RailDrop.change(for: .later), "a snooze needs a time, which a drop cannot give")
        for tile in [MailboxView.sent, .drafts, .later] {
            XCTAssertFalse(RailDrop.accepts(tile, rows: [row("1", inInbox: false)], selectedView: .all, isSearching: false))
        }
    }

    /// Outside a search the selected tile's rows are already where it would put them.
    func testTheSelectedTileTakesNothing() {
        let archived = row("1", inInbox: false)
        for tile in [MailboxView.inbox, .starred, .trash, .all] {
            XCTAssertFalse(RailDrop.accepts(tile, rows: [archived, row("2", starred: false)], selectedView: tile, isSearching: false), "\(tile)")
        }
    }

    /// A search lists mail from every view under the selected tile, so there the rows decide, as they do for S,
    /// E and ⇧I; Trash still takes nothing while selected, because # does nothing in Trash.
    func testDuringASearchTheSelectedTileTakesRowsItWouldChange() {
        let archived = row("1", inInbox: false)
        let inbox = row("2")
        let starred = row("3", starred: true)
        XCTAssertTrue(RailDrop.accepts(.inbox, rows: [archived], selectedView: .inbox, isSearching: true), "⇧I would move it")
        XCTAssertFalse(RailDrop.accepts(.inbox, rows: [inbox], selectedView: .inbox, isSearching: true), "in the Inbox already")
        XCTAssertTrue(RailDrop.accepts(.starred, rows: [inbox], selectedView: .starred, isSearching: true), "S would star it")
        XCTAssertFalse(RailDrop.accepts(.starred, rows: [starred], selectedView: .starred, isSearching: true), "starred already")
        XCTAssertTrue(RailDrop.accepts(.all, rows: [inbox], selectedView: .all, isSearching: true), "E would archive it")
        XCTAssertFalse(RailDrop.accepts(.all, rows: [archived], selectedView: .all, isSearching: true), "archived already")
        XCTAssertFalse(RailDrop.accepts(.trash, rows: [inbox], selectedView: .trash, isSearching: true), "# does nothing in Trash")
    }

    func testARowLeftAsItIsIsRefused() {
        XCTAssertFalse(RailDrop.accepts(.inbox, rows: [row("1"), row("2")], selectedView: .starred, isSearching: false), "all in the Inbox already")
        XCTAssertTrue(RailDrop.accepts(.inbox, rows: [row("1"), row("2", inInbox: false)], selectedView: .starred, isSearching: false), "one is not")
        XCTAssertFalse(RailDrop.accepts(.starred, rows: [row("1", starred: true)], selectedView: .inbox, isSearching: false), "starred already")
        XCTAssertTrue(RailDrop.accepts(.starred, rows: [row("1", starred: true), row("2")], selectedView: .inbox, isSearching: false))
        XCTAssertFalse(RailDrop.accepts(.all, rows: [row("1", inInbox: false)], selectedView: .trash, isSearching: false),
                       "archiving leaves it as it is")
        XCTAssertTrue(RailDrop.accepts(.all, rows: [row("1")], selectedView: .inbox, isSearching: false))
        XCTAssertTrue(RailDrop.accepts(.trash, rows: [row("1", inInbox: false)], selectedView: .sent, isSearching: false))
        XCTAssertFalse(RailDrop.accepts(.trash, rows: [], selectedView: .inbox, isSearching: false), "rows that left the list while dragged")
    }

    /// A draft kept on this Mac is not mail in the store: only Trash takes it, as Discard Draft.
    func testAKeptDraftGoesOnlyToTrash() {
        let draft = keptDraft()
        XCTAssertTrue(RailDrop.accepts(.trash, rows: [draft], selectedView: .drafts, isSearching: false))
        for tile in [MailboxView.inbox, .starred, .all] {
            XCTAssertFalse(RailDrop.accepts(tile, rows: [draft], selectedView: .drafts, isSearching: false), "\(tile)")
        }
        XCTAssertTrue(RailDrop.accepts(.starred, rows: [draft, row("1", inInbox: false)], selectedView: .drafts, isSearching: false),
                      "the store's draft beside it")
    }
}
