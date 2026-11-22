import Foundation

/// Writes the iCalendar Paper sends or hands on: the iMIP reply that answers an invitation by mail (RFC 6047,
/// METHOD:REPLY, the user's ATTENDEE with their PARTSTAT, the same UID and SEQUENCE), and a calendar file for an
/// invitation that arrived without one (Microsoft's), for Open in Calendar.
public enum InvitationCalendarWriter {
    static let productID = "-//Paper//Invitations//EN"

    /// The reply's calendar, the text/calendar part of the answer mailed to the organizer.
    public static func reply(_ answer: InvitationAnswer, stamp: Date = Date()) -> String {
        var lines = header(method: "REPLY")
        lines.append("BEGIN:VEVENT")
        lines.append("UID:" + escape(answer.uid))
        lines.append("SEQUENCE:\(answer.sequence)")
        lines.append("DTSTAMP:" + utcStamp(stamp))
        if let recurrenceID = answer.recurrenceID {
            lines.append(timeLine("RECURRENCE-ID", recurrenceID, isAllDay: answer.isAllDay, isFloating: answer.isFloating))
        }
        lines.append(timeLine("DTSTART", answer.start, isAllDay: answer.isAllDay, isFloating: answer.isFloating))
        lines.append(timeLine("DTEND", answer.end, isAllDay: answer.isAllDay, isFloating: answer.isFloating))
        if !answer.title.isEmpty { lines.append("SUMMARY:" + escape(answer.title)) }
        lines.append(userLine("ORGANIZER", answer.organizer, extra: []))
        lines.append(userLine("ATTENDEE", answer.attendee, extra: ["PARTSTAT=" + answer.response.partstat]))
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")
        return fold(lines)
    }

    /// A calendar for an invitation written from its facts; `rule` is its repeat rule.
    ///
    /// A repeating timed event with a zone is written in that zone's wall-clock time (TZID, defined by a VTIMEZONE): a
    /// rule expands in its start's zone, and Microsoft states a repeat's days and end date in the event's own zone, so
    /// UTC times would put later occurrences on the wrong day (when the UTC date differs) or hour (across a DST change).
    /// A single event is one instant, which UTC states exactly. A timed event's end date becomes the end of that day in
    /// its zone, in UTC, since RFC 5545 allows no DATE UNTIL beside a DATE-TIME start.
    public static func calendar(for invitation: CalendarInvitation, rule: RecurrenceRule? = nil, stamp: Date = Date()) -> String {
        let timed = !invitation.isAllDay && !invitation.isFloating
        var zone: (id: String, zone: TimeZone)?
        if timed, rule != nil, let id = invitation.timeZoneID, let timeZone = TimeZone(identifier: id) { zone = (id, timeZone) }
        var written = rule
        if timed, let until = written?.until, written?.untilIsDate == true {
            written?.until = endOfDay(until, in: zone?.zone ?? ICalendarTimes.utc.timeZone)
            written?.untilIsDate = false
        }
        func time(_ name: String, _ date: Date) -> String {
            guard let zone else { return timeLine(name, date, isAllDay: invitation.isAllDay, isFloating: invitation.isFloating) }
            return name + ";TZID=" + parameterValue(zone.id) + ":" + wallClock(date, in: zone.zone)
        }

        var lines = header(method: invitation.isCancelled ? "CANCEL" : "REQUEST")
        if let zone, let written {
            lines += timeZoneDefinition(zone.id, zone.zone, from: invitation.start, through: horizon(of: written, from: invitation.start))
        }
        lines.append("BEGIN:VEVENT")
        lines.append("UID:" + escape(invitation.uid))
        lines.append("SEQUENCE:\(invitation.sequence)")
        lines.append("DTSTAMP:" + utcStamp(stamp))
        if let recurrenceID = invitation.recurrenceID { lines.append(time("RECURRENCE-ID", recurrenceID)) }
        lines.append(time("DTSTART", invitation.start))
        lines.append(time("DTEND", invitation.end))
        if let written { lines.append("RRULE:" + written.rruleText) }
        lines.append("SUMMARY:" + escape(invitation.title))
        if let location = invitation.location { lines.append("LOCATION:" + escape(location)) }
        if let url = invitation.conferenceURL { lines.append("URL:" + url) }
        if invitation.isCancelled { lines.append("STATUS:CANCELLED") }
        if let organizer = invitation.organizer {
            lines.append(userLine("ORGANIZER", EmailAddress(name: organizer.name, address: organizer.address), extra: []))
        }
        for attendee in invitation.attendees {
            let status = attendee.response.map { ["PARTSTAT=" + $0.partstat] } ?? []
            lines.append(userLine("ATTENDEE", EmailAddress(name: attendee.name, address: attendee.address), extra: status))
        }
        lines.append("END:VEVENT")
        lines.append("END:VCALENDAR")
        return fold(lines)
    }

