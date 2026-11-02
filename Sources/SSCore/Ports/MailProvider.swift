import Foundation

/// One page of the first enumeration. Newest messages come first so the inbox paints early.
public struct BootstrapPage: Sendable {
    public var messages: [MessageMetadata]
    /// nil when enumeration is complete.
    public var nextPage: String?
    /// Returned on the first page only: the cursor from which `changes(since:)` continues without gaps.
    /// Providers must capture it before enumerating.
    public var changeCursor: String?
    /// Returned on the first page when the provider can say it cheaply: about how many messages the
    /// enumeration covers, for “Downloading · 3,412 of 8,120”. An estimate, never a promise.
    public var estimatedTotal: Int?
    public init(messages: [MessageMetadata], nextPage: String?, changeCursor: String?, estimatedTotal: Int? = nil) {
        self.messages = messages
        self.nextPage = nextPage
        self.changeCursor = changeCursor
        self.estimatedTotal = estimatedTotal
    }
}

/// Changes since a cursor. Upserts carry full metadata (providers hydrate internally).
public struct ChangesPage: Sendable {
    public var upserts: [MessageMetadata]
    public var deletedIDs: [String]
    public var cursor: String
    public var hasMore: Bool
    public init(upserts: [MessageMetadata], deletedIDs: [String], cursor: String, hasMore: Bool) {
        self.upserts = upserts
        self.deletedIDs = deletedIDs
        self.cursor = cursor
        self.hasMore = hasMore
    }
}

/// Everything the engine needs from a mail service. One instance per account.
///
/// Implementations are stateless beyond their account id and token source; all persistence is the store's job.
/// Cursors and pages are opaque strings the provider defines (JSON is fine). Message ids are provider ids
/// (`MessageID.providerID`), never local ids.
public protocol MailProvider: Sendable {
    var accountID: AccountID { get }
    var kind: ProviderKind { get }

    func profile() async throws -> AccountProfile

    /// Enumerate the mailbox newest first, excluding spam and trash. `page == nil` starts a new enumeration and
    /// must return `changeCursor`. `limit` is a hint, never exceeded.
    func bootstrap(page: String?, limit: Int) async throws -> BootstrapPage

    /// Changes since `cursor`. Throws `ProviderError.resetRequired` when the cursor is stale.
    func changes(since cursor: String, limit: Int) async throws -> ChangesPage

    /// Metadata for specific messages. Unknown ids are omitted, not thrown.
    func metadata(for providerIDs: [String]) async throws -> [MessageMetadata]

    func body(for providerID: String) async throws -> MessageBody

    func attachment(messageID providerID: String, attachmentID: String) async throws -> Data

    /// Apply a change to the given messages. Must be idempotent: applying twice is harmless.
    func apply(_ change: MetadataChange, to providerIDs: [String]) async throws

    func send(_ message: OutgoingMessage) async throws -> SendReceipt

    /// Server-side search returning provider message ids, newest first.
    func search(_ text: String, limit: Int) async throws -> [String]
}
