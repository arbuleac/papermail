import Foundation

/// The words of the invitation card (spec §5.14) from a stored invitation: when it is, in this Mac's zone and, when it
/// differs, the event's own; who organized it and who else is invited; which answer is chosen and whether one can be
/// given; and what it overlaps on the user's calendars. Pure and cheap: the facts were read at sync time, so nothing here
/// reads iCalendar, and the calendar's events come in already read from the store.
struct InvitationCardText {
    var calendar: Calendar
    var locale: Locale
    /// This Mac's zone, which timed events are shown in.
    var timeZone: TimeZone

    /// How many guests are named before “+3 more” (spec §5.14, `layout.invitation.attendeesMax`).
    static let guestsShown = 4

    /// - Parameters:
    ///   - reply: the answer given on this Mac (`MessageMetadata.invitationReply`), which wins over the one the
    ///     invitation stated.
    ///   - ownAddresses: the address of the account the message came to, lower-cased, for “You”: the user an answer
    ///     speaks for, never another account's address.
    ///   - needsPermission: the account waits for permission to update its calendar.
    ///   - superseded: a later message in the conversation carries a later revision (`CalendarInvitation.supersedes`):
    ///     only that one is answered.
    ///   - overlap: what it overlaps on the user's calendars (`overlapLine`), shown only while the card can say it
    ///     (`mayOverlap`).
    func card(for invitation: CalendarInvitation, reply: InvitationResponse?, ownAddresses: Set<String>, needsPermission: Bool,
              superseded: Bool = false, overlap: String? = nil, now: Date) -> RenderPayload.Invitation {
        let (canAnswer, response) = answer(invitation, reply: reply, superseded: superseded)
        let userAddress = invitation.userAddress?.lowercased()
        func isUser(_ address: String) -> Bool {
            let lower = address.lowercased()
            return lower == userAddress || ownAddresses.contains(lower)
        }
        let location = invitation.location
        let locationURL = location.flatMap { CalendarInvitationReader.webAddress($0) == nil ? nil : $0 }
        let conference = invitation.conferenceURL.flatMap { $0 == location ? nil : $0 }
        return RenderPayload.Invitation(
            title: invitation.title,
            when: when(invitation, in: invitation.isFloating ? ICalendarTimes.utc.timeZone : timeZone, now: now),
            whenElsewhere: whenElsewhere(invitation, now: now),
            repeats: invitation.repeats,
            location: location,
            locationURL: locationURL,
            conferenceURL: conference,
            organizer: invitation.userIsOrganizer ? "You" : invitation.organizer?.displayName,
            guests: guests(invitation, isUser: isUser),
            isCancelled: invitation.isCancelled,
            canAnswer: canAnswer,
            response: response,
            needsPermission: canAnswer && needsPermission && reply?.isAnswer == true,
            canOpen: invitation.calendarText?.isEmpty == false,
            overlap: saysOverlap(invitation, canAnswer: canAnswer, response: response) ? overlap : nil
        )
    }

    /// Whether Accept · Tentative · Decline are offered, and which answer the card shows chosen: the one given on this
    /// Mac, else the one the invitation states.
    private func answer(_ invitation: CalendarInvitation, reply: InvitationResponse?,
                        superseded: Bool) -> (canAnswer: Bool, response: InvitationResponse?) {
        let canAnswer = invitation.isAnswerable && !superseded
        let stated = invitation.userResponse.flatMap { $0.isAnswer ? $0 : nil }
        return (canAnswer, canAnswer ? (reply.flatMap { $0.isAnswer ? $0 : nil } ?? stated) : nil)
    }

    // MARK: The overlap line

    /// Whether the card can say what its invitation overlaps (spec §5.14): only one the user can answer (none on a
    /// cancellation, a revision a later message updated, one not sent to this account or the user's own event), and
    /// not while it is declined, so the line goes the moment the user declines and comes back if they answer again. An
    /// all-day invitation, like an all-day event, marks its day rather than taking its hours, so it overlaps nothing,
    /// as the calendar's hatch says (`CalendarFit.invitationOverlap`).
    func mayOverlap(_ invitation: CalendarInvitation, reply: InvitationResponse?, superseded: Bool) -> Bool {
        let (canAnswer, response) = answer(invitation, reply: reply, superseded: superseded)
        return saysOverlap(invitation, canAnswer: canAnswer, response: response)
    }

    private func saysOverlap(_ invitation: CalendarInvitation, canAnswer: Bool, response: InvitationResponse?) -> Bool {
        canAnswer && response != .declined && !invitation.isAllDay && invitation.end > invitation.start
    }

    /// “Overlaps 1:1 with Sam, 13:30 - 14:00”: the first event the invitation overlaps, by when they meet, and the time
    /// the two share; “Overlaps Hiring sync, 11:00 - 11:30, and 2 more” when it overlaps others too. The time is this
    /// Mac's, as the When line's; it carries its day only when the two meet on another day than the invitation starts.
    /// Nil when it overlaps nothing.
    func overlapLine(_ overlap: CalendarFit.InvitationOverlap, startingOn day: Date, now: Date) -> String? {
        guard let first = overlap.overlaps.first else { return nil }
        let title = first.event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var line = "Overlaps " + (title.isEmpty ? "an event with no title" : title) + ", " + shared(first.interval, startingOn: day, now: now)
        let more = overlap.overlaps.count - 1
        if more > 0 { line += ", and \(more) more" }
        return line
    }

