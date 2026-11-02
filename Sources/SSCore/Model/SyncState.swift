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
    public init(startedAt: Date, nextPage: String? = nil, pagesDone: Int = 0, messagesSeen: Int = 0, isComplete: Bool = false,
                estimatedTotal: Int? = nil) {
        self.startedAt = startedAt
        self.nextPage = nextPage
        self.pagesDone = pagesDone
        self.messagesSeen = messagesSeen
        self.isComplete = isComplete
        self.estimatedTotal = estimatedTotal
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
    public init(accountID: AccountID, phase: AccountSyncPhase, lastSuccessfulSyncAt: Date? = nil, bootstrapProgress: Int? = nil,
                message: String? = nil, bootstrapTotal: Int? = nil, retryAt: Date? = nil) {
        self.accountID = accountID
        self.phase = phase
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.bootstrapProgress = bootstrapProgress
        self.message = message
        self.bootstrapTotal = bootstrapTotal
        self.retryAt = retryAt
    }
}
