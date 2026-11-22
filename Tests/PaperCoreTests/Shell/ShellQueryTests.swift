import XCTest
@testable import PaperCore

final class ShellQueryTests: XCTestCase {
    func testMailboxViewWithoutSearch() {
        let query = ShellQuery.make(scope: nil, view: .inbox, searchText: "  ")
        XCTAssertEqual(query.view, .inbox)
        XCTAssertNil(query.searchText)
    }

    /// The Inbox always shows all of its mail (spec §5.5): the shell never asks for a Focused or Other section.
    func testTheInboxIsNeverFilteredBySection() {
        for view in MailboxView.allCases {
            XCTAssertNil(ShellQuery.make(scope: nil, view: view, searchText: "").section, "\(view)")
        }
    }

    /// Later is read whole: it orders by a time ahead, which paging by date cannot walk. A search from it looks through
    /// all mail, or the view an `in:` term picks, as from any view; Later has no `in:` of its own.
    func testLaterIsReadWholeAndSearchLeavesIt() {
        let later = ShellQuery.make(scope: nil, view: .later, searchText: "")
        XCTAssertEqual(later.view, .later)
        XCTAssertEqual(later.limit, ShellQuery.laterLimit)
        XCTAssertEqual(ShellQuery.make(scope: nil, view: .inbox, searchText: "").limit, ConversationQuery().limit, "the other views page")
        let search = ShellQuery.make(scope: nil, view: .later, searchText: "lease")
        XCTAssertEqual(search.view, .all)
        XCTAssertEqual(search.limit, ConversationQuery().limit)
        let sent = ShellQuery.make(scope: nil, view: .later, searchText: "in:sent lease")
        XCTAssertEqual(sent.view, .sent)
        XCTAssertEqual(sent.limit, ConversationQuery().limit)
        XCTAssertEqual(ShellQuery.make(scope: nil, view: .later, searchText: "in:later").view, .all, "a word, not a view")
    }

    func testSearchLooksThroughAllMailInTheScope() {
        let id = AccountID("a")
        let query = ShellQuery.make(scope: [id], view: .starred, searchText: " invoice ")
        XCTAssertEqual(query.view, .all)
        XCTAssertNil(query.section)
        XCTAssertEqual(query.searchText, "invoice")
        XCTAssertEqual(query.accountIDs, [id])
    }

    /// An `in:` operator picks the view a search looks through, whichever view is on screen; the account scope stays.
    func testAnInOperatorPicksTheViewSearched() {
        let id = AccountID("a")
        let sent = ShellQuery.make(scope: [id], view: .inbox, searchText: "in:sent lisbon")
        XCTAssertEqual(sent.view, .sent)
        XCTAssertEqual(sent.accountIDs, [id])
        XCTAssertEqual(sent.searchText, "in:sent lisbon")
        XCTAssertEqual(ShellQuery.make(scope: nil, view: .starred, searchText: "IN:TRASH").view, .trash)
        XCTAssertEqual(ShellQuery.make(scope: nil, view: .trash, searchText: "in:inbox").view, .inbox)
        XCTAssertEqual(ShellQuery.make(scope: nil, view: .inbox, searchText: "in:all").view, .all)
        XCTAssertEqual(ShellQuery.make(scope: nil, view: .inbox, searchText: "-in:sent budget").view, .all,
                       "a negated in: narrows the search; it picks no view")
        XCTAssertEqual(ShellQuery.make(scope: nil, view: .inbox, searchText: "in:sent in:inbox").view, .sent, "the first one")
        XCTAssertEqual(ShellQuery.make(scope: nil, view: .inbox, searchText: "in:tr").view, .all, "not finished yet")
    }

    func testDatesAreReadInTheGivenTimeZone() throws {
        let tokyo = try XCTUnwrap(TimeZone(identifier: "Asia/Tokyo"))
        let query = ShellQuery.make(scope: nil, view: .inbox, searchText: "after:2026-01-15", timeZone: tokyo)
        XCTAssertEqual(query.search?.terms, [SearchTerm(.after(Date(timeIntervalSince1970: 1_768_402_800)))], "2026-01-14T15:00:00Z")
    }
}
