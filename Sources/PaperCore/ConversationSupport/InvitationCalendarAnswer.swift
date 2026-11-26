import Foundation

/// The answer the calendar's copy of an invitation says (spec §5.14): the reader's card shows it before the message's
/// own reply or what the invitation stated, since the copy carries a pending local answer too (pending answers win), an
/// answer given in an event's details, on the phone or by the provider. Pure.
public enum InvitationCalendarAnswer {
    /// The copy is the same account's `synced` event the user did not organize whose UID matches the invitation's, the
    /// occurrence nearest the invitation's start (for a RECURRENCE-ID invitation, that occurrence); nil without one, or
    /// when it says no answer yet.
    public static func response(uid: String, near start: Date, accountID: AccountID, in events: [CalendarEvent]) -> InvitationResponse? {
        let copies = events.filter { event in
            event.accountID == accountID && event.sync == .synced && event.response != .organizer
                && InvitationUID.matches(event.invitationUID, uid)
        }
        guard let nearest = copies.min(by: { abs($0.start.timeIntervalSince(start)) < abs($1.start.timeIntervalSince(start)) })
        else { return nil }
        switch nearest.response {
        case .accepted: return .accepted
        case .tentative: return .tentative
        case .declined: return .declined
        case .needsAction, .organizer: return nil
        }
    }
}
