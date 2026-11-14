import Foundation

/// A send in the outbox without the parts of its message only the provider needs (its HTML, its threading references and
/// its attachments' bytes): what the outbox's observers, its pollers and the send runner's claim decisions read
/// (`MailStoring.pendingSendSummaries`). A Send Later message can wait for days with its attachments inline, so nothing
/// that looks at the outbox often decodes them; the whole message is read only to send it, or to make a draft of it
/// (`MailStoring.pendingSend(id:)`). Its state is written back with `MailStoring.updateSend`, which never touches the
/// message.
public struct PendingSendSummary: Hashable, Sendable, Identifiable {
    public var id: String
    public var accountID: AccountID
    public var createdAt: Date
    public var sendAfter: Date
    public var status: PendingSendStatus
    public var attempts: Int
    public var lastError: String?
    /// The draft kept on this Mac a Send Later message was written in (`PendingSend.draftID`).
    public var draftID: UUID?
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    /// The plain-text part, as it will be sent: the Drafts row's snippet and the sheets read it.
    public var text: String
    public var inReplyTo: MessageID?
    public var isForward: Bool
    /// It carries a file: an attachment that is not an inline image.
    public var hasFiles: Bool

    public init(
        id: String,
        accountID: AccountID,
        createdAt: Date,
        sendAfter: Date,
        status: PendingSendStatus,
        attempts: Int = 0,
        lastError: String? = nil,
        draftID: UUID? = nil,
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        subject: String = "",
        text: String = "",
        inReplyTo: MessageID? = nil,
        isForward: Bool = false,
        hasFiles: Bool = false
    ) {
        self.id = id
        self.accountID = accountID
        self.createdAt = createdAt
        self.sendAfter = sendAfter
        self.status = status
        self.attempts = attempts
        self.lastError = lastError
        self.draftID = draftID
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.text = text
        self.inReplyTo = inReplyTo
        self.isForward = isForward
        self.hasFiles = hasFiles
    }

    public init(_ send: PendingSend) {
        let message = send.message
        self.init(
            id: send.id, accountID: message.accountID, createdAt: send.createdAt, sendAfter: send.sendAfter, status: send.status,
            attempts: send.attempts, lastError: send.lastError, draftID: send.draftID, to: message.to, cc: message.cc, bcc: message.bcc,
            subject: message.subject, text: message.text, inReplyTo: message.inReplyTo, isForward: message.isForward,
            hasFiles: message.attachments.contains { $0.contentID == nil }
        )
    }

    /// `PendingSend.isHeldForLater`.
    public var isHeldForLater: Bool {
        status == .later || status == .missed
    }
}
