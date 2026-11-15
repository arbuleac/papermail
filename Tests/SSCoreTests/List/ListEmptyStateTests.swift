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
        XCTAssertEqual(state(.inbox), ListEmptyState(sentence: "Nothing left to read.", hint: "New mail will land here.", glyph: .brandMark))
        XCTAssertEqual(state(.starred), ListEmptyState(sentence: "No starred conversations", hint: "Press S to star one."))
        XCTAssertEqual(state(.sent), ListEmptyState(sentence: "No sent mail", hint: "Messages you send appear here."))
        XCTAssertEqual(state(.drafts), ListEmptyState(sentence: "Nothing in Drafts", hint: "Drafts you start here are kept on this Mac."))
        XCTAssertEqual(state(.trash), ListEmptyState(sentence: "Trash is empty", hint: "Conversations you move to Trash appear here."))
        XCTAssertEqual(state(.all), ListEmptyState(sentence: "No mail",
                                                   hint: "Every conversation in this account appears here, archived ones too."))
    }

    func testOnlyInboxZeroCarriesTheBrandMark() {
        for view in MailboxView.allCases where view != .inbox {
            XCTAssertNil(state(view).glyph, "\(view)")
        }
    }

    /// There is no Focused or Other list any more (spec §5.5): a query that still names a section, which the
    /// shell never builds, says what the whole Inbox says.
    func testAnInboxSectionSaysWhatTheInboxSays() {
        let inbox = state(.inbox)
        XCTAssertEqual(state(.inbox, section: .focused), inbox)
        XCTAssertEqual(state(.inbox, section: .other), inbox)
    }

    func testSearchWinsAndQuotesTheQuery() {
        XCTAssertEqual(state(.all, search: "  lisbon flat ", offline: true),
                       ListEmptyState(sentence: "No results for “lisbon flat”", hint: "Search looks at subjects, people and message text."))
        XCTAssertEqual(state(.inbox, search: "   ").sentence, "Nothing left to read.", "a blank query is no search")
    }

    /// A search with no local results offers the server in its own words (§5.9, §5.10), then says how it went; the
    /// line 1 keeps quoting the query.
    func testAnEmptySearchOffersTheServer() {
        let query = ConversationQuery(view: .all, searchText: "porto")
        let offer = ListEmptyState.make(query: query, serverSearch: ServerSearchRow(target: .provider(.gmail), phase: .offer))
        XCTAssertEqual(offer, ListEmptyState(sentence: "No results for “porto”", hint: "Not on this Mac?", link: "Search Gmail"))
        let running = ListEmptyState.make(query: query, serverSearch: ServerSearchRow(target: .allAccounts, phase: .searching))
        XCTAssertEqual(running, ListEmptyState(sentence: "No results for “porto”", hint: "Searching all accounts…"))
        let nothing = ListEmptyState.make(query: query, serverSearch: ServerSearchRow(target: .provider(.microsoft), phase: .found(0)))
        XCTAssertEqual(nothing.hint, "Nothing on Outlook either.")
        XCTAssertNil(nothing.link)
        let failed = ListEmptyState.make(query: query, serverSearch: ServerSearchRow(target: .provider(.gmail), phase: .failed(subject: "Gmail")))
        XCTAssertEqual(failed, ListEmptyState(sentence: "No results for “porto”", hint: "Couldn't search Gmail ·", link: "Try again"))
        let view = ListEmptyState.make(query: ConversationQuery(view: .inbox), serverSearch: ServerSearchRow(target: .provider(.gmail), phase: .offer))
        XCTAssertNil(view.link, "only a search offers the server")
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
                       "no brand mark before inbox zero is known")
        let search = ListEmptyState.make(query: ConversationQuery(view: .all, searchText: "lisbon"), olderMailDownloading: true)
        XCTAssertEqual(search.sentence, "No results for “lisbon”", "search keeps its own line")
    }
}
