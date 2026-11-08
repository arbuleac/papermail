import Foundation

/// Progress of the first full enumeration of an account. Bootstrap pages are provider-opaque.
public struct BootstrapState: Hashable, Codable, Sendable {
    public var startedAt: Date
    public var nextPage: String?
    public var pagesDone: Int
    public var messagesSeen: Int
    public var isComplete: Bool
    /// The provider's count of the mailbox when the enumeration began, if it gives one; kept so a resumed
    /// download still shows “3,412 of 8,120”. Absent in states stored before it was kept.
    public var estimatedTotal: Int?
    /// True when this enumeration re-checks a mailbox the store already holds, after the live lane's cursor was
    /// rejected: it refreshes stored messages instead of only adding missing ones, and when it completes it
    /// removes stored messages it never saw. Absent (nil, read as false) for a first download.
    public var reconciling: Bool?
    public init(startedAt: Date, nextPage: String? = nil, pagesDone: Int = 0, messagesSeen: Int = 0, isComplete: Bool = false,
                estimatedTotal: Int? = nil, reconciling: Bool? = nil) {
        self.startedAt = startedAt
        self.nextPage = nextPage
        self.pagesDone = pagesDone
        self.messagesSeen = messagesSeen
        self.isComplete = isComplete
        self.estimatedTotal = estimatedTotal
        self.reconciling = reconciling
    }
}

public enum AccountSyncPhase: String, Sendable {
    case idle
    case bootstrapping
    case syncing
    case hydrating
    case paused
    case needsReauth
    case error
}

public struct AccountSyncStatus: Hashable, Sendable {
    public var accountID: AccountID
    public var phase: AccountSyncPhase
    public var lastSuccessfulSyncAt: Date?
    public var bootstrapProgress: Int?
    public var message: String?
    /// While bootstrapping: the provider's estimate of how many messages the download covers, when it gives one
    /// (“Downloading · 3,412 of 8,120”). Nil when unknown.
    public var bootstrapTotal: Int?
    /// After a failed or throttled cycle: when the engine tries again (“Retrying in 30 s”). Cleared when the
    /// next cycle starts.
    public var retryAt: Date?
    /// While the backfill lane downloads older mail behind the live lane: how many messages its enumeration has
    /// covered so far. Nil when no backfill enumeration is running. `phase` describes the live lane only, so an
    /// account can be `idle` (new mail up to date) while this counts up.
    public var backfillProgress: Int?
    /// The provider's estimate of how many messages the backfill covers, when it gives one. Nil when unknown.
    public var backfillTotal: Int?
    /// Set while a throttle holds the backfill lane back, its own or one on the live lane (both spend the provider's
    /// quota): when it resumes. Only while the backfill has a request to make, so a pause after the download has
    /// finished never shows. The live lane's own throttle is in `phase`; it never waits for this.
    public var backfillPausedUntil: Date?
    /// True while the backfill lane, its listing done, is still downloading the bodies of mail already listed
    /// (“Up to date · downloading messages…”). Cleared once a batch finds no body missing.
    public var backfillDownloadingBodies: Bool
    public init(accountID: AccountID, phase: AccountSyncPhase, lastSuccessfulSyncAt: Date? = nil, bootstrapProgress: Int? = nil,
                message: String? = nil, bootstrapTotal: Int? = nil, retryAt: Date? = nil, backfillProgress: Int? = nil,
                backfillTotal: Int? = nil, backfillPausedUntil: Date? = nil, backfillDownloadingBodies: Bool = false) {
        self.accountID = accountID
        self.phase = phase
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.bootstrapProgress = bootstrapProgress
        self.message = message
        self.bootstrapTotal = bootstrapTotal
        self.retryAt = retryAt
        self.backfillProgress = backfillProgress
        self.backfillTotal = backfillTotal
        self.backfillPausedUntil = backfillPausedUntil
        self.backfillDownloadingBodies = backfillDownloadingBodies
    }
}
