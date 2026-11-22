import Foundation

/// Reads an invitation out of iCalendar text (RFC 5545, as iMIP mails it: RFC 6047). Ours and small: it reads the
/// method, the event's UID and revision, its title, start and end (a date, UTC, floating, or in a named zone,
/// resolved through IANA names, Outlook's Windows names, or the calendar's own VTIMEZONE), its duration, location,
/// organizer and attendees with their answers, and its repeat rule as words. It never expands a repeat.
///
/// Anything it cannot read whole gives no invitation, so the reader shows no card rather than a wrong one: a method
/// other than REQUEST or CANCEL, no event, no UID or start, an unknown zone, an end before the start, broken syntax.
public enum CalendarInvitationReader {
    /// The most iCalendar text it reads, in UTF-8 bytes: an invitation is a few kilobytes, so a provider need not
    /// fetch a larger calendar for it.
    public static let maximumLength = ICalendarContent.maximumLength

    /// The invitation in `text`, read for a user whose own addresses are `userAddresses`, in order of preference, or
    /// nil. Every address given is taken as the user's, so it must be one known to be theirs, never one inferred from
    /// whom the message was sent to (`Hydrator.invitation` gives the account's).
    public static func invitation(fromICS text: String, userAddresses: [String], locale: Locale = .current) -> CalendarInvitation? {
        guard let calendar = ICalendarContent.calendar(from: text) else { return nil }
        let methodName = calendar.first("METHOD")?.value.trimmingCharacters(in: .whitespaces).uppercased()
        var method: CalendarInvitation.Method
        switch methodName {
        case "REQUEST": method = .request
        case "CANCEL": method = .cancel
        default: return nil
        }
        let events = calendar.children("VEVENT")
        // A repeating invitation lists its series first and then the occurrences it changed, each with a RECURRENCE-ID;
        // the series is the invitation. One occurrence alone is an invitation to that occurrence.
        guard let event = events.first(where: { $0.first("RECURRENCE-ID") == nil }) ?? events.first else { return nil }
        guard let uid = event.first("UID")?.text.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else { return nil }
        let times = ICalendarTimes(calendar: calendar)
        guard let startProperty = event.first("DTSTART"), var start = times.value(of: startProperty) else { return nil }
        var end: ICalendarTimeValue
        if let endProperty = event.first("DTEND") {
            guard let value = times.value(of: endProperty), value.isDate == start.isDate else { return nil }
            end = value
        } else if let durationText = event.first("DURATION")?.value {
            guard let duration = ICalendarTimes.duration(durationText) else { return nil }
            end = start
            end.date = start.date.addingTimeInterval(duration)
            // The wall clock moves with it: Outlook's all-day flag below reads the last day from it.
            if let wall = start.local.asUTC { end.local = ICalendarLocalTime(utc: wall.addingTimeInterval(duration)) }
        } else {
            // RFC 5545 §3.6.1: a date lasts the day, a time is an instant.
            end = start
            if start.isDate { end.date = start.date.addingTimeInterval(86_400) }
        }
        // Outlook can mark an all-day event with a flag on midnight-to-midnight times instead of dates.
        if !start.isDate, event.first("X-MICROSOFT-CDO-ALLDAYEVENT")?.value.trimmingCharacters(in: .whitespaces).uppercased() == "TRUE",
           Self.isMidnight(start.local), Self.isMidnight(end.local),
           let startDay = ICalendarLocalTime(year: start.local.year, month: start.local.month, day: start.local.day).asUTC,
           let endDay = ICalendarLocalTime(year: end.local.year, month: end.local.month, day: end.local.day).asUTC {
            start = ICalendarTimeValue(date: startDay, isDate: true, isFloating: true, timeZoneID: nil, local: start.local)
            end = ICalendarTimeValue(date: endDay, isDate: true, isFloating: true, timeZoneID: nil, local: end.local)
        }
        guard end.date >= start.date else { return nil }

        if event.first("STATUS")?.value.trimmingCharacters(in: .whitespaces).uppercased() == "CANCELLED" { method = .cancel }

        let sequence = event.first("SEQUENCE").flatMap { Int($0.value.trimmingCharacters(in: .whitespaces)) } ?? 0
        let recurrenceID = event.first("RECURRENCE-ID").flatMap { times.value(of: $0)?.date }
        let organizer = event.first("ORGANIZER").flatMap(person(from:))
        var attendees: [CalendarInvitation.Person] = []
        // A group (a list the user may be on) is shown but is never the user: its answer is not theirs to give.
        var individuals: [CalendarInvitation.Person] = []
        var invitesGroup = false
        for property in event.all("ATTENDEE") {
            let kind = property.parameter("CUTYPE")?.uppercased()
            // Rooms and equipment are booked through the attendee list, but they are not people to show.
            guard kind != "ROOM", kind != "RESOURCE", let person = person(from: property, defaultResponse: .needsAction) else { continue }
            attendees.append(person)
            if kind == "GROUP" { invitesGroup = true } else { individuals.append(person) }
        }

        var repeats: String?
        if let ruleText = event.first("RRULE")?.value {
            // A rule that cannot be read at all would make the card claim a single event.
            guard let rule = RecurrenceRule(rrule: ruleText) else { return nil }
            let zone = start.timeZoneID.flatMap { TimeZone(identifier: $0) } ?? ICalendarTimes.utc.timeZone
            repeats = rule.words(start: start.date, timeZone: zone, locale: locale)
        }

        let users = userAddresses.map(mailbox).filter { !$0.isEmpty }
        func isUser(_ address: String) -> Bool { users.contains(mailbox(address)) }
        let userAttendee = users.lazy.compactMap { user in individuals.first { mailbox($0.address) == user } }.first

        return CalendarInvitation(
            method: method,
            uid: uid,
            sequence: max(0, sequence),
            recurrenceID: recurrenceID,
            stamp: event.first("DTSTAMP").flatMap { times.value(of: $0)?.date },
            title: (event.first("SUMMARY")?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            start: start.date,
            end: end.date,
            isAllDay: start.isDate,
            isFloating: start.isFloating,
            timeZoneID: start.timeZoneID,
            location: nonEmpty(event.first("LOCATION")?.text),
            conferenceURL: conferenceURL(in: event),
            organizer: organizer,
            attendees: attendees,
            repeats: repeats,
            userAddress: userAttendee?.address,
            // Not named, the user may still be on a group the invitation went to, and answers as themselves.
            answersAsAccount: userAttendee == nil && invitesGroup,
            userResponse: userAttendee?.response,
            userIsOrganizer: organizer.map { isUser($0.address) } ?? false,
            calendarText: text
        )
    }

    /// An address as the mailbox it reaches, to tell whether it is the user's: lower-cased, and on Gmail's own domains,
    /// which ignore dots and anything after a plus in the name, without them (j.doe+work@googlemail.com is
    /// jdoe@gmail.com).
    static func mailbox(_ address: String) -> String {
        let lower = address.trimmingCharacters(in: .whitespaces).lowercased()
        guard let at = lower.lastIndex(of: "@") else { return lower }
        let domain = lower[lower.index(after: at)...]
        guard domain == "gmail.com" || domain == "googlemail.com" else { return lower }
        var name = lower[..<at]
        if let plus = name.firstIndex(of: "+") { name = name[..<plus] }
        return name.replacingOccurrences(of: ".", with: "") + "@gmail.com"
    }

    private static func person(from property: ICalendarProperty) -> CalendarInvitation.Person? {
        person(from: property, defaultResponse: nil)
    }

    private static func person(from property: ICalendarProperty, defaultResponse: InvitationResponse?) -> CalendarInvitation.Person? {
        guard let address = ICalendarContent.address(fromCalendarUser: property.value) else { return nil }
        var name = property.parameter("CN")?.trimmingCharacters(in: .whitespaces)
        // Google writes the address again as the name when it has none.
        if let given = name, given.isEmpty || given.caseInsensitiveCompare(address) == .orderedSame { name = nil }
        let response = property.parameter("PARTSTAT").flatMap(InvitationResponse.init(partstat:)) ?? defaultResponse
        return CalendarInvitation.Person(name: name, address: address, response: response)
    }

    /// The meeting link Google (X-GOOGLE-CONFERENCE) or Teams (X-MICROSOFT-SKYPETEAMSMEETINGURL) names apart from
    /// the location, when it is a web address.
    private static func conferenceURL(in event: ICalendarComponent) -> String? {
        for name in ["X-GOOGLE-CONFERENCE", "X-MICROSOFT-SKYPETEAMSMEETINGURL"] {
            if let value = nonEmpty(event.first(name)?.text), webAddress(value) != nil { return value }
        }
        return nil
    }

    /// `value` as an http or https URL, when it is exactly one.
    public static func webAddress(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http", url.host?.isEmpty == false else { return nil }
        return url
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func isMidnight(_ local: ICalendarLocalTime) -> Bool {
        local.hour == 0 && local.minute == 0 && local.second == 0
    }
}
