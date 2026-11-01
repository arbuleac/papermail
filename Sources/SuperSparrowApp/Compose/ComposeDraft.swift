import AppKit
import SSCore

/// Everything a composer window holds, captured so an undone send can reopen the exact same message
/// and so the close prompt can tell prefilled content from what the user actually changed.
@MainActor
struct ComposeDraft {
    /// The parts the user can edit, reduced to something comparable. Prefill writes into the baseline
    /// as it lands, so only what the user typed or attached counts as unsaved.
    struct Fingerprint: Hashable {
        var to: [String] = []
        var cc: [String] = []
        var bcc: [String] = []
        var subject = ""
        var bodyText = ""
        var attachmentIDs: Set<UUID> = []
    }

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
            attachments: loadedAttachments
        )
    }
}