    /// “13:30 - 14:00” on the invitation's first day; “Wed 12 Nov, 00:30 - 01:00” on another; “Tue 11 Nov, 23:00 - Wed
    /// 12 Nov, 01:00” across midnight.
    private func shared(_ interval: DateInterval, startingOn day: Date, now: Date) -> String {
        let clock = self.clock(in: timeZone, now: now)
        // The end is exclusive: a time that ends at midnight ends on the day it started.
        let last = max(interval.start, interval.end.addingTimeInterval(-1))
        let times = clock.time(interval.start) + " - " + clock.time(interval.end)
        guard clock.calendar.isDate(last, inSameDayAs: interval.start) else {
            return clock.day(interval.start) + ", " + clock.time(interval.start) + " - " + clock.day(interval.end) + ", "
                + clock.time(interval.end)
        }
        return clock.calendar.isDate(interval.start, inSameDayAs: day) ? times : clock.day(interval.start) + ", " + times
    }

    /// “You, Ada Lovelace, Sam Lee, Tom Hughes +3 more”: the user first, the organizer left out (they have their own
    /// line), at most four names.
    private func guests(_ invitation: CalendarInvitation, isUser: (String) -> Bool) -> String? {
        let organizer = invitation.organizer?.address.lowercased()
        var seen: Set<String> = []
        var names: [String] = []
        var includesUser = false
        for person in invitation.attendees {
            let address = person.address.lowercased()
            guard address != organizer, seen.insert(address).inserted else { continue }
            if isUser(person.address) {
                includesUser = true
            } else {
                names.append(person.displayName)
            }
        }
        if includesUser { names.insert("You", at: 0) }
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(Self.guestsShown).joined(separator: ", ")
        let more = names.count - Self.guestsShown
        return more > 0 ? shown + " +\(more) more" : shown
    }

    /// The event in its own zone, named, when that zone is at another offset from this Mac's at the event's start; nil
    /// for all-day and floating events, which read the same everywhere.
    private func whenElsewhere(_ invitation: CalendarInvitation, now: Date) -> String? {
        guard !invitation.isFloating, let id = invitation.timeZoneID, let zone = TimeZone(identifier: id),
              zone.secondsFromGMT(for: invitation.start) != timeZone.secondsFromGMT(for: invitation.start) else { return nil }
        let name = zone.localizedName(for: .generic, locale: locale) ?? id
        return when(invitation, in: zone, now: now) + " " + name
    }

    /// “Tue 10 Nov · 15:00 – 16:00”, “Tue 10 Nov · All day”, “Tue 10 – Thu 12 Nov · All day”, “Tue 10 Nov, 22:00 –
    /// Wed 11 Nov, 02:00”; the year joins a day outside the current one.
    func when(_ invitation: CalendarInvitation, in zone: TimeZone, now: Date) -> String {
        let clock = self.clock(in: zone, now: now)
        let calendar = clock.calendar
        let day = clock.day
        let time = clock.time
        if invitation.isAllDay {
            // The end is exclusive: an event on the 10th ends at the start of the 11th.
            let lastDay = max(invitation.start, invitation.end.addingTimeInterval(-86_400))
            if calendar.isDate(lastDay, inSameDayAs: invitation.start) { return day(invitation.start) + " · All day" }
            return day(invitation.start) + " - " + day(lastDay) + " · All day"
        }
        if invitation.end <= invitation.start { return day(invitation.start) + " · " + time(invitation.start) }
        if calendar.isDate(invitation.end, inSameDayAs: invitation.start) {
            return day(invitation.start) + " · " + time(invitation.start) + " - " + time(invitation.end)
        }
        return day(invitation.start) + ", " + time(invitation.start) + " - " + day(invitation.end) + ", " + time(invitation.end)
    }

    /// The card's calendar in `zone`, and how it writes a day (“Tue 10 Nov”, with the year outside the current one) and
    /// a time (the system's 12- or 24-hour clock, spec §4.13).
    private func clock(in zone: TimeZone, now: Date) -> (calendar: Calendar, day: (Date) -> String, time: (Date) -> String) {
        var calendar = self.calendar
        calendar.timeZone = zone
        let thisYear = calendar.component(.year, from: now)
        let locale = self.locale
        func day(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = zone
            formatter.setLocalizedDateFormatFromTemplate(calendar.component(.year, from: date) == thisYear ? "EEEdMMM" : "EEEdMMMyyyy")
            return formatter.string(from: date)
        }
        func time(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.locale = locale
            formatter.timeZone = zone
            formatter.setLocalizedDateFormatFromTemplate("jmm")
            return formatter.string(from: date)
        }
        return (calendar, day, time)
    }
}
