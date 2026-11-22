import Foundation

/// iCalendar as the services that send invitations write it, recorded from real invitations and anonymized: names,
/// addresses, UIDs and places are made up; the shapes (folding, escapes, parameters, zones) are theirs.
enum CalendarFixtures {
    /// Google Calendar: UTC times, the user's address as their CN, a Meet link, a folded description, CRLF.
    static let googleRequest = [
        "BEGIN:VCALENDAR",
        "PRODID:-//Google Inc//Google Calendar 70.9054//EN",
        "VERSION:2.0",
        "CALSCALE:GREGORIAN",
        "METHOD:REQUEST",
        "BEGIN:VEVENT",
        "DTSTART:20261110T150000Z",
        "DTEND:20261110T160000Z",
        "DTSTAMP:20261101T091500Z",
        "ORGANIZER;CN=Ben Carter:mailto:ben@contoso.test",
        "UID:5h0v6l1b2q8c3s4d9e@google.com",
        "ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;CN=Ben Carter;X-NUM-GUESTS=0:mailto:ben@contoso.test",
        "ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=",
        " TRUE;CN=alex@contoso.test;X-NUM-GUESTS=0:mailto:alex@contoso.test",
        "ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=TENTATIVE;CN=\"Lovelace, Ada\";X-NUM-GUESTS=0:mailto:ada@contoso.test",
        "X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij",
        "CREATED:20261101T091400Z",
        "DESCRIPTION:Agenda: the reader\\, the composer\\; and the sync line.\\nBring note",
        " s.",
        "LAST-MODIFIED:20261101T091500Z",
        "LOCATION:Room 4\\, Level 2",
        "SEQUENCE:0",
        "STATUS:CONFIRMED",
        "SUMMARY:Design review",
        "TRANSP:OPAQUE",
        "END:VEVENT",
        "END:VCALENDAR",
    ].joined(separator: "\r\n") + "\r\n"

    /// Google Calendar, a repeat: TZID with its VTIMEZONE (and X-LIC-LOCATION), a weekly rule with UNTIL, SEQUENCE 2.
    static let googleWeekly = """
        BEGIN:VCALENDAR
        PRODID:-//Google Inc//Google Calendar 70.9054//EN
        VERSION:2.0
        METHOD:REQUEST
        BEGIN:VTIMEZONE
        TZID:Europe/Berlin
        X-LIC-LOCATION:Europe/Berlin
        BEGIN:DAYLIGHT
        TZOFFSETFROM:+0100
        TZOFFSETTO:+0200
        TZNAME:CEST
        DTSTART:19700329T020000
        RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU
        END:DAYLIGHT
        BEGIN:STANDARD
        TZOFFSETFROM:+0200
        TZOFFSETTO:+0100
        TZNAME:CET
        DTSTART:19701025T030000
        RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU
        END:STANDARD
        END:VTIMEZONE
        BEGIN:VEVENT
        DTSTART;TZID=Europe/Berlin:20261110T100000
        DTEND;TZID=Europe/Berlin:20261110T110000
        RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20270302T090000Z
        DTSTAMP:20261101T091500Z
        ORGANIZER;CN=Hannah Becker:mailto:hannah@fabrikam.test
        UID:7q2p0weekly0standup@google.com
        ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;CN=Hannah Becker:mailto:hannah@fabrikam.test
        ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=ACCEPTED;CN=alex@fabrikam.test:mailto:alex@fabrikam.test
        SEQUENCE:2
        SUMMARY:Weekly standup
        END:VEVENT
        END:VCALENDAR
        """

    /// Exchange: a Windows zone name with its VTIMEZONE, a room among the attendees, LANGUAGE parameters, a Teams
    /// link, a description folded with a tab, and an exception after the series.
    static let exchangeRequest = [
        "BEGIN:VCALENDAR",
        "METHOD:REQUEST",
        "PRODID:Microsoft Exchange Server 2010",
        "VERSION:2.0",
        "BEGIN:VTIMEZONE",
        "TZID:W. Europe Standard Time",
        "BEGIN:STANDARD",
        "DTSTART:16010101T030000",
        "TZOFFSETFROM:+0200",
        "TZOFFSETTO:+0100",
        "RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10",
        "END:STANDARD",
        "BEGIN:DAYLIGHT",
        "DTSTART:16010101T020000",
        "TZOFFSETFROM:+0100",
        "TZOFFSETTO:+0200",
        "RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=3",
        "END:DAYLIGHT",
        "END:VTIMEZONE",
        "BEGIN:VEVENT",
        "ORGANIZER;CN=Rachel Kim:mailto:rachel.kim@northwind.test",
        "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Alex Morgan:mailto:alex@northwind.test",
        "ATTENDEE;ROLE=OPT-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Marcus Bell:mailto:marcus.bell@northwind.test",
        "ATTENDEE;CUTYPE=RESOURCE;ROLE=NON-PARTICIPANT;RSVP=TRUE;CN=Bay 4 Room:mailto:bay4@northwind.test",
        "DESCRIPTION;LANGUAGE=en-US:Monthly look at the roadmap.\\n\\nJoin on your com",
        "\tputer.\\n",
        "UID:040000008200E00074C5B7101A82E0080000000050A1B2C3D4E5F601000000000000000010000000A1B2C3",
        "SUMMARY;LANGUAGE=en-US:Roadmap review",
        "DTSTART;TZID=W. Europe Standard Time:20261103T140000",
        "DTEND;TZID=W. Europe Standard Time:20261103T150000",
        "RRULE:FREQ=MONTHLY;BYDAY=1TU;UNTIL=20270302T130000Z",
        "CLASS:PUBLIC",
        "PRIORITY:5",
        "DTSTAMP:20261028T101500Z",
        "TRANSP:OPAQUE",
        "STATUS:CONFIRMED",
        "SEQUENCE:0",
        "LOCATION;LANGUAGE=en-US:Bay 4",
        "X-MICROSOFT-CDO-ALLDAYEVENT:FALSE",
        "X-MICROSOFT-SKYPETEAMSMEETINGURL:https://teams.microsoft.test/l/meetup-join/roadmap",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "RECURRENCE-ID;TZID=W. Europe Standard Time:20261201T140000",
        "UID:040000008200E00074C5B7101A82E0080000000050A1B2C3D4E5F601000000000000000010000000A1B2C3",
        "SUMMARY;LANGUAGE=en-US:Roadmap review (moved)",
        "DTSTART;TZID=W. Europe Standard Time:20261202T140000",
        "DTEND;TZID=W. Europe Standard Time:20261202T150000",
        "SEQUENCE:0",
        "END:VEVENT",
        "END:VCALENDAR",
    ].joined(separator: "\r\n")

