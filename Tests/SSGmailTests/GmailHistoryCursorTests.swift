import Foundation
import XCTest
@testable import SSGmail

final class GmailHistoryCursorTests: XCTestCase {
    func testBareHistoryIDRoundTrips() {
        let cursor = GmailHistoryCursor(parsing: " 8675309 ")
        XCTAssertEqual(cursor, GmailHistoryCursor(startHistoryID: "8675309"))
        XCTAssertEqual(cursor.encoded, "8675309", "without a page token the cursor stays a bare id")
        XCTAssertEqual(GmailHistoryCursor(startHistoryID: "1", pageToken: "").encoded, "1")
    }

    func testPageTokenRoundTrips() {
        let cursor = GmailHistoryCursor(startHistoryID: "8675309", pageToken: "abc+/=")
        let encoded = cursor.encoded
        XCTAssertTrue(encoded.hasPrefix("{"))
        XCTAssertEqual(GmailHistoryCursor(parsing: encoded), cursor)
    }

    func testMalformedJSONFallsBackToTreatingTheTextAsAnID() {
        XCTAssertEqual(GmailHistoryCursor(parsing: "{not json"), GmailHistoryCursor(startHistoryID: "{not json"))
    }
}
