import XCTest
@testable import SSCore

/// An event is the invitation's own when their iCalendar UIDs match: equal, or for Exchange, the same meeting whatever
/// occurrence (Graph's `iCalUId` carries the occurrence's date, the invitation mail's the series' zeros).
final class InvitationUIDTests: XCTestCase {
    /// A series' GlobalObjectId in hex: the class id, a zero date, the creation time, the reserved bytes, the size, data.
    private let series = "040000008200E00074C5B7101A82E00800000000D0F3B1A2C8D4D901000000000000000010000000A1B2C3D4E5F60718293A4B5C6D7E8F90"

    /// The same id with an occurrence's date (year high and low byte, month, day) in bytes 16 to 19.
    private func occurrence(_ date: String, of id: String) -> String {
        var hex = Array(id)
        hex.replaceSubrange(32..<40, with: Array(date))
        return String(hex)
    }

    func testEqualUIDsMatchAndOthersDoNot() {
        XCTAssertTrue(InvitationUID.matches("abc123@google.com", "abc123@google.com"))
        XCTAssertFalse(InvitationUID.matches("abc123@google.com", "abc124@google.com"))
        XCTAssertFalse(InvitationUID.matches("abc123@google.com", nil))
        XCTAssertFalse(InvitationUID.matches(nil, nil), "an event with no UID is no one's")
    }

    func testAnExchangeOccurrenceMatchesItsSeriesAndItsSiblings() {
        let tuesday = occurrence("07E9030B", of: series)
        let thursday = occurrence("07E9030D", of: series)
        XCTAssertTrue(InvitationUID.matches(series, tuesday))
        XCTAssertTrue(InvitationUID.matches(tuesday, thursday))
        XCTAssertTrue(InvitationUID.matches(series.lowercased(), tuesday), "hex is hex in either case")
        XCTAssertTrue(InvitationUID.matches(tuesday, series))
    }

    func testAnotherExchangeMeetingDoesNotMatch() {
        var other = Array(series)
        other[50] = other[50] == "1" ? "2" : "1"
        XCTAssertFalse(InvitationUID.matches(series, String(other)), "a different creation time is a different meeting")
        XCTAssertFalse(InvitationUID.matches(occurrence("07E9030B", of: series), occurrence("07E9030B", of: String(other))))
        XCTAssertFalse(InvitationUID.matches("040000008200E00074C5B7101A82E008", "040000008200E00074C5B7101A82E009"),
                       "too short to hold a date: compared whole")
    }

    func testTheCalendarsOverlapCheckTakesAnOccurrenceAsTheInvitationsOwn() {
        let account = AccountID("acct-1")
        let start = Date(timeIntervalSince1970: 1_741_705_200)
        let own = CalendarEvent(id: "acct-1|own", accountID: account, providerID: "own", title: "Weekly sync", start: start,
                                end: start.addingTimeInterval(1_800), response: .needsAction,
                                invitationUID: occurrence("07E9030B", of: series))
        let other = CalendarEvent(id: "acct-1|other", accountID: account, providerID: "other", title: "Hiring sync",
                                  start: start.addingTimeInterval(900), end: start.addingTimeInterval(2_700), invitationUID: "x@google.com")
        let overlap = CalendarFit.invitationOverlap(uid: series, near: start, in: [own, other])
        XCTAssertEqual(overlap?.event.id, own.id, "the calendar's copy is the invitation's event")
        XCTAssertEqual(overlap?.overlaps.map(\.event.id), [other.id], "and never an overlap of it")
    }
}
