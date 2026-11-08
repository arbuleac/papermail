import Foundation

/// The calendar invitations of the demo mailboxes, written as the services that send them write iCalendar: Google
/// Calendar (UTC times, a repeat in a named zone with its VTIMEZONE, a cancellation) and Exchange (a Windows zone
/// name, a room among the attendees, a Teams link). Each is the newest mail of its mailbox, so the inbox opens on
/// one, and its times follow the moment the demo is built, so the card always shows a coming event.
enum DemoInvitations {
    struct Invitation {
        let subject: String
        let organizer: DemoCatalog.Person
        let guests: [DemoCatalog.Person]
        let text: String
        let calendar: String
        /// How long before the demo's reference the mail arrived: under the two minutes the newest scripted mail keeps
        /// from it, so an invitation opens the inbox.
        let minutesAgo: Double
    }

    static func invitations(for profile: DemoProfile, reference: Date) -> [Invitation] {
        profile.kind == .gmail ? gmail(profile, reference: reference) : outlook(profile, reference: reference)
    }

    // MARK: Google Calendar

    private static func gmail(_ profile: DemoProfile, reference: Date) -> [Invitation] {
        let me = profile.email
        let dinnerStart = wallClock(daysAfter: 4, hour: 19, minute: 30, from: reference)
        let dinner = calendar(method: "REQUEST", prodID: "-//Google Inc//Google Calendar 70.9054//EN", event: [
            "DTSTART:" + utc(dinnerStart),
            "DTEND:" + utc(dinnerStart.addingTimeInterval(2.5 * 3_600)),
            "DTSTAMP:" + utc(reference),
            "ORGANIZER;CN=Sam Okafor:mailto:\(DemoCatalog.sam.address)",
            "UID:3k7d1demo0birthday0dinner@google.com",
            attendee(DemoCatalog.sam, partstat: "ACCEPTED"),
            attendee(nil, address: me, partstat: "NEEDS-ACTION", rsvp: true),
            attendee(DemoCatalog.priya, partstat: "ACCEPTED"),
            attendee(DemoCatalog.jordan, partstat: "TENTATIVE"),
            attendee(DemoCatalog.diego, partstat: "NEEDS-ACTION"),
            attendee(DemoCatalog.hannah, partstat: "ACCEPTED"),
            attendee(DemoCatalog.maya, partstat: "DECLINED"),
            "LOCATION:Casa Lisboa\\, 24 Valencia Street",
            "SEQUENCE:0",
            "STATUS:CONFIRMED",
            "SUMMARY:Sam's birthday dinner",
            "TRANSP:OPAQUE",
        ])
        // A repeat in Berlin time, which the Mac may well not be in: the card shows both.
        let potteryStart = wallClock(daysAfter: 2, hour: 18, minute: 0, from: reference, zone: "Europe/Berlin")
        let potteryUntil = wallClock(daysAfter: 2 + 7 * 9, hour: 18, minute: 0, from: reference, zone: "Europe/Berlin")
        let pottery = calendar(method: "REQUEST", prodID: "-//Google Inc//Google Calendar 70.9054//EN", timeZones: [berlinZone], event: [
            "DTSTART;TZID=Europe/Berlin:" + local(potteryStart, zone: "Europe/Berlin"),
            "DTEND;TZID=Europe/Berlin:" + local(potteryStart.addingTimeInterval(2 * 3_600), zone: "Europe/Berlin"),
            "RRULE:FREQ=WEEKLY;BYDAY=\(weekdayCode(potteryStart, zone: "Europe/Berlin"));UNTIL=\(utc(potteryUntil))",
            "DTSTAMP:" + utc(reference),
            "ORGANIZER;CN=Hannah Becker:mailto:\(DemoCatalog.hannah.address)",
            "UID:7q2pdemo0pottery0class@google.com",
            attendee(DemoCatalog.hannah, partstat: "ACCEPTED"),
            attendee(nil, address: me, partstat: "ACCEPTED"),
            attendee(DemoCatalog.theo, partstat: "ACCEPTED"),
            "LOCATION:Tonwerk Studio\\, Kastanienallee 12\\, Berlin",
            "SEQUENCE:2",
            "STATUS:CONFIRMED",
            "SUMMARY:Pottery class",
        ])
        let climbingStart = wallClock(daysAfter: 3, hour: 19, minute: 0, from: reference)
        let climbing = calendar(method: "CANCEL", prodID: "-//Google Inc//Google Calendar 70.9054//EN", event: [
            "DTSTART:" + utc(climbingStart),
            "DTEND:" + utc(climbingStart.addingTimeInterval(2 * 3_600)),
            "DTSTAMP:" + utc(reference),
            "ORGANIZER;CN=Jordan Lee:mailto:\(DemoCatalog.jordan.address)",
            "UID:9f4cdemo0climbing0thursday@google.com",
            attendee(DemoCatalog.jordan, partstat: "ACCEPTED"),
            attendee(nil, address: me, partstat: "ACCEPTED"),
            attendee(DemoCatalog.sam, partstat: "ACCEPTED"),
            "LOCATION:Mission Cliffs",
            "SEQUENCE:1",
            "STATUS:CANCELLED",
            "SUMMARY:Climbing night",
        ])
        return [
            Invitation(subject: "Invitation: Sam's birthday dinner", organizer: DemoCatalog.sam,
                       guests: [DemoCatalog.priya, DemoCatalog.jordan, DemoCatalog.diego, DemoCatalog.hannah, DemoCatalog.maya],
                       text: "Sam Okafor has invited you to Sam's birthday dinner. Bring your appetite, the paella takes an hour.",
                       calendar: dinner, minutesAgo: 1),
            Invitation(subject: "Updated invitation: Pottery class", organizer: DemoCatalog.hannah, guests: [DemoCatalog.theo],
                       text: "This event has been updated: it now runs until the end of the term. Aprons are provided.",
                       calendar: pottery, minutesAgo: 1.3),
            Invitation(subject: "Cancelled event: Climbing night", organizer: DemoCatalog.jordan, guests: [DemoCatalog.sam],
                       text: "This event has been cancelled. The gym is closed for the route reset.",
                       calendar: climbing, minutesAgo: 1.5),
        ]
    }

