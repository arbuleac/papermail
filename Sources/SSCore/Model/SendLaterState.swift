import Foundation

/// Where a Send Later message is, as its Drafts row and its draft sheet say it (spec §5.23, “Send Later”).
public enum SendLaterState: Hashable, Sendable {
    /// Waiting for its time: “Sends Mon 09:00”.
    case waiting(until: Date)
    /// Its time passed while SuperSparrow was closed; it waits for the user to say whether it goes: “Not sent”.
    case missed(Date)
    /// Its time came and it is on its way (or waits out a throttle's retry): “Sending…”.
    case sending

    /// The state a send in the outbox shows, or nil for one that is not a Send Later message on its way: an undo-send,
    /// or one that has left or failed. A Send Later message keeps its draft id while it goes, which is how one that a
    /// throttle put back in the outbox (`scheduled`) is still told apart from an undo-send.
    public init?(_ send: PendingSendSummary) {
        switch send.status {
        case .later: self = .waiting(until: send.sendAfter)
        case .missed: self = .missed(send.sendAfter)
        case .scheduled, .sending:
            guard send.draftID != nil else { return nil }
            self = .sending
        case .sent, .failed:
            return nil
        }
    }

    /// Still held, so opening it, Cancel and Discard can take it back.
    public var isHeld: Bool {
        switch self {
        case .waiting, .missed: return true
        case .sending: return false
        }
    }
}