    /// Outlook with a zone Windows does not name the IANA way: “Customized Time Zone”, defined only by its VTIMEZONE
    /// (UTC−5 with daylight saving as in the United States).
    static let customZone = """
        BEGIN:VCALENDAR
        METHOD:REQUEST
        PRODID:Microsoft Exchange Server 2010
        VERSION:2.0
        BEGIN:VTIMEZONE
        TZID:Customized Time Zone
        BEGIN:STANDARD
        DTSTART:16010101T020000
        TZOFFSETFROM:-0400
        TZOFFSETTO:-0500
        RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=1SU;BYMONTH=11
        END:STANDARD
        BEGIN:DAYLIGHT
        DTSTART:16010101T020000
        TZOFFSETFROM:-0500
        TZOFFSETTO:-0400
        RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=2SU;BYMONTH=3
        END:DAYLIGHT
        END:VTIMEZONE
        BEGIN:VEVENT
        ORGANIZER;CN=Tom Hughes:mailto:tom@northwind.test
        ATTENDEE;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Alex Morgan:mailto:alex@northwind.test
        UID:custom-zone-1
        SUMMARY:Vendor call
        DTSTART;TZID="Customized Time Zone":20261110T090000
        DTEND;TZID="Customized Time Zone":20261110T093000
        SEQUENCE:3
        END:VEVENT
        END:VCALENDAR
        """

    /// An all-day event over two days, as dates.
    static let allDay = """
        BEGIN:VCALENDAR
        METHOD:REQUEST
        VERSION:2.0
        BEGIN:VEVENT
        UID:all-day-1
        SUMMARY:Offsite
        DTSTART;VALUE=DATE:20261112
        DTEND;VALUE=DATE:20261114
        ORGANIZER:mailto:rachel.kim@northwind.test
        ATTENDEE;PARTSTAT=DECLINED:mailto:alex@northwind.test
        END:VEVENT
        END:VCALENDAR
        """

    /// Exchange's other all-day form: midnight to midnight with the all-day flag.
    static let flaggedAllDay = """
        BEGIN:VCALENDAR
        METHOD:REQUEST
        VERSION:2.0
        BEGIN:VEVENT
        UID:all-day-2
        SUMMARY:Company holiday
        DTSTART;TZID=Pacific Standard Time:20261126T000000
        DTEND;TZID=Pacific Standard Time:20261127T000000
        X-MICROSOFT-CDO-ALLDAYEVENT:TRUE
        ORGANIZER;CN=People Team:mailto:people@northwind.test
        END:VEVENT
        END:VCALENDAR
        """

    /// Floating times and a DURATION instead of DTEND.
    static let floatingWithDuration = """
        BEGIN:VCALENDAR
        METHOD:REQUEST
        VERSION:2.0
        BEGIN:VEVENT
        UID:floating-1
        SUMMARY:Lunch
        DTSTART:20261110T123000
        DURATION:PT1H30M
        ORGANIZER;CN=Priya Raman:mailto:priya@demo.test
        ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:alex@demo.test
        END:VEVENT
        END:VCALENDAR
        """

    /// A cancellation, LF line ends.
    static let googleCancel = """
        BEGIN:VCALENDAR
        PRODID:-//Google Inc//Google Calendar 70.9054//EN
        VERSION:2.0
        METHOD:CANCEL
        BEGIN:VEVENT
        DTSTART:20261112T180000Z
        DTEND:20261112T200000Z
        ORGANIZER;CN=Jordan Lee:mailto:jordan@demo.test
        UID:climbing-1@google.com
        ATTENDEE;PARTSTAT=ACCEPTED;CN=alex@demo.test:mailto:alex@demo.test
        SEQUENCE:1
        STATUS:CANCELLED
        SUMMARY:Climbing night
        END:VEVENT
        END:VCALENDAR
        """

    /// An event the user organized.
    static let organizedByUser = """
        BEGIN:VCALENDAR
        METHOD:REQUEST
        VERSION:2.0
        BEGIN:VEVENT
        UID:mine-1
        SUMMARY:Team lunch
        DTSTART:20261110T120000Z
        DTEND:20261110T130000Z
        ORGANIZER;CN=Alex Morgan:mailto:Alex@Contoso.test
        ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:ben@contoso.test
        END:VEVENT
        END:VCALENDAR
        """

    /// `googleRequest` with one line replaced, for the cases that must give no card.
    static func googleRequest(replacing old: String, with new: String) -> String {
        googleRequest.replacingOccurrences(of: old, with: new)
    }
}
