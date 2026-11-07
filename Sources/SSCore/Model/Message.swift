import Foundation

/// System mailboxes expressed as roles. Gmail maps system labels to roles; Graph maps well-known folders.
/// "Archived" is the absence of `inbox`, `trash` and `spam`; it is not a role of its own.
public enum MailboxRole: String, Codable, Sendable, CaseIterable {
    case inbox
    case sent
    case drafts
    case trash
    case spam
}

/// Gmail categories (Primary vs the rest) and Outlook Focused Inbox, folded into one bit. Stored to round-trip
/// provider state; the app neither filters nor marks rows by it (spec §5.5).
public enum InboxSection: String, Codable, Sendable {
    case focused
    case other
    case unknown
}

public struct EmailAddress: Hashable, Codable, Sendable {
    public var name: String?
    public var address: String
    public init(name: String? = nil, address: String) {
        self.name = name
        self.address = address
    }
    /// Display name when present, otherwise the local part of the address.
    public var shortDisplay: String {
        if let name, !name.isEmpty { return name }
        return address.split(separator: "@").first.map(String.init) ?? address
    }
}

/// Everything the list and the sync engine need about a message, without its body.
public struct MessageMetadata: Hashable, Codable, Sendable {
    public var id: MessageID
    public var conversationID: ConversationID
    public var internetMessageID: String?
    public var inReplyTo: String?
    public var references: [String]
    public var subject: String
    public var snippet: String
    public var from: EmailAddress?
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var replyTo: [EmailAddress]
    /// Provider receive date (Gmail internalDate, Graph receivedDateTime).
    public var date: Date
    public var roles: Set<MailboxRole>
    public var isRead: Bool
    public var isStarred: Bool
    public var inboxSection: InboxSection
    public var hasAttachments: Bool
    /// Gmail label ids. Stored for round-tripping; never shown in the UI.
    public var labelIDs: [String]
    /// Graph parentFolderId. Stored for round-tripping; never shown in the UI.
    public var folderID: String?
    /// Gmail historyId or Graph changeKey of this observation.
    public var providerVersion: String?
    public var sizeBytes: Int?

    public init(
        id: MessageID,
        conversationID: ConversationID,
        internetMessageID: String? = nil,
        inReplyTo: String? = nil,
        references: [String] = [],
        subject: String,
        snippet: String,
        from: EmailAddress?,
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        replyTo: [EmailAddress] = [],
        date: Date,
        roles: Set<MailboxRole>,
        isRead: Bool,
        isStarred: Bool,
        inboxSection: InboxSection = .unknown,
        hasAttachments: Bool,
        labelIDs: [String] = [],
        folderID: String? = nil,
        providerVersion: String? = nil,
        sizeBytes: Int? = nil
    ) {
        self.id = id
        self.conversationID = conversationID
        self.internetMessageID = internetMessageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.subject = subject
        self.snippet = snippet
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.replyTo = replyTo
        self.date = date
        self.roles = roles
        self.isRead = isRead
        self.isStarred = isStarred
        self.inboxSection = inboxSection
        self.hasAttachments = hasAttachments
        self.labelIDs = labelIDs
        self.folderID = folderID
        self.providerVersion = providerVersion
        self.sizeBytes = sizeBytes
    }

    /// True when the message belongs in the unified inbox.
    public var isInInbox: Bool {
        roles.contains(.inbox) && !roles.contains(.trash) && !roles.contains(.spam)
    }
}

public struct AttachmentInfo: Hashable, Codable, Sendable {
    /// Provider attachment id (Gmail body.attachmentId, Graph attachment id).
    public var id: String
    public var filename: String
    public var mimeType: String
    public var sizeBytes: Int
    /// Content-ID without angle brackets, for `cid:` references in HTML.
    public var contentID: String?
    public var isInline: Bool
    public init(id: String, filename: String, mimeType: String, sizeBytes: Int, contentID: String? = nil, isInline: Bool) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
        self.contentID = contentID
        self.isInline = isInline
    }
}

/// A fetched message body as the provider gave it, before sanitizing.
public struct MessageBody: Hashable, Codable, Sendable {
    public var html: String?
    public var text: String?
    /// All parts, inline ones included.
    public var attachments: [AttachmentInfo]
    public init(html: String?, text: String?, attachments: [AttachmentInfo] = []) {
        self.html = html
        self.text = text
        self.attachments = attachments
    }
}

/// What the store keeps for a message body: the original plus the render-ready HTML prepared at sync time.
public struct StoredBody: Hashable, Codable, Sendable {
    public var body: MessageBody
    /// Sanitized, cid-rewritten, remote-images-blocked HTML. See `HTMLSanitizer`.
    public var renderedHTML: String
    public var plainText: String
    /// Facts about `renderedHTML` worked out once at sync time, so rendering never scans the body. Nil for
    /// bodies stored before they were kept; the renderer then derives them from the HTML.
    public var hasQuotedContent: Bool?
    /// Remote images parked in `data-ss-src`, which the reader can load on request.
    public var blockedRemoteImageCount: Int?
    /// The design facts from `SanitizedBody`, nil for bodies stored before they were kept. Unlike the facts
    /// above they cannot be derived at render time without parsing, so nil renders as `.styled`, colours
    /// assumed and coverage unknown.
    public var typesetting: BodyTypesetting?
    public var declaresColors: Bool?
    public var coveredByNewYork: Bool?

    public init(
        body: MessageBody,
        renderedHTML: String,
        plainText: String,
        hasQuotedContent: Bool? = nil,
        blockedRemoteImageCount: Int? = nil,
        typesetting: BodyTypesetting? = nil,
        declaresColors: Bool? = nil,
        coveredByNewYork: Bool? = nil
    ) {
        self.body = body
        self.renderedHTML = renderedHTML
        self.plainText = plainText
        self.hasQuotedContent = hasQuotedContent
        self.blockedRemoteImageCount = blockedRemoteImageCount
        self.typesetting = typesetting
        self.declaresColors = declaresColors
        self.coveredByNewYork = coveredByNewYork
    }
}
