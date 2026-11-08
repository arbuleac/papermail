import XCTest
@testable import SSCore

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
    /// all mail, as from any view.
    func testLaterIsReadWholeAndSearchLeavesIt() {
        let later = ShellQuery.make(scope: nil, view: .later, searchText: "")
        XCTAssertEqual(later.view, .later)
        XCTAssertEqual(later.limit, ShellQuery.laterLimit)
        XCTAssertEqual(ShellQuery.make(scope: nil, view: .inbox, searchText: "").limit, ConversationQuery().limit, "the other views page")
        let search = ShellQuery.make(scope: nil, view: .later, searchText: "lease")
        XCTAssertEqual(search.view, .all)
        XCTAssertEqual(search.limit, ConversationQuery().limit)
    }

    func testSearchLooksThroughAllMailInTheScope() {
        let id = AccountID("a")
        let query = ShellQuery.make(scope: [id], view: .starred, searchText: " invoice ")
        XCTAssertEqual(query.view, .all)
        XCTAssertNil(query.section)
        XCTAssertEqual(query.searchText, "invoice")
        XCTAssertEqual(query.accountIDs, [id])
    }
}
