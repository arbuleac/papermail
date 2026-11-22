import Foundation

/// Where an account's calendar stands (`AccountSyncStatus.calendar`): what the day column's foot says and whether it
/// offers Connect. Mail sync never waits on it, and a calendar failure never changes the mail phase.
public enum CalendarSyncState: Hashable, Sendable {
    /// Not read yet in this run (the first read rides the account's first live cycle).
    case unknown
    /// The account has not granted the calendar scope (`AccountPermission.calendar`): Connect asks for it.
    case notConnected
    /// Google refused the read because the Calendar API is not enabled for the OAuth client the user registered
    /// (docs/OAUTH-SETUP.md step 1): nothing on this Mac can fix it, so the foot says where to turn it on.
    case apiDisabled
    /// Read at this instant; the store holds the account's events for the window.
    case current(Date)
    /// The last read failed for another reason (the network, a throttle, the service); the events stored stay shown
    /// and the next cycle tries again. `lastRead` is the last read that went through, if any.
    case failing(lastRead: Date?)
}