    // MARK: Exchange

    private static func outlook(_ profile: DemoProfile, reference: Date) -> [Invitation] {
        let start = wallClock(daysAfter: 1, hour: 10, minute: 0, from: reference, zone: "America/Los_Angeles")
        let zone = "Pacific Standard Time"
        let critique = calendar(method: "REQUEST", prodID: "Microsoft Exchange Server 2010", timeZones: [pacificZone], event: [
            "ORGANIZER;CN=Rachel Kim:mailto:\(DemoCatalog.rachel.address)",
            "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Alex Morgan:mailto:\(profile.email)",
            "ATTENDEE;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Marcus Bell:mailto:\(DemoCatalog.marcus.address)",
            "ATTENDEE;ROLE=OPT-PARTICIPANT;PARTSTAT=NEEDS-ACTION;RSVP=TRUE;CN=Aisha Patel:mailto:\(DemoCatalog.aisha.address)",
            "ATTENDEE;CUTYPE=RESOURCE;ROLE=NON-PARTICIPANT;RSVP=TRUE;CN=Bay 4 Room:mailto:bay4@northwind-labs.test",
            "DESCRIPTION;LANGUAGE=en-US:Weekly look at the reader and composer work. Bring one thing you would change.\\n",
            "UID:040000008200E00074C5B7101A82E0080000000050DEMO0000000000000000010000000DEMOCRITIQUE",
            "SUMMARY;LANGUAGE=en-US:Design critique",
            "DTSTART;TZID=\(zone):" + local(start, zone: "America/Los_Angeles"),
            "DTEND;TZID=\(zone):" + local(start.addingTimeInterval(3_600), zone: "America/Los_Angeles"),
            "RRULE:FREQ=WEEKLY;BYDAY=\(weekdayCode(start, zone: "America/Los_Angeles"));COUNT=12",
            "CLASS:PUBLIC",
            "PRIORITY:5",
            "DTSTAMP:" + utc(reference),
            "TRANSP:OPAQUE",
            "STATUS:CONFIRMED",
            "SEQUENCE:0",
            "LOCATION;LANGUAGE=en-US:Bay 4",
            "X-MICROSOFT-CDO-APPT-SEQUENCE:0",
            "X-MICROSOFT-CDO-BUSYSTATUS:TENTATIVE",
            "X-MICROSOFT-CDO-ALLDAYEVENT:FALSE",
            "X-MICROSOFT-SKYPETEAMSMEETINGURL:https://teams.demo-outlook.test/l/meetup-join/design-critique",
        ])
        return [
            Invitation(subject: "Design critique", organizer: DemoCatalog.rachel, guests: [DemoCatalog.marcus, DemoCatalog.aisha],
                       text: "Weekly look at the reader and composer work. Bring one thing you would change.",
                       calendar: critique, minutesAgo: 1.1),
        ]
    }

    // MARK: Writing iCalendar

    private static func calendar(method: String, prodID: String, timeZones: [String] = [], event: [String]) -> String {
        var lines = ["BEGIN:VCALENDAR", "PRODID:" + prodID, "VERSION:2.0", "CALSCALE:GREGORIAN", "METHOD:" + method]
        lines += timeZones.flatMap { $0.components(separatedBy: "\n") }
        lines += ["BEGIN:VEVENT"] + event + ["END:VEVENT", "END:VCALENDAR"]
        return InvitationCalendarWriter.fold(lines)
    }

    private static func attendee(_ person: DemoCatalog.Person?, address: String? = nil, partstat: String, rsvp: Bool = false) -> String {
        let mail = person?.address ?? address ?? ""
        // Google writes the address as the name when it has none, as for the user here.
        let name = person?.name ?? mail
        return "ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=\(partstat);RSVP=\(rsvp ? "TRUE" : "FALSE");CN=\(name);X-NUM-GUESTS=0:mailto:\(mail)"
    }

    private static let berlinZone = """
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
        """

    private static let pacificZone = """
        BEGIN:VTIMEZONE
        TZID:Pacific Standard Time
        BEGIN:STANDARD
        DTSTART:16010101T020000
        TZOFFSETFROM:-0700
        TZOFFSETTO:-0800
        RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=1SU;BYMONTH=11
        END:STANDARD
        BEGIN:DAYLIGHT
        DTSTART:16010101T020000
        TZOFFSETFROM:-0800
        TZOFFSETTO:-0700
        RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=2SU;BYMONTH=3
        END:DAYLIGHT
        END:VTIMEZONE
        """

    /// `hour:minute` on the day `days` after the reference's, in `zone` (the Mac's when nil).
    private static func wallClock(daysAfter days: Int, hour: Int, minute: Int, from reference: Date, zone: String? = nil) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
        let day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: reference)) ?? reference
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    private static func utc(_ date: Date) -> String {
        format(date, zone: "UTC", pattern: "yyyyMMdd'T'HHmmss'Z'")
    }

    private static func local(_ date: Date, zone: String) -> String {
        format(date, zone: zone, pattern: "yyyyMMdd'T'HHmmss")
    }

    private static func weekdayCode(_ date: Date, zone: String) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone) ?? .current
        return RecurrenceRule.weekdayCodes[calendar.component(.weekday, from: date) - 1]
    }

    private static func format(_ date: Date, zone: String, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: zone)
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
