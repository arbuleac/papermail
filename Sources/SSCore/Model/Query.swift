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
    /// Snoozed conversations (Later), soonest due first. Last, so the other views keep their `allCases` positions,
    /// which the menus use as tags.
    case later
}

public struct ConversationQuery: Hashable, Sendable {
    /// nil means every account (the unified view).
    public var accountIDs: [AccountID]?
    public var view: MailboxView
    /// nil means both sections.
    public var section: InboxSection?
    public var unreadOnly: Bool
    /// The search, parsed: full-text terms over subject, sender, recipients and body text, and operators on the
    /// conversation (`SearchQuery`). nil means no search. Its `in:` terms narrow `view`; choosing which view a
    /// search looks through is `ShellQuery`'s job.
    public var search: SearchQuery?
    public var limit: Int
    /// Paging: only conversations whose latest date (in the Inbox, `ConversationSummary.inboxDate`) is strictly
    /// before this. Later is never paged: it holds what the user snoozed, read whole.
    public var before: Date?
    /// The conversation the reader shows. A search's read-state terms (`is:unread`, `is:read`) never take it out of
    /// the results, so reading a result of an `is:unread` search does not pull it from under the reader and hand
    /// the selection to the next row, which would be read in turn. Everything else still applies to it: archiving
    /// it in an `in:inbox` search takes it out as usual. The list sets it; nil for every other caller.
    public var openConversationID: ConversationID?
    /// Conversations a search of the server found for the search's text (`MailClient.searchServer`). They stand in for
    /// the full-text match: listed with its hits whether or not their stored text holds the words, `from:`, `to:` and
    /// `subject:` terms, since the server's own search rules found them and a body not downloaded yet holds what it
    /// matched. Everything else still narrows them: the view, the account scope and the search's operators on the row
    /// (`is:`, `has:`, `before:`, `after:`, `in:`). Ignored without a search that has index terms to stand in for.
    public var serverMatches: Set<ConversationID>

    /// `searchText` is parsed as the search field's text is (`SearchQuery(parsing:)`), in the current calendar.
    public init(
        accountIDs: [AccountID]? = nil,
        view: MailboxView = .inbox,
        section: InboxSection? = nil,
        unreadOnly: Bool = false,
        searchText: String? = nil,
        limit: Int = 200,
        before: Date? = nil,
        serverMatches: Set<ConversationID> = []
    ) {
        self.accountIDs = accountIDs
        self.view = view
        self.section = section
        self.unreadOnly = unreadOnly
        self.search = searchText.flatMap { SearchQuery(parsing: $0) }
        self.limit = limit
        self.before = before
        self.serverMatches = serverMatches
    }

    /// The search as typed, trimmed; nil when there is no search.
    public var searchText: String? { search?.text }
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
    /// When a snooze brought it back to the Inbox, while it is still there and no newer mail has come
    /// (docs/DATA-MODEL.md, `returned_at`): the Inbox sorts it by this time, and its row says “Back” while unread.
    public var returnedAt: Date?
    /// When its snooze ends; set only in the Later view, whose rows read “Back Tue 09:00”.
    public var snoozedUntil: Date?
    /// Set only on a Drafts row that stands for a Send Later message (`SendLaterConversation`), whose time slot then
    /// reads “Sends Mon 09:00”.
    public var sendLater: SendLaterState?

    /// The date the Inbox sorts, pages and groups by, and its rows show: the latest message's, or the return's when
    /// that came later, so mail that comes back lands under Today rather than under the day it first arrived.
    public var inboxDate: Date {
        guard let returnedAt, returnedAt > latestDate else { return latestDate }
        return returnedAt
    }

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
        failedOperation: OperationKind? = nil,
        returnedAt: Date? = nil,
        snoozedUntil: Date? = nil,
        sendLater: SendLaterState? = nil
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
        self.returnedAt = returnedAt
        self.snoozedUntil = snoozedUntil
        self.sendLater = sendLater
    }
}
