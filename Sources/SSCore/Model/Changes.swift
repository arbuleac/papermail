import Foundation

/// A user intent that changes message state. Applied locally first, then replayed to the provider.
public enum MetadataChange: Hashable, Codable, Sendable {
    /// Remove from the inbox. Gmail: remove INBOX label. Graph: move to the Archive folder.
    case archive
    /// Put back in the inbox. Gmail: add INBOX label. Graph: move to Inbox.
    case moveToInbox
    case setRead(Bool)
    case setStarred(Bool)
    /// Gmail: add TRASH label. Graph: move to Deleted Items.
    case trash
    /// Gmail: remove TRASH, add INBOX. Graph: move to Inbox.
    case restoreFromTrash
}

/// The local effect of a change. This is the single source of truth for optimistic state; providers
/// are expected to converge to the same result.
public func applying(_ change: MetadataChange, to metadata: MessageMetadata) -> MessageMetadata {
    var m = metadata
    switch change {
    case .archive:
        m.roles.remove(.inbox)
    case .moveToInbox:
        m.roles.remove(.trash)
        m.roles.remove(.spam)
        m.roles.insert(.inbox)
    case .setRead(let read):
        m.isRead = read
    case .setStarred(let starred):
        m.isStarred = starred
    case .trash:
        m.roles.remove(.inbox)
        m.roles.remove(.spam)
        m.roles.insert(.trash)
    case .restoreFromTrash:
        m.roles.remove(.trash)
        m.roles.insert(.inbox)
    }
    return m
}

public enum OperationStatus: String, Codable, Sendable {
    case pending
    case inFlight
    case confirmed
    case failed
    /// The provider may or may not have applied it; the next sync decides.
    case uncertain
}

/// A queued metadata change (the outbox). One operation targets messages of exactly one account.
public struct Operation: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var accountID: AccountID
    public var change: MetadataChange
    public var targets: [MessageID]
    public var createdAt: Date
    public var status: OperationStatus
    public var attempts: Int
    public var lastError: String?
    public var nextAttemptAt: Date?

    public init(
        id: String = UUID().uuidString,
        accountID: AccountID,
        change: MetadataChange,
        targets: [MessageID],
        createdAt: Date = Date(),
        status: OperationStatus = .pending,
        attempts: Int = 0,
        lastError: String? = nil,
        nextAttemptAt: Date? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.change = change
        self.targets = targets
        self.createdAt = createdAt
        self.status = status
        self.attempts = attempts
        self.lastError = lastError
        self.nextAttemptAt = nextAttemptAt
    }
}
