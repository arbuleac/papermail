import Foundation

/// Where a send in the outbox is, as its Outbox row and its sheet say it (spec §5.53). Every send the provider has not
/// taken yet has one, from the moment Send is pressed; a `sent` row (the provider took it, and only its kept draft is
/// left to clear away) has none, so it leaves the Outbox at once.
///
/// A Send Later message waiting or missed reads as Drafts reads it (`SendLaterState`); the Outbox also shows what Drafts
/// never lists: an undo-send counting down, a send waiting to go again after a throttle or a failure that never left this
/// Mac, and one that failed, until it is kept in Drafts.
public enum OutboxState: Hashable, Sendable {
    /// Going now: in its undo window (the undo-send panel or the quick reply can still take it back), claimed by the send
    /// runner, or due and about to be: “Sending…”.
    case sending
    /// A Send Later message waiting for its time: “Sends Mon 09:00”.
    case waiting(until: Date)
    /// A Send Later message whose time passed while Paper was closed, waiting for the user: “Not sent”.
    case missed(Date)
    /// Put back to go again after a throttle, or after a failure before anything left this Mac (no connection, no token):
    /// “Retrying shortly”. `lastError` is the outbox's technical description of what stopped it; `isSendLater` when it is
    /// a Send Later message (it keeps its draft id while it goes), which Continue Editing can still take back.
    case retrying(lastError: String?, isSendLater: Bool)
    /// Failed after the request may have reached the provider, so it is never tried again: “Couldn't send”, in `danger`,
    /// for the moment until it is kept as a draft and its row cleared, when it leaves for Drafts (`FailedSend`).
    case failed(lastError: String?)

    /// The state `send` shows, or nil for a send the provider has taken (`sent`).
    ///
    /// A `scheduled` send is told apart by its error: the runner writes one whenever it puts a send back to go again, and
    /// a send queued from Send (or a Send Later message released by a stop) has none, so it is counting down or due.
    public init?(_ send: PendingSendSummary) {
        switch send.status {
        case .later: self = .waiting(until: send.sendAfter)
        case .missed: self = .missed(send.sendAfter)
        case .scheduled:
            self = send.lastError == nil ? .sending : .retrying(lastError: send.lastError, isSendLater: send.draftID != nil)
        case .sending: self = .sending
        case .failed: self = .failed(lastError: send.lastError)
        case .sent: return nil
        }
    }

    /// Still held for the user to change: a Send Later message waiting, missed, or put back to go again, whose draft
    /// Continue Editing opens, its schedule cancelled first, as from Drafts, where ↩ on that row takes it back too
    /// (`MailClient.cancelSend` takes a `scheduled` send). An undo-send is taken back by its own Undo: its panel or reply
    /// bar still watches it after its window, and would read it gone as sent.
    public var isHeld: Bool {
        switch self {
        case .waiting, .missed: return true
        case .retrying(_, let isSendLater): return isSendLater
        case .sending, .failed: return false
        }
    }

    /// It goes by itself, now or at its time; a missed or failed send waits for the user.
    public var goesByItself: Bool {
        switch self {
        case .sending, .waiting, .retrying: return true
        case .missed, .failed: return false
        }
    }
}
