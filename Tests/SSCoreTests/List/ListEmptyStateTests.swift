import XCTest
@testable import SSCore

/// The empty list's copy table (spec §5.9).
final class ListEmptyStateTests: XCTestCase {
    private func state(_ view: MailboxView, section: InboxSection? = nil, search: String? = nil,
                       offline: Bool = false, finished: String? = nil) -> ListEmptyState {
        ListEmptyState.make(query: ConversationQuery(view: view, section: section, searchText: search),
                            isOfflineWithNothingCached: offline, firstSyncFinishedAccount: finished)
    }

    func testEveryViewHasItsPair() {
        XCTAssertEqual(state(.inbox), ListEmptyState(sentence: "Nothing left to read.", hint: "New mail will land here.", glyph: .sparrow))
        XCTAssertEqual(state(.inbox, section: .focused),
                       ListEmptyState(sentence: "Nothing in Focused",
                                      hint: "Mail from people lands here; newsletters and notifications go to Other."))
        XCTAssertEqual(state(.inbox, section: .other),
                       ListEmptyState(sentence: "Nothing in Other", hint: "Newsletters and notifications land here."))
        XCTAssertEqual(state(.starred), ListEmptyState(sentence: "No starred conversations", hint: "Press S to star one."))
        XCTAssertEqual(state(.sent), ListEmptyState(sentence: "No sent mail", hint: "Messages you send appear here."))
        XCTAssertEqual(state(.drafts), ListEmptyState(sentence: "Nothing in Drafts", hint: "Drafts you start here are kept on this Mac."))
        XCTAssertEqual(state(.trash), ListEmptyState(sentence: "Trash is empty", hint: "Conversations you move to Trash appear here."))
        XCTAssertEqual(state(.all), ListEmptyState(sentence: "No mail",
                                                   hint: "Every conversation in this account appears here, archived ones too."))
    }

    func testOnlyInboxZeroCarriesTheSparrow() {
        for view in MailboxView.allCases where view != .inbox {
            XCTAssertNil(state(view).glyph, "\(view)")
        }
        XCTAssertNil(state(.inbox, section: .focused).glyph)
    }

    func testSearchWinsAndQuotesTheQuery() {
        XCTAssertEqual(state(.all, search: "  lisbon flat ", offline: true),
                       ListEmptyState(sentence: "No results for “lisbon flat”", hint: "Search looks at subjects, people and message text."))
        XCTAssertEqual(state(.inbox, search: "   ").sentence, "Nothing left to read.", "a blank query is no search")
    }

    func testSyncStates() {
        XCTAssertEqual(state(.inbox, offline: true),
                       ListEmptyState(sentence: "You're offline", hint: "Mail will appear when you reconnect.", glyph: .offline))
        XCTAssertEqual(state(.inbox, finished: "Contoso"),
                       ListEmptyState(sentence: "No mail in Contoso yet", hint: "Sync finished. New mail will land here."))
    }

    func testOlderMailStillDownloadingPromisesNothing() {
        let starred = ListEmptyState.make(query: ConversationQuery(view: .starred), olderMailDownloading: true)
        XCTAssertEqual(starred, ListEmptyState(sentence: "No starred conversations", hint: "Older mail is still downloading."))
        let inbox = ListEmptyState.make(query: ConversationQuery(view: .inbox), olderMailDownloading: true)
        XCTAssertEqual(inbox, ListEmptyState(sentence: "Nothing left to read.", hint: "Older mail is still downloading."),
                       "no sparrow before inbox zero is known")
        let search = ListEmptyState.make(query: ConversationQuery(view: .all, searchText: "lisbon"), olderMailDownloading: true)
        XCTAssertEqual(search.sentence, "No results for “lisbon”", "search keeps its own line")
    }
}
