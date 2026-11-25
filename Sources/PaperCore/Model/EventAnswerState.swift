import Foundation

/// Where the user's newest answer to an event stands in the outbox, derived from it, never stored.
public enum EventAnswerState: Hashable, Sendable {
    /// An answer on its way (pending, in flight or uncertain).
    case live(InvitationResponse)
    /// The newest answer covering the event was given up (and not yet pruned): the row has its old answer back.
    case failed
}
