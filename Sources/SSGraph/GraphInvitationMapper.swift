import Foundation
import SSCore

/// Reads the invitation of a Graph event message from its expanded event: Graph hands the facts over as JSON, so no
/// iCalendar is read here, and a calendar file for Open in Calendar is written from them. A response to the organizer,
/// or an event message whose event cannot be read whole (no UID, no start), gives none.
enum GraphInvitationMapper {
    static func invitation(from message: GraphMessage, locale: Locale = .current) -> CalendarInvitation? {
        guard message.isEventMessage, let event = message.event else { return nil }
        let messageType = message.meetingMessageType?.lowercased()
        let method: CalendarInvitation.Method
        if messageType == "meetingcancelled" || event.isCancelled == true {
            method = .cancel
        } else if messageType == "meetingrequest" || message.odataType?.lowercased().hasSuffix("eventmessagerequest") == true {
            method = .request
        } else {
            return nil
        }
        guard let uid = event.iCalUId?.trimmingCharacters(in: .whitespaces), !uid.isEmpty,
              let startValue = event.start, let endValue = event.end,
              let start = GraphEventTime.read(startValue), var end = GraphEventTime.read(endValue) else { return nil }
        let isAllDay = event.isAllDay ?? false
        var startDate = start.date
        if isAllDay {
            // All-day events are dates: kept as their own days, at midnight read as UTC, wherever the Mac is. The UTC
            // preference moves the creator's midnight, which `allDay` takes back to it in the zone it was made in.
            guard let startDay = GraphEventTime.allDay(startValue, originalZone: event.originalStartTimeZone),
                  let endDay = GraphEventTime.allDay(endValue, originalZone: event.originalEndTimeZone ?? event.originalStartTimeZone)
            else { return nil }
            startDate = startDay
            end.date = endDay
        }
        guard end.date >= startDate else { return nil }
        let zone = event.originalStartTimeZone.flatMap(CalendarTimeZones.timeZone(named:))
        let rule = event.recurrence.flatMap(recurrenceRule(from:))
        let wordsZone = isAllDay ? TimeZone(identifier: "UTC")! : (zone ?? TimeZone(identifier: "UTC")!)
        var invitation = CalendarInvitation(
            method: method,
            uid: uid,
            recurrenceID: (event.type == "occurrence" || event.type == "exception") ? event.originalStart.flatMap(GraphDate.parse) : nil,
            title: (event.subject ?? message.subject ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            start: startDate,
            end: end.date,
            isAllDay: isAllDay,
            isFloating: isAllDay,
            timeZoneID: isAllDay ? nil : zone.flatMap { ["UTC", "GMT", "Etc/UTC", "Etc/GMT"].contains($0.identifier) ? nil : $0.identifier },
            location: nonEmpty(event.location?.displayName),
            conferenceURL: nonEmpty(event.onlineMeeting?.joinUrl).flatMap { CalendarInvitationReader.webAddress($0) == nil ? nil : $0 },
            organizer: person(event.organizer?.emailAddress, response: nil),
            attendees: (event.attendees ?? []).compactMap { attendee in
                // Rooms and equipment are booked as attendees of type resource; they are not people to show.
                guard attendee.type?.lowercased() != "resource" else { return nil }
                return person(attendee.emailAddress, response: response(attendee.status?.response) ?? .needsAction)
            },
            repeats: rule.map { $0.words(start: startDate, timeZone: wordsZone, locale: locale) },
            // The answer goes to the event in the user's own calendar, so it is the mailbox's whomever the invitation named.
            answersAsAccount: true,
            userResponse: response(event.responseStatus?.response),
            userIsOrganizer: event.isOrganizer ?? (event.responseStatus?.response?.lowercased() == "organizer"),
            graphEventID: event.id
        )
        // Graph states a repeat's days and end date in the event's zone and its times in UTC. In a zone the Mac does not
        // know, the two cannot be put in one frame: the file has the first occurrence alone, at its exact time, rather
        // than a repeat Calendar would expand on the wrong days. The card still says how it repeats.
        invitation.calendarText = InvitationCalendarWriter.calendar(for: invitation, rule: isAllDay || zone != nil ? rule : nil)
        return invitation
    }

    /// Graph's answer words; `organizer` and anything unknown say nothing about an answer.
    static func response(_ value: String?) -> InvitationResponse? {
        switch value?.lowercased() {
        case "none", "notresponded": return .needsAction
        case "accepted": return .accepted
        case "tentativelyaccepted": return .tentative
        case "declined": return .declined
        default: return nil
        }
    }

    private static func person(_ address: GraphEmailAddress?, response: InvitationResponse?) -> CalendarInvitation.Person? {
        guard let email = address?.address?.trimmingCharacters(in: .whitespaces), !email.isEmpty else { return nil }
        let name = address?.name?.trimmingCharacters(in: .whitespaces)
        let shown = (name?.isEmpty ?? true) || name?.caseInsensitiveCompare(email) == .orderedSame ? nil : name
        return CalendarInvitation.Person(name: shown, address: email, response: response)
    }

    /// Graph's recurrence pattern as an RRULE's parts; nil for a pattern it does not name.
    static func recurrenceRule(from recurrence: GraphPatternedRecurrence) -> RecurrenceRule? {
        guard let pattern = recurrence.pattern, let type = pattern.type?.lowercased() else { return nil }
        let interval = max(1, pattern.interval ?? 1)
        let ordinal = ordinal(pattern.index)
        let days = (pattern.daysOfWeek ?? []).compactMap(weekday)
        var rule: RecurrenceRule
        switch type {
        case "daily":
            rule = RecurrenceRule(frequency: .daily, interval: interval)
        case "weekly":
            rule = RecurrenceRule(frequency: .weekly, interval: interval, days: days.map { RecurrenceRule.Day(weekday: $0) })
        case "absolutemonthly":
            guard let day = pattern.dayOfMonth, day > 0 else { return nil }
            rule = RecurrenceRule(frequency: .monthly, interval: interval, monthDays: [day])
        case "relativemonthly":
            guard days.count == 1 else { return nil }
            rule = RecurrenceRule(frequency: .monthly, interval: interval, days: [RecurrenceRule.Day(weekday: days[0], ordinal: ordinal)])
        case "absoluteyearly":
            guard let day = pattern.dayOfMonth, day > 0, let month = pattern.month, (1...12).contains(month) else { return nil }
            rule = RecurrenceRule(frequency: .yearly, interval: interval, monthDays: [day], months: [month])
        case "relativeyearly":
            guard days.count == 1, let month = pattern.month, (1...12).contains(month) else { return nil }
            rule = RecurrenceRule(frequency: .yearly, interval: interval, days: [RecurrenceRule.Day(weekday: days[0], ordinal: ordinal)],
                                  months: [month])
        default:
            return nil
        }
        switch recurrence.range?.type?.lowercased() {
        case "enddate":
            if let end = recurrence.range?.endDate, let date = day(end) {
                rule.until = date
                rule.untilIsDate = true
            }
        case "numbered":
            if let count = recurrence.range?.numberOfOccurrences, count > 0 { rule.count = count }
        default:
            break
        }
        return rule
    }

    private static func weekday(_ name: String) -> Int? {
        ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"].firstIndex(of: name.lowercased()).map { $0 + 1 }
    }

    private static func ordinal(_ index: String?) -> Int {
        switch index?.lowercased() {
        case "second": return 2
        case "third": return 3
        case "fourth": return 4
        case "last": return -1
        default: return 1
        }
    }

    private static func day(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
