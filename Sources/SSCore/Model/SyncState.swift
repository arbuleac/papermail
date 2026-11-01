import Foundation

/// Progress of the first full enumeration of an account. Bootstrap pages are provider-opaque.
public struct BootstrapState: Hashable, Codable, Sendable {
    public var startedAt: Date
    public var nextPage: String?
    public var pagesDone: Int
    public var messagesSeen: Int
    public var isComplete: Bool
    public init(startedAt: Date, nextPage: String? = nil, pagesDone: Int = 0, messagesSeen: Int = 0, isComplete: Bool = false) {
        self.startedAt = startedAt
        self.nextPage = nextPage
        self.pagesDone = pagesDone
        self.messagesSeen = messagesSeen
        self.isComplete = isComplete
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
    public init(accountID: AccountID, phase: AccountSyncPhase, lastSuccessfulSyncAt: Date? = nil, bootstrapProgress: Int? = nil, message: String? = nil) {
        self.accountID = accountID
        self.phase = phase
        self.lastSuccessfulSyncAt = lastSuccessfulSyncAt
        self.bootstrapProgress = bootstrapProgress
        self.message = message
    }
}