    /// “Accepted: Design review”, the reply mail's subject, as calendar apps word it.
    public static func replySubject(_ answer: InvitationAnswer) -> String {
        let verb: String
        switch answer.response {
        case .accepted: verb = "Accepted"
        case .tentative: verb = "Tentative"
        case .declined: verb = "Declined"
        case .needsAction: verb = "Invitation"
        }
        return answer.title.isEmpty ? verb : verb + ": " + answer.title
    }

    /// “Alex Morgan has accepted this invitation.”, the reply mail's text for a mail app that shows no calendar.
    public static func replyText(_ answer: InvitationAnswer) -> String {
        let who = answer.attendee.name.flatMap { $0.isEmpty ? nil : $0 } ?? answer.attendee.address
        switch answer.response {
        case .accepted: return who + " has accepted this invitation."
        case .tentative: return who + " has tentatively accepted this invitation."
        case .declined: return who + " has declined this invitation."
        case .needsAction: return who + " has not answered this invitation yet."
        }
    }

    /// The same words as the reply's HTML alternative.
    public static func replyHTML(_ answer: InvitationAnswer) -> String {
        "<p>" + HTMLEscaping.escape(replyText(answer)) + "</p>"
    }

    // MARK: Lines

    private static func header(method: String) -> [String] {
        ["BEGIN:VCALENDAR", "PRODID:" + productID, "VERSION:2.0", "CALSCALE:GREGORIAN", "METHOD:" + method]
    }

    private static func userLine(_ name: String, _ user: EmailAddress, extra: [String]) -> String {
        var parameters: [String] = []
        if let cn = user.name?.trimmingCharacters(in: .whitespacesAndNewlines), !cn.isEmpty {
            parameters.append("CN=" + parameterValue(cn))
        }
        parameters += extra
        let head = ([name] + parameters).joined(separator: ";")
        return head + ":mailto:" + user.address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A parameter value, quoted when it holds a separator; DQUOTE and line breaks cannot appear in one at all.
    private static func parameterValue(_ value: String) -> String {
        let clean = value.replacingOccurrences(of: "\"", with: "'").components(separatedBy: .newlines).joined(separator: " ")
        return clean.contains(where: { ";:,".contains($0) }) ? "\"" + clean + "\"" : clean
    }

    private static func timeLine(_ name: String, _ date: Date, isAllDay: Bool, isFloating: Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = ICalendarTimes.utc.timeZone
        if isAllDay {
            formatter.dateFormat = "yyyyMMdd"
            return name + ";VALUE=DATE:" + formatter.string(from: date)
        }
        // Floating times are held as their wall clock read as UTC, so the same fields come back out without a Z.
        formatter.dateFormat = isFloating ? "yyyyMMdd'T'HHmmss" : "yyyyMMdd'T'HHmmss'Z'"
        return name + ":" + formatter.string(from: date)
    }

    /// A wall-clock time in `zone`, as DTSTART;TZID= and a VTIMEZONE's onsets write it.
    private static func wallClock(_ date: Date, in zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: date)
    }

