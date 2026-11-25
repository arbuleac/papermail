import Foundation

/// The calendar rows an invitation answer shows on at once, what each said before it (a give-up puts that back), and,
/// for an answer no message carries, the provider's event to answer (docs/DATA-MODEL.md, "Invitation answers"). Kept in
/// the answer itself (`InvitationAnswer.calendar`), so the outbox is the one place a pending answer lives: nothing on
/// `calendar_events` says an answer waits.
public struct CalendarCopies: Hashable, Codable, Sendable {
    public enum Scope: Hashable, Codable, Sendable {
        /// The invitation's rows by UID (`InvitationUID.matches`): every occurrence, or only the one whose start is
        /// nearest `near` (an answer to one occurrence).
        case invitation(uid: String, near: Date?)
        /// One row by local id: a single event, or one occurrence (This Event).
        case event(id: String)
        /// Every row of the account whose `seriesID` is this (All Events).
        case series(id: String)
    }

    public var scope: Scope
    /// The provider's event to answer when no message carries the answer: Google's instance id or `recurringEventId`,
    /// Graph's occurrence id or `seriesMasterId`. Nil for an answer that goes through its message.
    public var providerEventID: String?
    /// Written by the store in the enqueue's transaction: every row the scope covered then, with the answer it had
    /// (rows that already said this answer included, with it). A give-up puts these back.
    public var previous: [String: CalendarEvent.Response]

    public init(scope: Scope, providerEventID: String? = nil, previous: [String: CalendarEvent.Response] = [:]) {
        self.scope = scope
        self.providerEventID = providerEventID
        self.previous = previous
    }
}
