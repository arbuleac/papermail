import XCTest
@testable import SSCore

final class ShellQueryTests: XCTestCase {
    func testMailboxViewWithoutSearch() {
        let query = ShellQuery.make(scope: nil, view: .inbox, section: .focused, searchText: "  ")
        XCTAssertEqual(query.view, .inbox)
        XCTAssertEqual(query.section, .focused)
        XCTAssertNil(query.searchText)
    }

    func testSectionOnlyAppliesToTheInbox() {
        XCTAssertNil(ShellQuery.make(scope: nil, view: .starred, section: .focused, searchText: "").section)
    }

    func testSearchLooksThroughAllMailInTheScope() {
        let id = AccountID("a")
        let query = ShellQuery.make(scope: [id], view: .starred, section: .other, searchText: " invoice ")
        XCTAssertEqual(query.view, .all)
        XCTAssertNil(query.section)
        XCTAssertEqual(query.searchText, "invoice")
        XCTAssertEqual(query.accountIDs, [id])
    }
}
