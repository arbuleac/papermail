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
    /// The `List-Unsubscribe` header as sent (RFC 2369), nil when the message has none or the provider did not
    /// say: Gmail reports it with the metadata, Graph only with the body (`MessageBody.listUnsubscribe`), so a
    /// Microsoft message learns it when its body is fetched. Headers never change, so a nil from a path that cannot
    /// carry it never clears one already stored. `UnsubscribeMethod` reads it.
    public var listUnsubscribe: String?
    /// The `List-Unsubscribe-Post` header as sent (RFC 8058); kept only beside a `listUnsubscribe`.
    public var listUnsubscribePost: String?
    /// The user's answer to the invitation this message carries, as given in the reader on this Mac; nil until they
    /// answer here. Local state, like the effect of a pending operation: providers never set it, and the store keeps
    /// the recorded value through every provider upsert (docs/DATA-MODEL.md, `messages.invitation_reply`).
    public var invitationReply: InvitationResponse?

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
        sizeBytes: Int? = nil,
        listUnsubscribe: String? = nil,
        listUnsubscribePost: String? = nil,
        invitationReply: InvitationResponse? = nil
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
        self.listUnsubscribe = listUnsubscribe
        self.listUnsubscribePost = listUnsubscribePost
        self.invitationReply = invitationReply
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
    /// The message's `List-Unsubscribe` and `List-Unsubscribe-Post` headers when the body fetch carries them (Graph's
    /// list and delta calls cannot select headers, so they arrive here). Not kept with the body: the store writes them
    /// on the message (`MessageMetadata.listUnsubscribe`), so a body read back from the store has none.
    public var listUnsubscribe: String?
    public var listUnsubscribePost: String?
    /// The message's text/calendar part as fetched (Gmail), which the engine reads into `invitation` when it stores
    /// the body. Not stored itself: the invitation keeps the text it needs.
    public var calendar: String?
    /// An invitation the provider read itself (Microsoft's event message), stored as it is.
    public var invitation: CalendarInvitation?
    public init(html: String?, text: String?, attachments: [AttachmentInfo] = [], listUnsubscribe: String? = nil,
                listUnsubscribePost: String? = nil, calendar: String? = nil, invitation: CalendarInvitation? = nil) {
        self.html = html
        self.text = text
        self.attachments = attachments
        self.listUnsubscribe = listUnsubscribe
        self.listUnsubscribePost = listUnsubscribePost
        self.calendar = calendar
        self.invitation = invitation
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
    /// The parked images marked as trackers (spec §5.60), part of `blockedRemoteImageCount`; nil for bodies stored before
    /// the sanitizer marked them (v24), which carry no marks, so the reader counts none.
    public var trackerImageCount: Int?
    /// The design facts from `SanitizedBody`, nil for bodies stored before they were kept. Unlike the facts
    /// above they cannot be derived at render time without parsing, so nil renders as `.styled`, colours
    /// assumed and coverage unknown.
    public var typesetting: BodyTypesetting?
    public var declaresColors: Bool?
    public var coveredByNewYork: Bool?
    /// The calendar invitation the message carries, read at sync time; nil for every other message (spec §5.14).
    public var invitation: CalendarInvitation?

    public init(
        body: MessageBody,
        renderedHTML: String,
        plainText: String,
        hasQuotedContent: Bool? = nil,
        blockedRemoteImageCount: Int? = nil,
        trackerImageCount: Int? = nil,
        typesetting: BodyTypesetting? = nil,
        declaresColors: Bool? = nil,
        coveredByNewYork: Bool? = nil,
        invitation: CalendarInvitation? = nil
    ) {
        self.body = body
        self.renderedHTML = renderedHTML
        self.plainText = plainText
        self.hasQuotedContent = hasQuotedContent
        self.blockedRemoteImageCount = blockedRemoteImageCount
        self.trackerImageCount = trackerImageCount
        self.typesetting = typesetting
        self.declaresColors = declaresColors
        self.coveredByNewYork = coveredByNewYork
        self.invitation = invitation
    }
}
