import Foundation

public struct OutgoingAttachment: Hashable, Codable, Sendable {
    public var filename: String
    public var mimeType: String
    public var data: Data
    /// Set for inline images referenced as `cid:` from the HTML.
    public var contentID: String?
    public init(filename: String, mimeType: String, data: Data, contentID: String? = nil) {
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
        self.contentID = contentID
    }
}

/// A message the user wants to send. Providers build MIME (Gmail) or JSON (Graph) from this.
public struct OutgoingMessage: Hashable, Codable, Sendable {
    public var accountID: AccountID
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    /// Simple HTML produced by the composer: p, br, b, i, u, a, ul, ol, li, blockquote, div, span.
    public var html: String
    /// Plain-text alternative.
    public var text: String
    /// The message being replied to or forwarded, when any. Providers use it for threading.
    public var inReplyTo: MessageID?
    public var inReplyToInternetMessageID: String?
    public var references: [String]
    public var attachments: [OutgoingAttachment]

    public init(
        accountID: AccountID,
        to: [EmailAddress],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        subject: String,
        html: String,
        text: String,
        inReplyTo: MessageID? = nil,
        inReplyToInternetMessageID: String? = nil,
        references: [String] = [],
        attachments: [OutgoingAttachment] = []
    ) {
        self.accountID = accountID
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.html = html
        self.text = text
        self.inReplyTo = inReplyTo
        self.inReplyToInternetMessageID = inReplyToInternetMessageID
        self.references = references
        self.attachments = attachments
    }
}

public struct SendReceipt: Hashable, Codable, Sendable {
    public var providerMessageID: String?
    public var providerConversationID: String?
    public init(providerMessageID: String?, providerConversationID: String?) {
        self.providerMessageID = providerMessageID
        self.providerConversationID = providerConversationID
    }
}

public enum PendingSendStatus: String, Codable, Sendable {
    /// Held locally during the undo window.
    case scheduled
    case sending
    case sent
    case failed
}

/// A send waiting in the outbox. `sendAfter` implements undo-send.
public struct PendingSend: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var message: OutgoingMessage
    public var createdAt: Date
    public var sendAfter: Date
    public var status: PendingSendStatus
    public var attempts: Int
    public var lastError: String?

    public init(
        id: String = UUID().uuidString,
        message: OutgoingMessage,
        createdAt: Date = Date(),
        sendAfter: Date,
        status: PendingSendStatus = .scheduled,
        attempts: Int = 0,
        lastError: String? = nil
    ) {
        self.id = id
        self.message = message
        self.createdAt = createdAt
        self.sendAfter = sendAfter
        self.status = status
        self.attempts = attempts
        self.lastError = lastError
    }
}
