import Foundation
import SSCore
import XCTest
@testable import SSGraph

/// The calendar an event message carries in its MIME (`GraphMIMECalendar`), read when Graph will not hand over the
/// event: a meeting request as Exchange writes its MIME (multipart/alternative inside multipart/mixed, the calendar in
/// base64), and the shapes other mailers give the same part.
final class GraphMIMECalendarTests: XCTestCase {
    static let ics = [
        "BEGIN:VCALENDAR", "METHOD:REQUEST", "PRODID:Microsoft Exchange Server 2010", "VERSION:2.0",
        "BEGIN:VEVENT",
        "ORGANIZER;CN=Rachel Kim:mailto:rachel.kim@northwind.test",
        "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Alex Morgan:mailto:alex@northwind.test",
        "UID:040000008200E00074C5B7101A82E00800000000A1B2C3D4",
        "SUMMARY;LANGUAGE=en-US:Roadmap review",
        "DTSTART:20261103T130000Z", "DTEND:20261103T140000Z", "DTSTAMP:20261028T101500Z",
        "SEQUENCE:0", "LOCATION;LANGUAGE=en-US:Bay 4",
        "END:VEVENT", "END:VCALENDAR",
    ].joined(separator: "\r\n") + "\r\n"

    /// A meeting request's MIME as Exchange writes it, attachments and all, wrapped at 76 columns.
    static func exchangeMIME(calendar: String = ics, lineEnding: String = "\r\n") -> Data {
        let encoded = Data(calendar.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return Data([
            "Received: from AM0PR01MB1234.eurprd01.prod.exchangelabs.com",
            "From: Rachel Kim <rachel.kim@northwind.test>",
            "Subject: Roadmap review",
            "Content-Type: multipart/mixed;",
            "\tboundary=\"_004_AM0PR01MB1234_\"",
            "MIME-Version: 1.0",
            "",
            "--_004_AM0PR01MB1234_",
            "Content-Type: multipart/alternative; boundary=\"_000_AM0PR01MB1234_\"",
            "",
            "--_000_AM0PR01MB1234_",
            "Content-Type: text/plain; charset=\"us-ascii\"",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            "Monthly look at the roadmap.",
            "--_000_AM0PR01MB1234_",
            "Content-Type: text/html; charset=\"us-ascii\"",
            "Content-Transfer-Encoding: quoted-printable",
            "",
            "<p>Monthly look at the roadmap. BEGIN:VCALENDAR is only words here.</p>",
            "--_000_AM0PR01MB1234_",
            "Content-Type: text/calendar; charset=\"utf-8\"; method=REQUEST",
            "Content-Transfer-Encoding: base64",
            "",
            encoded.replacingOccurrences(of: "\r\n", with: lineEnding),
            "",
            "--_000_AM0PR01MB1234_--",
            "",
            "--_004_AM0PR01MB1234_",
            "Content-Type: application/pdf; name=\"agenda.pdf\"",
            "Content-Disposition: attachment; filename=\"agenda.pdf\"",
            "Content-Transfer-Encoding: base64",
            "",
            "JVBERi0xLjQKJcOkw7zDtsOfCjIgMCBvYmoKPDwvTGVuZ3RoIDMgMCBSL0ZpbHRlci9GbGF0ZURlY29kZT4+",
            "",
            "--_004_AM0PR01MB1234_--",
            "",
        ].joined(separator: lineEnding).utf8)
    }

    func testExchangesMeetingRequestGivesItsCalendar() throws {
        let calendar = try XCTUnwrap(GraphMIMECalendar.calendar(in: Self.exchangeMIME()))
        XCTAssertEqual(calendar, Self.ics, "the part's bytes, decoded, unchanged")
        let invitation = try XCTUnwrap(CalendarInvitationReader.invitation(fromICS: calendar, userAddresses: ["alex@northwind.test"]))
        XCTAssertEqual(invitation.method, .request)
        XCTAssertEqual(invitation.title, "Roadmap review")
        XCTAssertEqual(invitation.userAddress, "alex@northwind.test")
    }

    func testBareLineFeedsReadAsWell() {
        XCTAssertEqual(GraphMIMECalendar.calendar(in: Self.exchangeMIME(lineEnding: "\n")), Self.ics)
    }

    func testAMessageWithoutACalendarHasNone() {
        let plain = Data("Content-Type: text/plain; charset=utf-8\r\n\r\nBEGIN:VCALENDAR\r\nEND:VCALENDAR\r\n".utf8)
        XCTAssertNil(GraphMIMECalendar.calendar(in: plain), "words that look like a calendar in a text part are not one")
        XCTAssertNil(GraphMIMECalendar.calendar(in: Data()))
        XCTAssertNil(GraphMIMECalendar.calendar(in: Data("not a message at all".utf8)))
    }

    func testQuotedPrintableIsDecodedInItsCharset() throws {
        let latin1 = Self.ics.replacingOccurrences(of: "Bay 4", with: "Caf=E9 =E0 la Bay=\r\n 4")
        let mime = Data("""
            Content-Type: text/calendar; method=REQUEST; charset=iso-8859-1\r
            Content-Transfer-Encoding: quoted-printable\r
            \r
            \(latin1.replacingOccurrences(of: "LOCATION;LANGUAGE=en-US:", with: "LOCATION=3BLANGUAGE=3Den-US:"))
            """.utf8)
        let calendar = try XCTUnwrap(GraphMIMECalendar.calendar(in: mime))
        XCTAssertTrue(calendar.contains("LOCATION;LANGUAGE=en-US:Café à la Bay 4"), "=XX bytes, soft breaks, the part's charset")
        XCTAssertEqual(try XCTUnwrap(CalendarInvitationReader.invitation(fromICS: calendar, userAddresses: [])).location, "Café à la Bay 4")
    }

    func testTheAlternativeWinsOverAnAttachedFileWhereverItIs() throws {
        let file = Self.ics.replacingOccurrences(of: "Roadmap review", with: "The attached copy")
        let mime = Data("""
            Content-Type: multipart/mixed; boundary=outer\r
            \r
            preamble\r
            --outer\r
            Content-Type: application/ics; name="invite.ics"\r
            Content-Disposition: attachment; filename*=utf-8''invite%20copy.ics\r
            \r
            \(file)\r
            --outer\r
            Content-Type: text/calendar; method=REQUEST\r
            \r
            \(Self.ics)\r
            --outer--\r
            epilogue\r
            """.utf8)
        XCTAssertTrue(GraphMIMECalendar.calendar(in: mime)?.contains("SUMMARY;LANGUAGE=en-US:Roadmap review") ?? false)

        let fileOnly = Data("""
            Content-Type: multipart/mixed; boundary=outer\r
            \r
            --outer\r
            Content-Type: text/plain\r
            \r
            See the attached invitation.\r
            --outer\r
            Content-Type: application/octet-stream; name=invite.ics\r
            Content-Disposition: attachment; filename=invite.ics\r
            \r
            \(file)\r
            --outer--\r
            """.utf8)
        XCTAssertTrue(GraphMIMECalendar.calendar(in: fileOnly)?.contains("The attached copy") ?? false, "a file named .ics, with no alternative")
    }

    /// A forwarded message's invitation is that message's, not this one's.
    func testAForwardedMessageIsNotOpened() {
        let mime = Data("""
            Content-Type: multipart/mixed; boundary="b1"\r
            \r
            --b1\r
            Content-Type: text/plain\r
            \r
            Forwarding this.\r
            --b1\r
            Content-Type: message/rfc822\r
            \r
            Content-Type: text/calendar; method=REQUEST\r
            \r
            \(Self.ics)\r
            --b1--\r
            """.utf8)
        XCTAssertNil(GraphMIMECalendar.calendar(in: mime))
    }

    func testALineThatOnlyBeginsLikeTheBoundaryDoesNotEndThePart() throws {
        let mime = Data("""
            Content-Type: multipart/alternative; boundary=b\r
            \r
            --b\r
            Content-Type: text/calendar; method=REQUEST\r
            \r
            \(Self.ics.replacingOccurrences(of: "SEQUENCE:0", with: "SEQUENCE:0\r\n--branch"))\r
            --b--\r
            """.utf8)
        XCTAssertTrue(try XCTUnwrap(GraphMIMECalendar.calendar(in: mime)).contains("--branch\r\nLOCATION"))
    }

    func testAMessageCutShortKeepsThePartItEndsIn() {
        let mime = Data("Content-Type: multipart/alternative; boundary=b\r\n\r\n--b\r\nContent-Type: text/calendar\r\n\r\n\(Self.ics)".utf8)
        XCTAssertEqual(GraphMIMECalendar.calendar(in: mime), Self.ics.trimmingCharacters(in: .newlines))
    }

    func testAByteOrderMarkIsDropped() {
        let marked = Data([0xEF, 0xBB, 0xBF]) + Data(Self.ics.utf8)
        let mime = Data("Content-Type: text/calendar; charset=utf-8\r\nContent-Transfer-Encoding: base64\r\n\r\n\(marked.base64EncodedString())\r\n".utf8)
        XCTAssertEqual(GraphMIMECalendar.calendar(in: mime), Self.ics)
    }

    func testACalendarLargerThanTheReaderReadsIsLeft() {
        let huge = String(repeating: "X", count: CalendarInvitationReader.maximumLength + 1)
        let mime = Data("Content-Type: text/calendar\r\n\r\n\(huge)".utf8)
        XCTAssertNil(GraphMIMECalendar.calendar(in: mime))
    }

    func testNestingDeeperThanAnyMailerWritesIsNotFollowed() {
        var mime = "Content-Type: text/calendar; method=REQUEST\r\n\r\n\(Self.ics)"
        for depth in 0...GraphMIMECalendar.maximumDepth {
            mime = "Content-Type: multipart/mixed; boundary=d\(depth)\r\n\r\n--d\(depth)\r\n\(mime)\r\n--d\(depth)--\r\n"
        }
        XCTAssertNil(GraphMIMECalendar.calendar(in: Data(mime.utf8)))
    }
}
