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
    /// The counted requests this call made, for providers whose cost is per request (Graph's first page also looks up
    /// the system folders and lists the top of the folder tree); nil means one listing call plus per-message
    /// metadata as the quota prices it. The engine charges it to whichever lane asked.
    public var requestCount: Int?
    public init(messages: [MessageMetadata], nextPage: String?, changeCursor: String?, estimatedTotal: Int? = nil,
                requestCount: Int? = nil) {
        self.messages = messages
        self.nextPage = nextPage
        self.changeCursor = changeCursor
        self.estimatedTotal = estimatedTotal
        self.requestCount = requestCount
    }
}

/// One page of the backfill: the older mail the engine downloads behind the live lane, newest first.
///
/// A provider whose listing is cheap without metadata (Gmail lists ids for 5 quota units, then charges 20 per
/// message) returns ids only, so the engine fetches metadata just for the messages the store lacks, in small
/// paced chunks. A provider whose listing already carries metadata (Graph) returns it in `messages`.
public struct BackfillListing: Sendable {
    /// Provider ids on this page, newest first.
    public var ids: [String]
    /// Metadata for `ids` when the listing carries it; nil when the engine must call `metadata(for:)`.
    public var messages: [MessageMetadata]?
    /// nil when the enumeration is complete.
    public var nextPage: String?
    public init(ids: [String], messages: [MessageMetadata]?, nextPage: String?) {
        self.ids = ids
        self.messages = messages
        self.nextPage = nextPage
    }
}

/// Changes since a cursor. Upserts carry full metadata (providers hydrate internally).
public struct ChangesPage: Sendable {
    public var upserts: [MessageMetadata]
    public var deletedIDs: [String]
    public var cursor: String
    public var hasMore: Bool
    /// The counted requests this call made, for providers whose cost is per request (Graph counts every delta GET
    /// and every `$batch` part against the mailbox's limit, and one call can send a hundred); nil means one call
    /// plus per-message metadata as the quota prices it. The engine paces its live lane by it.
    public var requestCount: Int?
    /// Folders the provider stopped polling because they are gone (a Graph folder whose delta answers 404, or one two
    /// folder walks in a row did not find). No delta will report their mail again, purged with them or not, so the
    /// engine looks up the messages it stores in them (`MessageMetadata.folderID`).
    public var goneFolders: [String]
    public init(upserts: [MessageMetadata], deletedIDs: [String], cursor: String, hasMore: Bool, requestCount: Int? = nil,
                goneFolders: [String] = []) {
        self.upserts = upserts
        self.deletedIDs = deletedIDs
        self.cursor = cursor
        self.hasMore = hasMore
        self.requestCount = requestCount
        self.goneFolders = goneFolders
    }
}

