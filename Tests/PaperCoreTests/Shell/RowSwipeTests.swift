import XCTest
@testable import PaperCore

/// What a swipe on a row offers on each edge (spec §5.7, Swipe): E's change on the trailing edge, U's on the leading
/// one, each only where the key would change the row.
final class RowSwipeTests: XCTestCase {
    private let account = AccountID("a")

    private func row(_ id: String = "1", inInbox: Bool = true, unread: Int = 0, snoozedUntil: Date? = nil) -> ConversationSummary {
        ConversationSummary(
            id: ConversationID(accountID: account, providerID: id), subject: "Lisbon", snippet: "", participants: [], latestDate: Date(),
            messageCount: 2, unreadCount: unread, isStarred: false, hasAttachments: false, inInbox: inInbox, inboxSection: .focused,
            latestMessageID: MessageID(accountID: account, providerID: id + "-m"), hasPendingOperations: false, snoozedUntil: snoozedUntil
        )
    }

    private func keptDraft() -> ConversationSummary {
        var draft = row("draft", inInbox: false, unread: 0)
        draft.id = LocalDraftConversation.conversationID(draftID: UUID(), account: account)
        return draft
    }

    func testTrailingArchivesWhereTheRowHasInboxMail() {
        for view in MailboxView.allCases {
            XCTAssertEqual(RowSwipe.change(for: row(), edge: .trailing, view: view), .archive, "\(view): Inbox mail goes")
        }
    }

    /// E beeps where there is nothing to archive, so the swipe shows no button there.
    func testTrailingOffersNothingWithoutInboxMail() {
        for view in [MailboxView.inbox, .starred, .sent, .drafts, .trash, .all] {
            XCTAssertNil(RowSwipe.change(for: row(inInbox: false), edge: .trailing, view: view), "\(view)")
        }
    }

    /// In Later everything is archived already and E ends the snooze, leaving the mail archived; a snoozed conversation
    /// found by a search (which never reads Later) carries no time, and E leaves it be.
    func testLaterOffersArchiveForItsSnoozedRows() {
        let snoozed = row(inInbox: false, snoozedUntil: Date().addingTimeInterval(3_600))
        XCTAssertEqual(RowSwipe.change(for: snoozed, edge: .trailing, view: .later), .archive)
        XCTAssertNil(RowSwipe.change(for: row(inInbox: false), edge: .trailing, view: .all), "a search's snoozed result")
    }

    func testLeadingIsUForOneRow() {
        XCTAssertEqual(RowSwipe.change(for: row(unread: 1), edge: .leading, view: .inbox), .setRead(true))
        XCTAssertEqual(RowSwipe.change(for: row(unread: 0), edge: .leading, view: .inbox), .setRead(false))
        XCTAssertEqual(RowSwipe.change(for: row(inInbox: false, unread: 2), edge: .leading, view: .trash), .setRead(true),
                       "U works in every view, the Trash included")
    }

    func testAKeptDraftOffersNothing() {
        for edge in RowSwipe.Edge.allCases {
            XCTAssertNil(RowSwipe.change(for: keptDraft(), edge: edge, view: .drafts), "\(edge)")
        }
    }

    func testTitlesAreTheMenusCommands() {
        XCTAssertEqual(RowSwipe.title(for: .archive), "Archive")
        XCTAssertEqual(RowSwipe.title(for: .setRead(true)), "Mark as Read")
        XCTAssertEqual(RowSwipe.title(for: .setRead(false)), "Mark as Unread")
    }

    func testTrailingComesFirst() {
        XCTAssertEqual(RowSwipe.Edge.allCases, [.trailing, .leading], "VoiceOver lists Archive first")
    }
}
