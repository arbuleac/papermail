import XCTest
@testable import SSCore

/// The iCalendar reader (docs/ARCHITECTURE.md, "Calendar invitations"): what it reads from Google's and Exchange's
/// invitations, and that anything it cannot read whole gives no card.
final class CalendarInvitationReaderTests: XCTestCase {
    private let locale = Locale(identifier: "en_GB")

    private func read(_ text: String, user: String = "alex@contoso.test") -> CalendarInvitation? {
        CalendarInvitationReader.invitation(fromICS: text, userAddresses: [user], locale: locale)
    }

    private func utc(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)!
    }

    // MARK: Google

    func testGoogleRequestReadsEveryFact() throws {
        let invitation = try XCTUnwrap(read(CalendarFixtures.googleRequest))
        XCTAssertEqual(invitation.method, .request)
        XCTAssertEqual(invitation.uid, "5h0v6l1b2q8c3s4d9e@google.com")
        XCTAssertEqual(invitation.sequence, 0)
        XCTAssertEqual(invitation.stamp, utc("2026-11-01T09:15:00Z"), "DTSTAMP orders revisions with the same SEQUENCE")
        XCTAssertEqual(invitation.title, "Design review")
        XCTAssertEqual(invitation.start, utc("2026-11-10T15:00:00Z"))
        XCTAssertEqual(invitation.end, utc("2026-11-10T16:00:00Z"))
        XCTAssertFalse(invitation.isAllDay)
        XCTAssertFalse(invitation.isFloating)
        XCTAssertNil(invitation.timeZoneID, "UTC times have no zone of their own")
        XCTAssertEqual(invitation.location, "Room 4, Level 2", "escaped commas are undone")
        XCTAssertEqual(invitation.conferenceURL, "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(invitation.organizer, CalendarInvitation.Person(name: "Ben Carter", address: "ben@contoso.test"))
        XCTAssertEqual(invitation.attendees.map(\.address), ["ben@contoso.test", "alex@contoso.test", "ada@contoso.test"])
        XCTAssertEqual(invitation.attendees.map(\.response), [.accepted, .needsAction, .tentative])
        // Google writes the address as the name when there is none; a quoted name keeps its comma.
        XCTAssertNil(invitation.attendees[1].name)
        XCTAssertEqual(invitation.attendees[2].name, "Lovelace, Ada")
        XCTAssertEqual(invitation.userAddress, "alex@contoso.test", "the folded attendee line is the user's")
        XCTAssertEqual(invitation.userResponse, .needsAction)
        XCTAssertFalse(invitation.userIsOrganizer)
        XCTAssertNil(invitation.repeats)
        XCTAssertEqual(invitation.calendarText, CalendarFixtures.googleRequest, "Open in Calendar hands over the invitation as it came")
        XCTAssertTrue(invitation.isAnswerable)
    }

    func testARepeatInANamedZoneIsReadInThatZoneAndSaidInWords() throws {
        let invitation = try XCTUnwrap(read(CalendarFixtures.googleWeekly, user: "alex@fabrikam.test"))
        // 10:00 in Berlin in November is 09:00 UTC.
        XCTAssertEqual(invitation.start, utc("2026-11-10T09:00:00Z"))
        XCTAssertEqual(invitation.end, utc("2026-11-10T10:00:00Z"))
        XCTAssertEqual(invitation.timeZoneID, "Europe/Berlin")
        XCTAssertEqual(invitation.sequence, 2)
        XCTAssertEqual(invitation.repeats, "Every week on Tuesday, until 2 March 2027")
        XCTAssertEqual(invitation.userResponse, .accepted)
    }

    func testACancellationIsMarkedAndCannotBeAnswered() throws {
        let invitation = try XCTUnwrap(read(CalendarFixtures.googleCancel, user: "alex@demo.test"))
        XCTAssertEqual(invitation.method, .cancel)
        XCTAssertTrue(invitation.isCancelled)
        XCTAssertFalse(invitation.isAnswerable)
        XCTAssertEqual(invitation.title, "Climbing night")
    }

    func testStatusCancelledInARequestReadsAsCancelled() throws {
        let text = CalendarFixtures.googleRequest(replacing: "STATUS:CONFIRMED", with: "STATUS:CANCELLED")
        XCTAssertEqual(try XCTUnwrap(read(text)).method, .cancel)
    }

    func testAnEventTheUserOrganizedOffersNoAnswer() throws {
        let invitation = try XCTUnwrap(read(CalendarFixtures.organizedByUser, user: "alex@contoso.test"))
        XCTAssertTrue(invitation.userIsOrganizer, "addresses compare without case")
        XCTAssertFalse(invitation.isAnswerable)
    }

    func testAnAliasTheMessageWasSentToIsTheUser() throws {
        let invitation = try XCTUnwrap(CalendarInvitationReader.invitation(
            fromICS: CalendarFixtures.googleRequest, userAddresses: ["alex.morgan@gmail.test", "ADA@contoso.test"], locale: locale))
        XCTAssertEqual(invitation.userAddress, "ada@contoso.test")
        XCTAssertEqual(invitation.userResponse, .tentative)
    }

    /// A list the user was invited through is shown with the guests, but its answer is not the user's to give.
    func testAGroupIsNeverTheUser() throws {
        let group = "ATTENDEE;CUTYPE=GROUP;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;CN=Design team:mailto:design@contoso.test"
        let text = CalendarFixtures.googleRequest(replacing: "X-GOOGLE-CONFERENCE:", with: group + "\r\nX-GOOGLE-CONFERENCE:")
        let invitation = try XCTUnwrap(CalendarInvitationReader.invitation(
            fromICS: text, userAddresses: ["alex.morgan@gmail.test", "design@contoso.test"], locale: locale))
        XCTAssertTrue(invitation.attendees.contains { $0.address == "design@contoso.test" }, "the group is still a guest")
        XCTAssertNil(invitation.userAddress)
        XCTAssertNil(invitation.userResponse, "the group's ACCEPTED is not the user's answer")
        // A member answers a group's invitation as themselves (RFC 5546 §3.2.3).
        XCTAssertEqual(invitation.answersAsAccount, true)
        XCTAssertTrue(invitation.isAnswerable)
        let answer = try XCTUnwrap(InvitationAnswer(.declined, to: invitation, accountEmail: "alex.morgan@gmail.test",
                                                    accountName: "Alex Morgan", previous: nil))
        XCTAssertEqual(answer.attendee, EmailAddress(name: "Alex Morgan", address: "alex.morgan@gmail.test"), "answered as the account")
    }

    /// An invitation that names neither the account nor a group it may be on (a forward, a Bcc, an assistant's copy of
    /// the boss's invitation, another address of the user's) is shown, but is not the account's to answer.
    func testAnInvitationThatDoesNotNameTheAccountIsNotItsToAnswer() throws {
        let invitation = try XCTUnwrap(read(CalendarFixtures.googleRequest, user: "assistant@contoso.test"))
        XCTAssertNil(invitation.userAddress)
        XCTAssertEqual(invitation.answersAsAccount, false)
        XCTAssertFalse(invitation.isAnswerable)
        XCTAssertNil(InvitationAnswer(.accepted, to: invitation, accountEmail: "assistant@contoso.test", accountName: nil, previous: nil))
    }

    /// Gmail's own domains ignore dots and anything after a plus in the name, so those spellings are the account; the
    /// answer names the address as the invitation lists it. Any other domain compares whole.
    func testGmailSpellingsOfTheAccountAreTheUser() throws {
        let text = CalendarFixtures.googleRequest.replacingOccurrences(of: "alex@contoso.test", with: "Alex.Morgan+work@googlemail.com")
        let invitation = try XCTUnwrap(read(text, user: "alexmorgan@gmail.com"))
        XCTAssertEqual(invitation.userAddress, "Alex.Morgan+work@googlemail.com")
        XCTAssertTrue(invitation.isAnswerable)
        let elsewhere = CalendarFixtures.googleRequest.replacingOccurrences(of: "alex@contoso.test", with: "a.lex@contoso.test")
        XCTAssertNil(try XCTUnwrap(read(elsewhere)).userAddress, "dots matter outside Gmail")
    }

    /// The organizer's address is where an answer is mailed, and the sender writes it: one that could name a second
    /// recipient, or another than the one shown, is no address, so the invitation has no organizer and no answer.
    func testAnOrganizerThatIsNotOnePlainAddressIsNone() throws {
        let crafted = [
            "mailto:ben@contoso.test,a@third.test,b@third.test",
            "mailto:ben@contoso.test>,a@third.test,<b@third.test",
            "mailto:ben@contoso.test;a@third.test",
            "mailto:ben@contoso.test?cc=a@third.test",
            "mailto:ben@contoso.test%2Ca@third.test",
            "mailto:\"ben\"@contoso.test",
            "mailto:ben@contoso.test@third.test",
            "mailto:ben@contoso.test (Ben)",
            "mailto:ben@contoso.test%0D%0ABcc:a@third.test",
        ]
        for value in crafted {
            let text = CalendarFixtures.googleRequest(replacing: "ORGANIZER;CN=Ben Carter:mailto:ben@contoso.test",
                                                      with: "ORGANIZER;CN=Ben Carter:" + value)
            let invitation = try XCTUnwrap(read(text), value)
            XCTAssertNil(invitation.organizer, value)
            XCTAssertFalse(invitation.isAnswerable, value)
        }
        let listed = CalendarFixtures.googleRequest(replacing: "mailto:ada@contoso.test", with: "mailto:ada@contoso.test,x@third.test")
        XCTAssertFalse(try XCTUnwrap(read(listed)).attendees.contains { $0.address.contains("third.test") }, "an attendee too")
        let escaped = CalendarFixtures.googleRequest(replacing: "ORGANIZER;CN=Ben Carter:mailto:ben@contoso.test",
                                                     with: "ORGANIZER;CN=Ben Carter:MAILTO:ben%40contoso.test")
        XCTAssertEqual(try XCTUnwrap(read(escaped)).organizer?.address, "ben@contoso.test", "a percent escape is undone first")
    }

    // MARK: Exchange

    func testExchangeWindowsZoneRoomsAndTheSeriesOverItsException() throws {
        let invitation = try XCTUnwrap(read(CalendarFixtures.exchangeRequest, user: "alex@northwind.test"))
        XCTAssertEqual(invitation.title, "Roadmap review", "the series, not the moved occurrence listed after it")
        XCTAssertNil(invitation.recurrenceID)
        // 14:00 W. Europe Standard Time (Berlin) on 3 November is 13:00 UTC.
        XCTAssertEqual(invitation.start, utc("2026-11-03T13:00:00Z"))
        XCTAssertEqual(invitation.timeZoneID, "Europe/Berlin")
        XCTAssertEqual(invitation.location, "Bay 4")
        XCTAssertEqual(invitation.conferenceURL, "https://teams.microsoft.test/l/meetup-join/roadmap")
        XCTAssertEqual(invitation.attendees.map(\.name), ["Alex Morgan", "Marcus Bell"], "the room is booked, not invited")
        XCTAssertEqual(invitation.repeats, "Every month on the first Tuesday, until 2 March 2027")
        XCTAssertEqual(invitation.userResponse, .needsAction)
    }

    func testAZoneOnlyItsVTIMEZONEDefinesIsEvaluatedFromItsRules() throws {
        let invitation = try XCTUnwrap(read(CalendarFixtures.customZone, user: "alex@northwind.test"))
        // On 10 November the zone has left daylight saving (first Sunday of November): UTC−5, so 09:00 is 14:00 UTC.
        XCTAssertEqual(invitation.start, utc("2026-11-10T14:00:00Z"))
        XCTAssertEqual(invitation.end, utc("2026-11-10T14:30:00Z"))
        XCTAssertEqual(invitation.timeZoneID, TimeZone(secondsFromGMT: -5 * 3_600)?.identifier)
        XCTAssertEqual(invitation.sequence, 3)
    }

    func testTheSameDefinedZoneInSummerIsAnHourCloser() throws {
        let text = CalendarFixtures.customZone
            .replacingOccurrences(of: "20261110T090000", with: "20260710T090000")
            .replacingOccurrences(of: "20261110T093000", with: "20260710T093000")
        XCTAssertEqual(try XCTUnwrap(read(text, user: "alex@northwind.test")).start, utc("2026-07-10T13:00:00Z"))
    }

    /// Outlook names a zone it defines after the places it covers. The VTIMEZONE's TZID is TEXT, so its commas and
    /// semicolons come escaped; the TZID parameter quotes them instead. Both name the same zone.
    func testADefinedZoneWhoseNameHasEscapedSeparatorsIsFound() throws {
        let text = CalendarFixtures.customZone
            .replacingOccurrences(of: "TZID:Customized Time Zone", with: "TZID:(UTC-05:00) Eastern Time\\, US\\; Canada")
            .replacingOccurrences(of: "TZID=\"Customized Time Zone\"", with: "TZID=\"(UTC-05:00) Eastern Time, US; Canada\"")
        let invitation = try XCTUnwrap(read(text, user: "alex@northwind.test"), "the definition is found, so there is a card")
        XCTAssertEqual(invitation.start, utc("2026-11-10T14:00:00Z"))
        XCTAssertEqual(invitation.end, utc("2026-11-10T14:30:00Z"))
    }

    // MARK: Dates

    func testAllDayDatesAreFloatingAndEndExclusive() throws {
        let invitation = try XCTUnwrap(read(CalendarFixtures.allDay, user: "alex@northwind.test"))
        XCTAssertTrue(invitation.isAllDay)
        XCTAssertTrue(invitation.isFloating)
        XCTAssertEqual(invitation.start, utc("2026-11-12T00:00:00Z"))
        XCTAssertEqual(invitation.end, utc("2026-11-14T00:00:00Z"))
        XCTAssertNil(invitation.organizer?.name)
        XCTAssertEqual(invitation.userResponse, .declined)
    }

    func testOutlooksAllDayFlagTurnsMidnightTimesIntoDates() throws {
        let invitation = try XCTUnwrap(read(CalendarFixtures.flaggedAllDay))
        XCTAssertTrue(invitation.isAllDay)
        XCTAssertEqual(invitation.start, utc("2026-11-26T00:00:00Z"))
        XCTAssertEqual(invitation.end, utc("2026-11-27T00:00:00Z"))
        XCTAssertNil(invitation.timeZoneID)
    }

    /// The same flag with a DURATION in place of the end: the event keeps its days rather than ending where it starts.
    func testOutlooksAllDayFlagWithADurationKeepsItsDays() throws {
        for (duration, end) in [("P1D", "2026-11-27T00:00:00Z"), ("P2D", "2026-11-28T00:00:00Z"), ("P1W", "2026-12-03T00:00:00Z")] {
            let text = CalendarFixtures.flaggedAllDay.replacingOccurrences(
                of: "DTEND;TZID=Pacific Standard Time:20261127T000000", with: "DURATION:" + duration)
            let invitation = try XCTUnwrap(read(text), duration)
            XCTAssertTrue(invitation.isAllDay, duration)
            XCTAssertEqual(invitation.start, utc("2026-11-26T00:00:00Z"), duration)
            XCTAssertEqual(invitation.end, utc(end), duration)
        }
    }

    func testFloatingTimesAndADurationInsteadOfAnEnd() throws {
        let invitation = try XCTUnwrap(read(CalendarFixtures.floatingWithDuration, user: "alex@demo.test"))
        XCTAssertTrue(invitation.isFloating)
        XCTAssertFalse(invitation.isAllDay)
        XCTAssertNil(invitation.timeZoneID)
        XCTAssertEqual(invitation.start, utc("2026-11-10T12:30:00Z"), "a floating time is its wall clock, held as UTC")
        XCTAssertEqual(invitation.end, utc("2026-11-10T14:00:00Z"))
    }

    func testWithoutAnEndADateLastsTheDayAndATimeIsAnInstant() throws {
        let date = try XCTUnwrap(read(CalendarFixtures.allDay.replacingOccurrences(of: "DTEND;VALUE=DATE:20261114\n", with: ""),
                                      user: "x@y.test"))
        XCTAssertEqual(date.end.timeIntervalSince(date.start), 86_400)
        let time = try XCTUnwrap(read(CalendarFixtures.googleRequest(replacing: "DTEND:20261110T160000Z\r\n", with: "")))
        XCTAssertEqual(time.end, time.start)
    }

    func testDurations() {
        XCTAssertEqual(ICalendarTimes.duration("PT1H30M"), 5_400)
        XCTAssertEqual(ICalendarTimes.duration("P1D"), 86_400)
        XCTAssertEqual(ICalendarTimes.duration("P2W"), 14 * 86_400)
        XCTAssertEqual(ICalendarTimes.duration("P1DT2H"), 93_600)
        XCTAssertEqual(ICalendarTimes.duration("-PT15M"), -900)
        XCTAssertNil(ICalendarTimes.duration("1H"))
        XCTAssertNil(ICalendarTimes.duration("PT"))
        XCTAssertNil(ICalendarTimes.duration("P1H"), "hours belong after T")
    }

    // MARK: Syntax

    func testUnfoldingParametersAndEscapes() throws {
        let lines = ICalendarContent.unfold("A:one\r\n two\r\n\tthree\nB;X=\"a:b;c\",d:value:with:colons\rC:x")
        XCTAssertEqual(lines, ["A:onetwothree", "B;X=\"a:b;c\",d:value:with:colons", "C:x"])
        let property = try XCTUnwrap(ICalendarContent.property(from: lines[1]))
        XCTAssertEqual(property.name, "B")
        XCTAssertEqual(property.parameters["X"], ["a:b;c", "d"])
        XCTAssertEqual(property.value, "value:with:colons")
        XCTAssertEqual(ICalendarContent.unescape("a\\,b\\;c\\nd\\\\e\\Nf"), "a,b;c\nd\\e\nf")
        XCTAssertNil(ICalendarContent.property(from: "NOCOLON"))
        XCTAssertNil(ICalendarContent.property(from: "A;X=\"unterminated:value"))
    }

    func testWindowsAndPrefixedZoneNames() {
        XCTAssertEqual(CalendarTimeZones.timeZone(named: "Pacific Standard Time")?.identifier, "America/Los_Angeles")
        XCTAssertEqual(CalendarTimeZones.timeZone(named: "W. Europe Standard Time")?.identifier, "Europe/Berlin")
        XCTAssertEqual(CalendarTimeZones.timeZone(named: "\"GMT Standard Time\"")?.identifier, "Europe/London")
        XCTAssertEqual(CalendarTimeZones.timeZone(named: "Tokyo Standard Time")?.identifier, "Asia/Tokyo")
        XCTAssertEqual(CalendarTimeZones.timeZone(named: "/mozilla.org/20050126_1/America/New_York")?.identifier, "America/New_York")
        XCTAssertEqual(CalendarTimeZones.timeZone(named: "America/Argentina/Buenos_Aires")?.identifier, "America/Argentina/Buenos_Aires")
        XCTAssertNil(CalendarTimeZones.timeZone(named: "Customized Time Zone"))
        XCTAssertNil(CalendarTimeZones.timeZone(named: "EST"), "abbreviations are ambiguous")
    }

    // MARK: No card

    func testAnythingItCannotReadWholeGivesNoCard() {
        let cases: [(String, String)] = [
            ("empty", ""),
            ("not iCalendar", "<html><body>Meeting at 3</body></html>"),
            ("a published calendar", CalendarFixtures.googleRequest(replacing: "METHOD:REQUEST", with: "METHOD:PUBLISH")),
            ("a reply", CalendarFixtures.googleRequest(replacing: "METHOD:REQUEST", with: "METHOD:REPLY")),
            ("no method", CalendarFixtures.googleRequest(replacing: "METHOD:REQUEST\r\n", with: "")),
            ("no UID", CalendarFixtures.googleRequest(replacing: "UID:5h0v6l1b2q8c3s4d9e@google.com\r\n", with: "")),
            ("no start", CalendarFixtures.googleRequest(replacing: "DTSTART:20261110T150000Z\r\n", with: "")),
            ("a malformed start", CalendarFixtures.googleRequest(replacing: "DTSTART:20261110T150000Z", with: "DTSTART:2026-11-10 15:00")),
            ("a day that does not exist", CalendarFixtures.googleRequest(replacing: "DTSTART:20261110T150000Z", with: "DTSTART:20261131T150000Z")),
            ("an end before the start", CalendarFixtures.googleRequest(replacing: "DTEND:20261110T160000Z", with: "DTEND:20261110T140000Z")),
            ("a date ending a time", CalendarFixtures.googleRequest(replacing: "DTEND:20261110T160000Z", with: "DTEND;VALUE=DATE:20261111")),
            ("an unknown zone without a definition",
             CalendarFixtures.googleRequest(replacing: "DTSTART:20261110T150000Z", with: "DTSTART;TZID=Atlantis Standard Time:20261110T150000")),
            ("an unreadable repeat", CalendarFixtures.googleRequest(replacing: "SEQUENCE:0", with: "RRULE:FREQ=FORTNIGHTLY\r\nSEQUENCE:0")),
            ("a malformed duration", CalendarFixtures.googleRequest(replacing: "DTEND:20261110T160000Z", with: "DURATION:an hour")),
            ("an unclosed event", CalendarFixtures.googleRequest(replacing: "END:VEVENT\r\n", with: "")),
            ("a mismatched end", CalendarFixtures.googleRequest(replacing: "END:VEVENT", with: "END:VTODO")),
            ("no event", "BEGIN:VCALENDAR\r\nMETHOD:REQUEST\r\nEND:VCALENDAR\r\n"),
            ("a line that is not a content line", CalendarFixtures.googleRequest(replacing: "TRANSP:OPAQUE", with: "this is not a property")),
            ("an oversized object", "BEGIN:VCALENDAR\r\nX-PAD:" + String(repeating: "x", count: ICalendarContent.maximumLength) + "\r\nEND:VCALENDAR"),
        ]
        for (name, text) in cases {
            XCTAssertNil(read(text), "\(name) must give no card")
        }
    }

    func testARuleWithPartsItCannotSaySaysRepeats() throws {
        let text = CalendarFixtures.googleRequest(replacing: "SEQUENCE:0", with: "RRULE:FREQ=WEEKLY;BYHOUR=9,17\r\nSEQUENCE:0")
        XCTAssertEqual(try XCTUnwrap(read(text)).repeats, "Repeats", "true, if vague: never a wrong rule")
    }
}