/// What a lookup by id found (`MailProvider.lookUpMetadata(for:)`). An id in neither list is one the provider does
/// not know: gone.
public struct MetadataLookup: Sendable {
    public var messages: [MessageMetadata]
    /// Ids the provider would not return on their own for now: refused for that message alone (Graph's 403 for one
    /// item, a reply that does not decode) or failing in the service. Nothing says they are gone.
    public var unreadable: [String]
    public init(messages: [MessageMetadata], unreadable: [String] = []) {
        self.messages = messages
        self.unreadable = unreadable
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

    /// A later page of the enumeration `bootstrap(page: nil, limit:)` started, for the backfill. `page` is a
    /// `nextPage` from `bootstrap` or from an earlier listing, and `limit` is the same hint the enumeration
    /// started with. The default implementation calls `bootstrap(page:limit:)` and returns its metadata inline.
    func backfillListing(page: String, limit: Int) async throws -> BackfillListing

    /// Whether the enumeration leaves out mail the store can hold and only this provider's changes from before a reset
    /// would report: Gmail's Spam and Trash, which history reports when mail lands there. A reconcile then lists those
    /// ids too (`mailOutsideEnumeration`), so its sweep keeps what the provider still has rather than deleting it with
    /// nothing to bring it back. False by default: Graph's fresh cursor seeds Deleted Items and Junk again.
    var hasMailOutsideEnumeration: Bool { get }

    /// The ids of that mail, without metadata, a page at a time (`page` nil starts; `nextPage` nil ends). The default
    /// lists none.
    func mailOutsideEnumeration(page: String?, limit: Int) async throws -> BackfillListing

    /// Changes since `cursor`. Throws `ProviderError.resetRequired` when the cursor is stale.
    func changes(since cursor: String, limit: Int) async throws -> ChangesPage

    /// Metadata for specific messages. Unknown ids are omitted, not thrown, and so is a message the provider will not
    /// return on its own (refused or failing for that one message): one such message must not fail a search or a
    /// backfill page. A throttle, a refused token or the network still fails the call.
    func metadata(for providerIDs: [String]) async throws -> [MessageMetadata]

    /// As `metadata(for:)`, saying which ids it left out without knowing them gone, for a caller that deletes what the
    /// provider no longer has (a reconcile's lost targets). The default reports none.
    func lookUpMetadata(for providerIDs: [String]) async throws -> MetadataLookup

    func body(for providerID: String) async throws -> MessageBody

    /// The attachment's bytes in one piece. The default `downloadAttachment` builds on it, so a provider whose
    /// files are small or already at hand (the demo) needs nothing else.
    func attachment(messageID providerID: String, attachmentID: String) async throws -> Data

    /// Downloads an attachment into `destination`, a file that does not exist yet in a folder that does, reporting
    /// through `progress` how far it has got: fractions from 0 to 1, rising, ending at 1 once the file is complete,
    /// and nothing at all when the provider cannot tell how large the download is. `expectedSize` is the size the
    /// body listed (`AttachmentInfo.sizeBytes`), 0 when unknown. On a throw nothing is left at `destination`. Any
    /// working file goes beside it, named after it, and is gone when this returns; a run cut off by quitting
    /// leaves both to the caller's sweep.
    /// The default implementation writes `attachment(messageID:attachmentID:)` and reports nothing; providers
    /// that stream the file from the network override it, so the whole file never sits in memory.
    func downloadAttachment(messageID providerID: String, attachmentID: String, expectedSize: Int, to destination: URL,
                            progress: @escaping @Sendable (Double) -> Void) async throws

    /// Apply a change to the given messages. Must be idempotent: applying twice is harmless.
    func apply(_ change: MetadataChange, to providerIDs: [String]) async throws

    /// The permission `change` needs that the account has not granted, or nil when it can go out. Asked before every
    /// replay without a request (the granted scopes come with the token), so a change waiting for the user's
    /// permission costs nothing while it waits. The default needs none.
    func missingPermission(for change: MetadataChange) async -> AccountPermission?

    func send(_ message: OutgoingMessage) async throws -> SendReceipt

    /// Server-side search returning provider message ids, newest first.
    func search(_ text: String, limit: Int) async throws -> [String]
}

extension MailProvider {
    public func missingPermission(for change: MetadataChange) async -> AccountPermission? {
        nil
    }

    public func lookUpMetadata(for providerIDs: [String]) async throws -> MetadataLookup {
        MetadataLookup(messages: try await metadata(for: providerIDs))
    }

    public var hasMailOutsideEnumeration: Bool {
        false
    }

    public func mailOutsideEnumeration(page: String?, limit: Int) async throws -> BackfillListing {
        BackfillListing(ids: [], messages: nil, nextPage: nil)
    }

    public func downloadAttachment(messageID providerID: String, attachmentID: String, expectedSize: Int, to destination: URL,
                                   progress: @escaping @Sendable (Double) -> Void) async throws {
        let data = try await attachment(messageID: providerID, attachmentID: attachmentID)
        try data.write(to: destination, options: .atomic)
    }

    public func backfillListing(page: String, limit: Int) async throws -> BackfillListing {
        let listed = try await bootstrap(page: page, limit: limit)
        return BackfillListing(ids: listed.messages.map(\.id.providerID), messages: listed.messages, nextPage: listed.nextPage)
    }
}