    /// The last second of the day `date` names (a DATE, held as its midnight read as UTC) in `zone`.
    private static func endOfDay(_ date: Date, in zone: TimeZone) -> Date {
        let day = ICalendarTimes.utc.dateComponents([.year, .month, .day], from: date)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let end = calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 23, minute: 59, second: 59))
        return end ?? date.addingTimeInterval(86_399)
    }

    /// How far a repeat can run, for the VTIMEZONE to cover: to its UNTIL, roughly its COUNT of periods, or 20 years.
    private static func horizon(of rule: RecurrenceRule, from start: Date) -> Date {
        let cap = start.addingTimeInterval(20 * 366 * 86_400)
        if let count = rule.count {
            let days: Double
            switch rule.frequency {
            case .daily: days = 1
            case .weekly: days = 7
            case .monthly: days = 31
            case .yearly: days = 366
            }
            return min(cap, start.addingTimeInterval(days * 86_400 * Double(rule.interval) * Double(count)))
        }
        return min(cap, rule.until ?? cap)
    }

    /// The VTIMEZONE a TZID names, from the Mac's zone data: one observance per kind of offset change, from the change
    /// in force at `start` through `end`, its first onset as DTSTART and the others as RDATE (wall-clock times in the
    /// offset before each, RFC 5545 §3.6.5). It is exact over the span the repeat can run, with no yearly rule to guess;
    /// a zone that does not change in that span is one observance that holds from long before.
    static func timeZoneDefinition(_ id: String, _ zone: TimeZone, from start: Date, through end: Date) -> [String] {
        var onsets: [Date] = []
        var cursor = start.addingTimeInterval(-400 * 86_400)
        while onsets.count < 200, let next = zone.nextDaylightSavingTimeTransition(after: cursor), next <= end {
            onsets.append(next)
            cursor = next
        }
        if let lead = onsets.lastIndex(where: { $0 <= start }) { onsets.removeFirst(lead) }
        struct Observance {
            var daylight: Bool
            var from: Int
            var to: Int
            var onsets: [String]
        }
        var observances: [Observance] = []
        if onsets.first.map({ $0 > start }) ?? true {
            let offset = zone.secondsFromGMT(for: start)
            observances.append(Observance(daylight: zone.isDaylightSavingTime(for: start), from: offset, to: offset,
                                          onsets: ["19700101T000000"]))
        }
        let utc = ICalendarTimes.utc.timeZone
        var grouped: [Observance] = []
        for onset in onsets {
            let from = zone.secondsFromGMT(for: onset.addingTimeInterval(-1))
            let to = zone.secondsFromGMT(for: onset)
            let daylight = zone.isDaylightSavingTime(for: onset)
            let local = wallClock(onset.addingTimeInterval(TimeInterval(from)), in: utc)
            if let index = grouped.firstIndex(where: { $0.daylight == daylight && $0.from == from && $0.to == to }) {
                grouped[index].onsets.append(local)
            } else {
                grouped.append(Observance(daylight: daylight, from: from, to: to, onsets: [local]))
            }
        }
        var lines = ["BEGIN:VTIMEZONE", "TZID:" + id]
        for observance in observances + grouped {
            let name = observance.daylight ? "DAYLIGHT" : "STANDARD"
            lines.append("BEGIN:" + name)
            lines.append("DTSTART:" + observance.onsets[0])
            if observance.onsets.count > 1 { lines.append("RDATE:" + observance.onsets.dropFirst().joined(separator: ",")) }
            lines.append("TZOFFSETFROM:" + offsetText(observance.from))
            lines.append("TZOFFSETTO:" + offsetText(observance.to))
            lines.append("END:" + name)
        }
        lines.append("END:VTIMEZONE")
        return lines
    }

    /// `+0100`, `-0330`; seconds only when there are any.
    private static func offsetText(_ seconds: Int) -> String {
        let value = abs(seconds)
        let text = String(format: "%02d%02d", value / 3_600, value / 60 % 60) + (value % 60 == 0 ? "" : String(format: "%02d", value % 60))
        return (seconds < 0 ? "-" : "+") + text
    }

    private static func utcStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = ICalendarTimes.utc.timeZone
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    /// TEXT escapes (RFC 5545 §3.3.11).
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ";", with: "\\;")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }

    /// Lines of at most 75 octets, continued on lines that start with a space, never splitting a character; CRLF ends
    /// every line.
    static func fold(_ lines: [String]) -> String {
        var output = ""
        for line in lines {
            var current = ""
            var octets = 0
            var limit = 75
            for character in line {
                let size = String(character).utf8.count
                if octets + size > limit {
                    output += current + "\r\n "
                    current = ""
                    octets = 0
                    limit = 74
                }
                current.append(character)
                octets += size
            }
            output += current + "\r\n"
        }
        return output
    }
}
