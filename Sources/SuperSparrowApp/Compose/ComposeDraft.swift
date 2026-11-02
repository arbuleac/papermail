import AppKit
import SSCore

/// Everything a composer window holds, captured so an undone send can reopen the exact same message, so
/// the draft can be kept on this Mac, and so closing can tell prefilled content from what the user changed.
@MainActor
struct ComposeDraft {
    /// The parts the user can edit, reduced to something comparable. Prefill writes into the baseline
    /// as it lands, so only what the user typed or attached counts as worth keeping.
    struct Fingerprint: Hashable {
        var to: [String] = []
        var cc: [String] = []
        var bcc: [String] = []
        var subject = ""
        var bodyText = ""
        var attachmentIDs: Set<UUID> = []
    }

    /// The draft's identity in `ComposeDraftStore`, kept across undo send and reopening.
    var id: UUID
    var mode: ComposeMode
    var account: Account
    var to: [EmailAddress]
    var cc: [EmailAddress]
    var bcc: [EmailAddress]
    var subject: String
    /// The editor's document as typed, list markers included; `ComposeBodyNormalizer` cleans it at send time.
    var body: NSAttributedString
    /// Files and forwarded parts. Inline parts (`contentID` set) are sent so the quoted original's images
    /// resolve again, but never shown as chips.
    var attachments: [ComposeAttachment]
    var quoted: QuotedReply.Rendering?
    /// Taken from the original when replying or forwarding and kept whatever From is chosen, so an undone
    /// send reopens with them; `outgoingMessage` applies them only when the account can use them.
    var threading: ReplyThreading?
    /// The provider's reason when this draft comes back from a failed send; the composer shows the banner.
    var sendFailure: String?
    /// The provider's draft this one continues (Continue Editing on a synced Drafts row): sending discards it.
    var continuesDraft: MessageID? = nil

    var fingerprint: Fingerprint {
        Fingerprint(
            to: to.map(\.address),
            cc: cc.map(\.address),
            bcc: bcc.map(\.address),
            subject: subject,
            bodyText: body.string,
            attachmentIDs: Set(attachments.map(\.id))
        )
    }

    /// The first recipient as a person would name them, for “The message to Ben Carter hasn't been sent.”
    var firstRecipientName: String? {
        guard let first = to.first ?? cc.first ?? bcc.first else { return nil }
        return QuotedReply.authorName(first)
    }

    /// Builds what `MailClient.send` takes from the normalized body and the already-read attachment bytes
    /// (reading file-backed attachments belongs off the main thread, so the caller does it first).
    func outgoingMessage(normalizedBody: NSAttributedString, loadedAttachments: [OutgoingAttachment]) -> OutgoingMessage {
        let export = ComposerHTMLExporter().export(normalizedBody, appending: quoted)
        // Threading headers name a message of one account; sending from another would hand the provider
        // an id it cannot resolve, so the message starts a fresh thread there.
        let threading = threading?.applicable(to: account.id)
        return OutgoingMessage(
            accountID: account.id,
            to: to,
            cc: cc,
            bcc: bcc,
            subject: subject,
            html: export.html,
            text: export.text,
            inReplyTo: threading?.inReplyTo,
            inReplyToInternetMessageID: threading?.inReplyToInternetMessageID,
            references: threading?.references ?? [],
            isForward: threading?.isForward ?? false,
            attachments: loadedAttachments
        )
    }
}
