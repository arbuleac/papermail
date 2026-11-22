import XCTest
@testable import PaperCore

/// The iCalendar Paper writes: the iMIP reply (RFC 6047) that answers by mail, and the file written from a
/// Microsoft invitation's facts for Open in Calendar. Both must read back through our own reader.
final class InvitationCalendarWriterTests: XCTestCase {
    private let stamp = ISO8601DateFormatter().date(from: "2026-11-01T09:15:00Z")!

    private func answer(_ response: InvitationResponse = .tentative, title: String = "Design review; Q4, part 2",
                        allDay: Bool = false, recurrence: Date? = nil) -> InvitationAnswer {
        InvitationAnswer(
            response: response, uid: "uid-1@google.com", sequence: 4, recurrenceID: recurrence, title: title,
            start: ISO8601DateFormatter().date(from: allDay ? "2026-11-12T00:00:00Z" : "2026-11-10T15:00:00Z")!,
            end: ISO8601DateFormatter().date(from: allDay ? "2026-11-14T00:00:00Z" : "2026-11-10T16:00:00Z")!,
            isAllDay: allDay, isFloating: allDay,
            organizer: EmailAddress(name: "Carter, Ben", address: "ben@contoso.test"),
            attendee: EmailAddress(name: "Alex Morgan", address: "alex@contoso.test")
        )
    }

    func testTheReplyCarriesTheMethodTheAttendeeAndTheEventsIdentity() {
        let reply = InvitationCalendarWriter.reply(answer(), stamp: stamp)
        XCTAssertEqual(reply, [
            "BEGIN:VCALENDAR",
            "PRODID:-//Paper//Invitations//EN",
            "VERSION:2.0",
            "CALSCALE:GREGORIAN",
            "METHOD:REPLY",
            "BEGIN:VEVENT",
            "UID:uid-1@google.com",
            "SEQUENCE:4",
            "DTSTAMP:20261101T091500Z",
            "DTSTART:20261110T150000Z",
            "DTEND:20261110T160000Z",
            "SUMMARY:Design review\\; Q4\\, part 2",
            "ORGANIZER;CN=\"Carter, Ben\":mailto:ben@contoso.test",
            "ATTENDEE;CN=Alex Morgan;PARTSTAT=TENTATIVE:mailto:alex@contoso.test",
            "END:VEVENT",
            "END:VCALENDAR",
            "",
        ].joined(separator: "\r\n"))
    }

    func testAnAllDayOccurrenceRepliesWithDatesAndItsRecurrenceID() {
        let reply = InvitationCalendarWriter.reply(answer(.declined, allDay: true, recurrence: ISO8601DateFormatter().date(from: "2026-11-12T00:00:00Z")),
                                                   stamp: stamp)
        XCTAssertTrue(reply.contains("RECURRENCE-ID;VALUE=DATE:20261112\r\n"))
        XCTAssertTrue(reply.contains("DTSTART;VALUE=DATE:20261112\r\n"))
        XCTAssertTrue(reply.contains("DTEND;VALUE=DATE:20261114\r\n"))
        XCTAssertTrue(reply.contains("PARTSTAT=DECLINED"))
    }

