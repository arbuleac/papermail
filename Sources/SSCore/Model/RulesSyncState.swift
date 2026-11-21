import Foundation

/// Where an account's server rules stand (`AccountSyncStatus.rules`): what Settings › Senders shows beside the mirror the
/// store keeps. Mail sync never waits on it, and a rules failure never changes the mail phase.
public enum RulesSyncState: Hashable, Sendable {
    /// Not read yet in this run (the first read rides the account's first live cycle).
    case unknown
    /// The account has not granted the rules scope (`AccountPermission.rules`): rules set on this Mac wait, and a
    /// reconnect asks for it.
    case notConnected
    /// Read at `readAt`; the store's mirror holds the server's sender rules, and the server has `otherCount` rules besides
    /// that this app does not show (a Gmail filter that labels, an Outlook rule with conditions of its own).
    case upToDate(otherCount: Int, readAt: Date)
    /// The last turn failed: the failure's words for the user, and the other rules the last read in this run counted, if
    /// any. A refused write is reported here until the next read goes through.
    case failed(RulesSyncFailure, otherCount: Int?)

    /// The other rules the server had at the last read in this run, if any.
    public var otherCount: Int? {
        switch self {
        case .upToDate(let count, _): return count
        case .failed(_, let count): return count
        case .unknown, .notConnected: return nil
        }
    }
}
