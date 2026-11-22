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
    /// Simple HTML produced by the composer: p, br, b, i, u, a, ul, ol, li, blockquote, div, span, and img for a
    /// picture in the body, whose `cid:` names one of `attachments` (`ComposerInlineImage`).
    public var html: String
    /// Plain-text alternative.
    public var text: String
    /// The message being replied to or forwarded, when any. Providers use it for threading.
    public var inReplyTo: MessageID?
    public var inReplyToInternetMessageID: String?
    public var references: [String]
    /// A forward names its original in `inReplyTo` so providers can find its parts and thread, but it does
    /// not answer it: no In-Reply-To, no server-side reply draft.
    public var isForward: Bool
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
        isForward: Bool = false,
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
        self.isForward = isForward
        self.attachments = attachments
    }

    /// Pending sends are stored as JSON; rows written before `isForward` existed decode as replies.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try container.decode(AccountID.self, forKey: .accountID)
        to = try container.decode([EmailAddress].self, forKey: .to)
        cc = try container.decode([EmailAddress].self, forKey: .cc)
        bcc = try container.decode([EmailAddress].self, forKey: .bcc)
        subject = try container.decode(String.self, forKey: .subject)
        html = try container.decode(String.self, forKey: .html)
        text = try container.decode(String.self, forKey: .text)
        inReplyTo = try container.decodeIfPresent(MessageID.self, forKey: .inReplyTo)
        inReplyToInternetMessageID = try container.decodeIfPresent(String.self, forKey: .inReplyToInternetMessageID)
        references = try container.decode([String].self, forKey: .references)
        isForward = try container.decodeIfPresent(Bool.self, forKey: .isForward) ?? false
        attachments = try container.decode([OutgoingAttachment].self, forKey: .attachments)
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

/// Raw values are stored in `pending_sends.status`; never rename them.
public enum PendingSendStatus: String, Codable, Sendable {
    /// Held locally during the undo window (or a throttle's retry), and sent at `sendAfter`.
    case scheduled
    /// Send Later: held until the time the user chose (`sendAfter`, on the wall clock) and sent then, while the app runs.
    case later
    /// Send Later whose time passed while the app was closed: held until the user says to send it (`MailClient.sendNow`)
    /// or keeps it as a draft (`MailClient.cancelSend`). The runner never claims one.
    case missed
    case sending
    case sent
    case failed
}

/// A send waiting in the outbox. `sendAfter` implements undo-send and Send Later.
public struct PendingSend: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var message: OutgoingMessage
    public var createdAt: Date
    public var sendAfter: Date
    public var status: PendingSendStatus
    public var attempts: Int
    public var lastError: String?
    /// The draft kept on this Mac that a Send Later message was written in (the app's `ComposeDraftStore`), so opening
    /// it from Drafts brings back what was written. Opaque to the engine, which only keeps a delivered send that has one
    /// as `sent`, for the app to remove the draft and then the row, and tells by it that a `scheduled` send left by a
    /// quit is a Send Later message waiting out a throttle, which the next launch asks about. Nil for every other send.
    public var draftID: UUID?

    public init(
        id: String = UUID().uuidString,
        message: OutgoingMessage,
        createdAt: Date = Date(),
        sendAfter: Date,
        status: PendingSendStatus = .scheduled,
        attempts: Int = 0,
        lastError: String? = nil,
        draftID: UUID? = nil
    ) {
        self.id = id
        self.message = message
        self.createdAt = createdAt
        self.sendAfter = sendAfter
        self.status = status
        self.attempts = attempts
        self.lastError = lastError
        self.draftID = draftID
    }

    /// Waiting for a time the user chose with Send Later, or holding one that passed while the app was closed: the
    /// Drafts view lists it, and `MailClient.cancelSend` can still take it back.
    public var isHeldForLater: Bool {
        status == .later || status == .missed
    }
}