    func testLongLinesFoldAtSeventyFiveOctetsWithoutSplittingACharacter() throws {
        let title = String(repeating: "Planungsrunde für das Quartal · ", count: 4)
        let reply = InvitationCalendarWriter.reply(answer(title: title), stamp: stamp)
        for line in reply.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.utf8.count, 75, line)
        }
        // Read back by our reader, the folded title is whole again.
        let calendar = try XCTUnwrap(ICalendarContent.calendar(from: reply))
        let event = try XCTUnwrap(calendar.children("VEVENT").first)
        XCTAssertEqual(event.first("SUMMARY")?.text, title)
    }

    func testTheReplysWords() {
        XCTAssertEqual(InvitationCalendarWriter.replySubject(answer(.accepted, title: "Design review")), "Accepted: Design review")
        XCTAssertEqual(InvitationCalendarWriter.replySubject(answer(.tentative, title: "Design review")), "Tentative: Design review")
        XCTAssertEqual(InvitationCalendarWriter.replySubject(answer(.declined, title: "")), "Declined")
        XCTAssertEqual(InvitationCalendarWriter.replyText(answer(.accepted)), "Alex Morgan has accepted this invitation.")
        XCTAssertEqual(InvitationCalendarWriter.replyText(answer(.tentative)), "Alex Morgan has tentatively accepted this invitation.")
        XCTAssertEqual(InvitationCalendarWriter.replyText(answer(.declined)), "Alex Morgan has declined this invitation.")
        var nameless = answer(.accepted)
        nameless.attendee = EmailAddress(address: "alex@contoso.test")
        XCTAssertEqual(InvitationCalendarWriter.replyHTML(nameless), "<p>alex@contoso.test has accepted this invitation.</p>")
    }

    func testACalendarWrittenFromFactsReadsBackAsTheSameInvitation() throws {
        let original = try XCTUnwrap(CalendarInvitationReader.invitation(
            fromICS: CalendarFixtures.exchangeRequest, userAddresses: ["alex@northwind.test"], locale: Locale(identifier: "en_GB")))
        let rule = try XCTUnwrap(RecurrenceRule(rrule: "FREQ=MONTHLY;BYDAY=1TU;UNTIL=20270302T130000Z"))
        let written = InvitationCalendarWriter.calendar(for: original, rule: rule, stamp: stamp)
        let reread = try XCTUnwrap(CalendarInvitationReader.invitation(fromICS: written, userAddresses: ["alex@northwind.test"],
                                                                       locale: Locale(identifier: "en_GB")))
        XCTAssertEqual(reread.uid, original.uid)
        XCTAssertEqual(reread.start, original.start)
        XCTAssertEqual(reread.end, original.end)
        XCTAssertEqual(reread.title, original.title)
        XCTAssertEqual(reread.location, original.location)
        XCTAssertEqual(reread.organizer, original.organizer)
        XCTAssertEqual(reread.attendees, original.attendees)
        XCTAssertEqual(reread.repeats, original.repeats)
    }

    private func losAngeles(start: String, minutes: Double) -> CalendarInvitation {
        let start = ISO8601DateFormatter().date(from: start)!
        return CalendarInvitation(method: .request, uid: "series-1@northwind.test", title: "Weekly sync", start: start,
                                  end: start.addingTimeInterval(minutes * 60), timeZoneID: "America/Los_Angeles",
                                  organizer: CalendarInvitation.Person(name: "Rachel Kim", address: "rachel.kim@northwind.test"))
    }

    private func weeklyOnMonday(until day: String) -> RecurrenceRule {
        RecurrenceRule(frequency: .weekly, days: [RecurrenceRule.Day(weekday: 2)],
                       until: ISO8601DateFormatter().date(from: day + "T00:00:00Z"), untilIsDate: true)
    }

    private func observances(in written: String) throws -> [[String]] {
        let calendar = try XCTUnwrap(ICalendarContent.calendar(from: written))
        let zone = try XCTUnwrap(calendar.children("VTIMEZONE").first)
        return zone.components.map { observance in
            [observance.name] + ["DTSTART", "RDATE", "TZOFFSETFROM", "TZOFFSETTO"].compactMap { observance.first($0)?.value }
        }
    }

    /// A weekly Monday 17:00 in Los Angeles starts on a Tuesday in UTC, so written in UTC its BYDAY=MO would put every
    /// later occurrence on a Sunday there. It is written in the event's own zone, which a VTIMEZONE defines, and its end
    /// date (a DATE, as Microsoft gives it) becomes the end of that day there, in UTC.
    func testARepeatIsWrittenInTheEventsOwnZone() throws {
        let invitation = losAngeles(start: "2026-11-10T01:00:00Z", minutes: 30)
        let rule = weeklyOnMonday(until: "2027-01-25")
        let written = InvitationCalendarWriter.calendar(for: invitation, rule: rule, stamp: stamp)
        XCTAssertTrue(written.contains("DTSTART;TZID=America/Los_Angeles:20261109T170000\r\n"), written)
        XCTAssertTrue(written.contains("DTEND;TZID=America/Los_Angeles:20261109T173000\r\n"))
        XCTAssertTrue(written.contains("RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20270126T075959Z\r\n"), "the end of 25 January in Los Angeles")
        XCTAssertEqual(try observances(in: written), [["STANDARD", "20261101T020000", "-0700", "-0800"]],
                       "standard time, in force since 1 November, to the end of the repeat")

        let reread = try XCTUnwrap(CalendarInvitationReader.invitation(fromICS: written, userAddresses: [], locale: Locale(identifier: "en_GB")))
        XCTAssertEqual(reread.start, invitation.start)
        XCTAssertEqual(reread.end, invitation.end)
        XCTAssertEqual(reread.timeZoneID, "America/Los_Angeles")
        XCTAssertEqual(reread.repeats, rule.words(start: invitation.start, timeZone: TimeZone(identifier: "America/Los_Angeles")!,
                                                  locale: Locale(identifier: "en_GB")))

        // A single event is one instant, which UTC states exactly.
        let single = InvitationCalendarWriter.calendar(for: invitation, stamp: stamp)
        XCTAssertTrue(single.contains("DTSTART:20261110T010000Z\r\n"))
        XCTAssertFalse(single.contains("VTIMEZONE"))
    }

    /// A weekly 10:00 in Los Angeles that crosses the change to daylight time on 14 March 2027: the VTIMEZONE defines
    /// both offsets over the repeat's span, so the meeting stays at 10:00 after the change (in UTC it would move to 11:00).
    func testTheZoneCoversADaylightChangeTheRepeatCrosses() throws {
        let invitation = losAngeles(start: "2027-01-04T18:00:00Z", minutes: 60)
        let written = InvitationCalendarWriter.calendar(for: invitation, rule: weeklyOnMonday(until: "2027-04-26"), stamp: stamp)
        XCTAssertTrue(written.contains("DTSTART;TZID=America/Los_Angeles:20270104T100000\r\n"), written)
        XCTAssertTrue(written.contains("RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20270427T065959Z\r\n"), "the end of 26 April, in daylight time")
        XCTAssertEqual(try observances(in: written), [
            ["STANDARD", "20261101T020000", "-0700", "-0800"],
            ["DAYLIGHT", "20270314T020000", "-0800", "-0700"],
        ])
    }

    /// The definition comes from the Mac's zone data: each kind of change once, its later onsets as RDATE; a zone that
    /// does not change is one observance from long before.
    func testTheZoneDefinitionComesFromTheMacsZoneData() throws {
        let start = ISO8601DateFormatter().date(from: "2026-11-03T13:00:00Z")!
        let berlin = InvitationCalendarWriter.timeZoneDefinition("Europe/Berlin", TimeZone(identifier: "Europe/Berlin")!, from: start,
                                                                 through: start.addingTimeInterval(600 * 86_400))
        XCTAssertEqual(berlin, [
            "BEGIN:VTIMEZONE", "TZID:Europe/Berlin",
            "BEGIN:STANDARD", "DTSTART:20261025T030000", "RDATE:20271031T030000", "TZOFFSETFROM:+0200", "TZOFFSETTO:+0100", "END:STANDARD",
            "BEGIN:DAYLIGHT", "DTSTART:20270328T020000", "RDATE:20280326T020000", "TZOFFSETFROM:+0100", "TZOFFSETTO:+0200", "END:DAYLIGHT",
            "END:VTIMEZONE",
        ])
        let tokyo = InvitationCalendarWriter.timeZoneDefinition("Asia/Tokyo", TimeZone(identifier: "Asia/Tokyo")!, from: start,
                                                                through: start.addingTimeInterval(365 * 86_400))
        XCTAssertEqual(tokyo, ["BEGIN:VTIMEZONE", "TZID:Asia/Tokyo", "BEGIN:STANDARD", "DTSTART:19700101T000000",
                               "TZOFFSETFROM:+0900", "TZOFFSETTO:+0900", "END:STANDARD", "END:VTIMEZONE"])
    }

    func testTheAnswerIsBuiltFromTheStoredInvitation() throws {
        let invitation = try XCTUnwrap(CalendarInvitationReader.invitation(
            fromICS: CalendarFixtures.googleRequest, userAddresses: ["alex@contoso.test"]))
        let built = try XCTUnwrap(InvitationAnswer(.accepted, to: invitation, accountEmail: "alex@contoso.test", accountName: "Alex Morgan",
                                                   previous: .tentative))
        XCTAssertEqual(built.organizer, EmailAddress(name: "Ben Carter", address: "ben@contoso.test"))
        XCTAssertEqual(built.attendee, EmailAddress(name: "Alex Morgan", address: "alex@contoso.test"),
                       "an attendee listed without a name takes the account's")
        XCTAssertEqual(built.previous, .tentative)
        XCTAssertEqual(built.uid, invitation.uid)
        XCTAssertNil(InvitationAnswer(.needsAction, to: invitation, accountEmail: "alex@contoso.test", accountName: nil, previous: nil))
        var cancelled = invitation
        cancelled.method = .cancel
        XCTAssertNil(InvitationAnswer(.accepted, to: cancelled, accountEmail: "alex@contoso.test", accountName: nil, previous: nil))
        // Not naming the account, it is no answer of the account's: a forward, a Bcc, another address of the user's.
        var unlisted = invitation
        unlisted.userAddress = nil
        XCTAssertNil(InvitationAnswer(.declined, to: unlisted, accountEmail: "me@else.test", accountName: nil, previous: nil))
        // Sent to a group the user may be on rather than to them: the answer names the account's address.
        var toList = unlisted
        toList.answersAsAccount = true
        XCTAssertEqual(InvitationAnswer(.declined, to: toList, accountEmail: "me@else.test", accountName: nil, previous: nil)?.attendee,
                       EmailAddress(address: "me@else.test"))
    }
}
