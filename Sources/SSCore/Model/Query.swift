import Foundation

/// The views the UI can ask for. There is deliberately no folder or label view.
public enum MailboxView: String, Codable, Sendable, CaseIterable {
    /// Conversations with at least one message whose roles include `inbox` and exclude trash/spam.
    case inbox
    case starred
    case sent
    case drafts
    case trash
    /// Everything except trash and spam ("All mail").
    case all
}

public struct ConversationQuery: Hashable, Sendable {
    /// nil means every account (the unified view).
    public var accountIDs: [AccountID]?
    public var view: MailboxView
    /// nil means both sections.
    public var section: InboxSection?
    public var unreadOnly: Bool
    /// Full-text search over subject, participants and body text. nil or empty means no search.
    public var searchText: String?
    public var limit: Int
    /// Paging: only conversations whose latest date is strictly before this.
    public var before: Date?

    public init(
        accountIDs: [AccountID]? = nil,
        view: MailboxView = .inbox,
        section: InboxSection? = nil,
        unreadOnly: Bool = false,
        searchText: String? = nil,
        limit: Int = 200,
        before: Date? = nil
    ) {
        self.accountIDs = accountIDs
        self.view = view
        self.section = section
        self.unreadOnly = unreadOnly
        self.searchText = searchText
        self.limit = limit
        self.before = before
    }
}

/// One row of the message list. Denormalized so the list needs no joins.
public struct ConversationSummary: Hashable, Sendable, Identifiable {
    public var id: ConversationID
    public var subject: String
    public var snippet: String
    /// Distinct senders in date order, oldest first. The list shows the last one or two.
    public var participants: [EmailAddress]
    public var latestDate: Date
    public var messageCount: Int
    public var unreadCount: Int
    public var isStarred: Bool
    public var hasAttachments: Bool
    public var inInbox: Bool
    public var inboxSection: InboxSection
    public var latestMessageID: MessageID
    public var hasPendingOperations: Bool
    /// The kind of the newest failed operation on this conversation the user has not seen yet, for the row's
    /// failed glyph and its “Couldn't archive” copy. Set in the transaction that marks an operation failed;
    /// cleared by `MailStoring.acknowledgeFailedOperation(conversationID:)`, by a later operation on the
    /// conversation being confirmed, or by the failed row being pruned (docs/DATA-MODEL.md, `failed_op_kind`).
    public var failedOperation: OperationKind?

    public init(
        id: ConversationID,
        subject: String,
        snippet: String,
        participants: [EmailAddress],
        latestDate: Date,
        messageCount: Int,
        unreadCount: Int,
        isStarred: Bool,
        hasAttachments: Bool,
        inInbox: Bool,
        inboxSection: InboxSection,
        latestMessageID: MessageID,
        hasPendingOperations: Bool,
        failedOperation: OperationKind? = nil
    ) {
        self.id = id
        self.subject = subject
        self.snippet = snippet
        self.participants = participants
        self.latestDate = latestDate
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.isStarred = isStarred
        self.hasAttachments = hasAttachments
        self.inInbox = inInbox
        self.inboxSection = inboxSection
        self.latestMessageID = latestMessageID
        self.hasPendingOperations = hasPendingOperations
        self.failedOperation = failedOperation
    }
}
