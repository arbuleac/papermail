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
            guard !message.roles.contains(.drafts), !pending.contains(message.id), let invitation = bodies[message.id]?.invitation,
                  text.mayOverlap(invitation, reply: message.invitationReply, superseded: revisions.contains { $0.supersedes(invitation) }),
                  let pencil = CalendarFit.pencil(for: invitation, message: message.id, timeZone: timeZone) else { return nil }
            return InvitationOverlaps.Card(message: message.id, uid: invitation.uid, span: DateInterval(start: pencil.start, end: pencil.end))
        }
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
        for card in cards {
            // The invitation as the calendar draws it while it holds no copy: shown, so it can overlap.
            let pencil = CalendarEvent(id: CalendarFit.pencilID(for: card.message), accountID: card.message.accountID, providerID: nil,
                                       title: "", start: card.span.start, end: card.span.end, response: .needsAction,
                                       invitationUID: card.uid)
            guard let overlap = CalendarFit.invitationOverlap(uid: card.uid, near: card.span.start, in: events, pencil: pencil),
                  let line = text.overlapLine(overlap, startingOn: card.span.start, now: now) else { continue }
            lines[card.message] = line
        }
        return lines
    }
}
