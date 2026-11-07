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

    func testSearchLooksThroughAllMailInTheScope() {
        let id = AccountID("a")
        let query = ShellQuery.make(scope: [id], view: .starred, searchText: " invoice ")
        XCTAssertEqual(query.view, .all)
        XCTAssertNil(query.section)
        XCTAssertEqual(query.searchText, "invoice")
        XCTAssertEqual(query.accountIDs, [id])
    }
}
