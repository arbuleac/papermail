import Foundation

/// The invitation card's overlap line (spec §5.14): which cards can say what they overlap, and what each says, from the
/// calendar events the store holds over their times. Kept apart from `build` so the reader reads the calendar once per
/// render, and can check a change to the calendar against the cards it rendered without building a payload.
extension RenderPayloadBuilder {
    /// The cards of `messages` that can carry the line: as `build` shows them (trash and spam filtered, no card on a
    /// draft or a reply still in the outbox), one the user can answer and has not declined, and taking hours of a day
    /// (`InvitationCardText.mayOverlap`). Each with its time as instants, a time written without a zone read on this
    /// Mac's clock (`CalendarFit.pencil`), as the calendar draws the same invitation.
    public func overlapCards(messages: [MessageMetadata], bodies: [MessageID: StoredBody],
                             pending: Set<MessageID> = []) -> [InvitationOverlaps.Card] {
        let visible = Self.visibleMessages(messages)
        let revisions = visible.compactMap { bodies[$0.id]?.invitation }
        guard !revisions.isEmpty else { return [] }
        let text = InvitationCardText(calendar: calendar, locale: locale, timeZone: timeZone)
        return visible.compactMap { message in
            guard !message.roles.contains(.drafts), !pending.contains(message.id), let invitation = bodies[message.id]?.invitation
            else { return nil }
            let superseded = revisions.contains { $0.supersedes(invitation) }
            // Every card that can answer reads the calendar, for its copy's answer; fewer say an overlap.
            guard invitation.isAnswerable, !superseded,
                  let pencil = CalendarFit.pencil(for: invitation, message: message.id, timeZone: timeZone) else { return nil }
            return InvitationOverlaps.Card(message: message.id, uid: invitation.uid, span: DateInterval(start: pencil.start, end: pencil.end),
                                           mayOverlap: text.mayOverlap(invitation, reply: message.invitationReply, superseded: superseded))
        }
    }

    /// What each card's calendar copy says, from `events` (`InvitationCalendarAnswer`): the card shows it chosen.
    public func calendarAnswers(for cards: [InvitationOverlaps.Card], events: [CalendarEvent]) -> [MessageID: InvitationResponse] {
        var answers: [MessageID: InvitationResponse] = [:]
        for card in cards {
            if let answer = InvitationCalendarAnswer.response(uid: card.uid, near: card.span.start, accountID: card.message.accountID,
                                                              in: events) {
                answers[card.message] = answer
            }
        }
        return answers
    }

    /// Each card's line, from `events`: the store's events of every account over `InvitationOverlaps.interval`. What
    /// counts is what the calendar's hatch counts (`CalendarFit.invitationOverlap`): every busy event the invitation's
    /// event meets, never the invitation's own (the calendar's copy, by its UID, is the invitation's event when it holds
    /// one), a declined, free, all-day one or one being deleted; none when the calendar's copy is declined.
    public func overlapLines(for cards: [InvitationOverlaps.Card], events: [CalendarEvent],
                             now: Date = Date()) -> [MessageID: String] {
        guard !cards.isEmpty else { return [:] }
        let text = InvitationCardText(calendar: calendar, locale: locale, timeZone: timeZone)
        var lines: [MessageID: String] = [:]
        for card in cards where card.mayOverlap {
            // The invitation as the calendar draws it while it holds no copy: shown, so it can overlap.
            let pencil = CalendarEvent(id: CalendarFit.pencilID(for: card.message), accountID: card.message.accountID, providerID: nil,
                                       title: "", start: card.span.start, end: card.span.end, response: .needsAction,
                                       invitationUID: card.uid)
            guard let overlap = CalendarFit.invitationOverlap(uid: card.uid, near: card.span.start, in: events, pencil: pencil,
                                                              accountID: card.message.accountID),
                  let line = text.overlapLine(overlap, startingOn: card.span.start, now: now) else { continue }
            lines[card.message] = line
        }
        return lines
    }

    /// One overlap's words as the reader's card writes them (“Overlaps an event with no title, Wed 12 Nov, 00:30 -
    /// 01:00”), for the week's invitation card, which says the same (spec §5.54); `day` is the invitation's start.
    public func overlapLine(_ overlap: CalendarFit.InvitationOverlap, startingOn day: Date, now: Date = Date()) -> String? {
        InvitationCardText(calendar: calendar, locale: locale, timeZone: timeZone).overlapLine(overlap, startingOn: day, now: now)
    }
}
