import XCTest
@testable import PaperCore

/// An answer queued here is read by an older build (the owner may run main again), and an older build's queued answer
/// is read here (docs/DATA-MODEL.md, "Migrations", v25): the calendar part is optional on both sides.
final class InvitationAnswerCodingTests: XCTestCase {
    /// `InvitationAnswer` as 1.21 declared it: no `calendar`.
    private struct Answer121: Codable, Equatable {
        var response: InvitationResponse
        var previous: InvitationResponse?
        var uid: String
        var sequence: Int
        var recurrenceID: Date?
        var title: String
        var start: Date
        var end: Date
        var isAllDay: Bool
        var isFloating: Bool
        var organizer: EmailAddress
        var attendee: EmailAddress
        var graphEventID: String?
        var replyID: String?
    }

    private let start = Date(timeIntervalSince1970: 1_795_000_000)

    func testAnAnswerWithItsCalendarPartDecodesInTheOlderShape() throws {
        var answer = InvitationAnswer(response: .accepted, previous: .tentative, uid: "uid", sequence: 2, title: "Weekly",
                                      start: start, end: start.addingTimeInterval(1_800),
                                      organizer: EmailAddress(name: "Org", address: "org@example.com"),
                                      attendee: EmailAddress(address: "me@example.com"), graphEventID: "AAMk", replyID: "r1")
        answer.calendar = CalendarCopies(scope: .series(id: "S"), providerEventID: "S",
                                         previous: ["acct|e1": .needsAction, "acct|e2": .declined])
        let json = try MailStoreCodec.json(MetadataChange.answerInvitation(answer))

        struct OldChange: Decodable {
            var answerInvitation: Payload
            struct Payload: Decodable { var _0: Answer121 }
        }
        let old = try JSONDecoder().decode(OldChange.self, from: Data(json.utf8)).answerInvitation._0
        XCTAssertEqual(old, Answer121(response: .accepted, previous: .tentative, uid: "uid", sequence: 2, recurrenceID: nil,
                                      title: "Weekly", start: start, end: start.addingTimeInterval(1_800), isAllDay: false,
                                      isFloating: false, organizer: EmailAddress(name: "Org", address: "org@example.com"),
                                      attendee: EmailAddress(address: "me@example.com"), graphEventID: "AAMk", replyID: "r1"))

        let back = try MailStoreCodec.decode(MetadataChange.self, from: json)
        XCTAssertEqual(back, .answerInvitation(answer), "every scope and the rows' answers round-trip here")
    }

    func testAnOlderAnswerDecodesWithNoCalendarPart() throws {
        let old = Answer121(response: .declined, previous: nil, uid: "uid", sequence: 0, recurrenceID: nil, title: "T",
                            start: start, end: start, isAllDay: true, isFloating: true,
                            organizer: EmailAddress(address: "org@example.com"), attendee: EmailAddress(address: "me@example.com"),
                            graphEventID: nil, replyID: nil)
        let data = try JSONEncoder().encode(["answerInvitation": ["_0": old]])
        guard case .answerInvitation(let answer) = try JSONDecoder().decode(MetadataChange.self, from: data) else {
            return XCTFail("not an answer")
        }
        XCTAssertNil(answer.calendar)
        XCTAssertEqual(answer.response, .declined)
    }

    func testEveryScopeRoundTrips() throws {
        for scope: CalendarCopies.Scope in [.invitation(uid: "u", near: nil), .invitation(uid: "u", near: start),
                                             .event(id: "acct|e"), .series(id: "S")] {
            let copies = CalendarCopies(scope: scope, providerEventID: nil, previous: [:])
            XCTAssertEqual(try JSONDecoder().decode(CalendarCopies.self, from: JSONEncoder().encode(copies)), copies)
        }
    }
}
