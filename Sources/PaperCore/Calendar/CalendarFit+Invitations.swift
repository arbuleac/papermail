import Foundation

/// The selected conversation's invitation on the calendar: pencilled in from the mail when no calendar event is it
/// yet, and checked for what it overlaps (the hatch on it, and "Overlaps 1:1 with Sam, 13:30 - 14:00" on the reader's
/// card).
extension CalendarFit {
    /// The invitation's event and the busy events it overlaps.
    public struct InvitationOverlap: Hashable, Sendable {
        public struct Overlap: Hashable, Sendable {
            public var event: CalendarEvent
            /// Where the two meet.
            public var interval: DateInterval
        }

        /// The calendar's event with the invitation's UID, or the pencil drawn from the mail when there is none.
        public var event: CalendarEvent
        /// By the start of the overlap, then its end, then the other event's id. Empty when the event is not drawn
        /// (declined) or is all-day.
        public var overlaps: [Overlap]
    }

    /// The invitation the selected mail carries, as an event the fit lays out (pencilled: `response` defaults to the
    /// answer the mail stated, `needsAction` when none) with an id of its own that no calendar event can have
    /// (`isPencil`). Nil for a cancellation. Only the selected conversation's invitation is pencilled, so the pencil
    /// names no message: `sourceMessage` stays nil, or the event would read as time set aside (`isSetAside`) and offer
    /// Remove.
    ///
    /// A floating invitation's times (written without a zone) are wall-clock times held as UTC: they are read on
    /// `timeZone` (the Mac's) so they line up with real instants. An all-day one stays floating, as an all-day
    /// `CalendarEvent` is held.
    public static func pencil(
        for invitation: CalendarInvitation,
        message: MessageID,
        timeZone: TimeZone,
        response: CalendarEvent.Response? = nil
    ) -> CalendarEvent? {
        guard !invitation.isCancelled else { return nil }
        var start = invitation.start
        var end = invitation.end
        if invitation.isFloating, !invitation.isAllDay {
            start = wallClock(start, on: timeZone)
            end = wallClock(end, on: timeZone)
        }
        let answer: CalendarEvent.Response = response ?? {
            if invitation.userIsOrganizer { return .organizer }
            switch invitation.userResponse {
            case .accepted: return .accepted
            case .tentative: return .tentative
            case .declined: return .declined
            case .needsAction, nil: return .needsAction
            }
        }()
        return CalendarEvent(
            id: pencilID(for: message),
            accountID: message.accountID,
            providerID: nil,
            title: invitation.title,
            location: invitation.location,
            start: start,
            end: max(start, end),
            isAllDay: invitation.isAllDay,
            response: answer,
            // The card keeps any web meeting link; the calendar's Join opens only https, so it offers no other.
            joinURL: invitation.conferenceURL.flatMap { CalendarInvitationReader.webAddress($0)?.scheme?.lowercased() == "https" ? $0 : nil },
            organizer: invitation.organizer?.displayName,
            invitationUID: invitation.uid,
            // Where it was written, so its details say the time there too.
            timeZone: invitation.isAllDay ? nil : invitation.timeZoneID.flatMap { TimeZone(identifier: $0) == nil ? nil : $0 }
        )
    }

    /// The id of the pencil drawn from `message`'s invitation. Calendar events' ids are an account id (a UUID) and a
    /// provider or local id, so this prefix never meets one.
    public static func pencilID(for message: MessageID) -> String {
        "\(pencilPrefix)\(message.accountID.rawValue)|\(message.providerID)"
    }

    /// Drawn from mail (`pencil(for:message:timeZone:response:)`), not read from a calendar: a click on it shows its
    /// mail rather than an event's details.
    public static func isPencil(_ event: CalendarEvent) -> Bool {
        event.providerID == nil && event.id.hasPrefix(pencilPrefix)
    }

    private static let pencilPrefix = "invitation|"

    /// The selected conversation's invitation and what it overlaps. The invitation's event is the event with `uid`
    /// (of a repeating invitation, the occurrence whose start is nearest `start`, when given), else `pencil`; nil when
    /// there is neither.
    ///
    /// An overlap is a busy event (`CalendarEvent.isBusy`: not declined, free or all-day) that meets the invitation's
    /// event for some time, other than an occurrence of the invitation itself (the same UID, as `InvitationUID` compares
    /// them). Nothing overlaps an invitation the user declined or an all-day one.
    public static func invitationOverlap(
        uid: String,
        near start: Date? = nil,
        in events: [CalendarEvent],
        pencil: CalendarEvent? = nil,
        accountID: AccountID? = nil
    ) -> InvitationOverlap? {
        // The copy that is the invitation's event is its own account's (an answer writes one account's rows, so another
        // account's copy says another answer); no copy of the same meeting, in any account, is ever an overlap.
        let own = events.filter {
            InvitationUID.matches($0.invitationUID, uid) && $0.sync != .deleting && (accountID == nil || $0.accountID == accountID)
        }
        let matched: CalendarEvent?
        if let start {
            matched = own.min { a, b in
                abs(a.start.timeIntervalSince(start)) < abs(b.start.timeIntervalSince(start))
            }
        } else {
            matched = own.first
        }
        guard let event = matched ?? pencil else { return nil }
        guard event.isShown, !event.isAllDay else { return InvitationOverlap(event: event, overlaps: []) }

        var overlaps: [InvitationOverlap.Overlap] = []
        for other in events where other.isBusy && !InvitationUID.matches(other.invitationUID, uid) && other.id != event.id {
            let from = max(other.start, event.start)
            let to = min(other.end, event.end)
            guard from < to else { continue }
            overlaps.append(.init(event: other, interval: DateInterval(start: from, end: to)))
        }
        overlaps.sort { a, b in
            if a.interval.start != b.interval.start { return a.interval.start < b.interval.start }
            if a.interval.end != b.interval.end { return a.interval.end < b.interval.end }
            return a.event.id < b.event.id
        }
        return InvitationOverlap(event: event, overlaps: overlaps)
    }

    /// The instant `timeZone`'s clock shows the wall-clock time `floating` holds as UTC.
    private static func wallClock(_ floating: Date, on timeZone: TimeZone) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
        var local = utc
        local.timeZone = timeZone
        let parts = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: floating)
        return local.date(from: parts) ?? floating
    }
}
