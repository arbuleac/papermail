import Foundation

/// The words of the invitation card (spec §5.14) from a stored invitation: when it is, in this Mac's zone and, when it
/// differs, the event's own; who organized it and who else is invited; which answer is chosen and whether one can be
/// given. Pure and cheap: the facts were read at sync time, so nothing here reads iCalendar.
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
    func card(for invitation: CalendarInvitation, reply: InvitationResponse?, ownAddresses: Set<String>, needsPermission: Bool,
              superseded: Bool = false, now: Date) -> RenderPayload.Invitation {
        let canAnswer = invitation.isAnswerable && !superseded
        let stated = invitation.userResponse.flatMap { $0.isAnswer ? $0 : nil }
        let response = canAnswer ? (reply.flatMap { $0.isAnswer ? $0 : nil } ?? stated) : nil
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
            canOpen: invitation.calendarText?.isEmpty == false
        )
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
        var calendar = self.calendar
        calendar.timeZone = zone
        let thisYear = calendar.component(.year, from: now)
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
        if invitation.isAllDay {
            // The end is exclusive: an event on the 10th ends at the start of the 11th.
            let lastDay = max(invitation.start, invitation.end.addingTimeInterval(-86_400))
            if calendar.isDate(lastDay, inSameDayAs: invitation.start) { return day(invitation.start) + " · All day" }
            return day(invitation.start) + " – " + day(lastDay) + " · All day"
        }
        if invitation.end <= invitation.start { return day(invitation.start) + " · " + time(invitation.start) }
        if calendar.isDate(invitation.end, inSameDayAs: invitation.start) {
            return day(invitation.start) + " · " + time(invitation.start) + " – " + time(invitation.end)
        }
        return day(invitation.start) + ", " + time(invitation.start) + " – " + day(invitation.end) + ", " + time(invitation.end)
    }
}
