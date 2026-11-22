import Foundation
import PaperCore

/// What Send and Archive archived (spec §5.23), and how to put it back. The archive is the main window's own, as E's,
/// taken the moment the send is queued; it joins no undo history and shows no toast of its own, because the send's undo
/// (the undo-send panel, the quick reply's strip, ⌘Z) takes it back with the send: one undo for both, which brings the
/// conversation back to the Inbox exactly as Z after E would. Once the message has left, the archive stays.
@MainActor
final class SendArchive {
    /// The main window, which archives a send's conversation as E does (`MainWindowController`).
    static weak var archiver: SendArchiving?

    let conversation: ConversationID
    private var revertAction: (() -> Void)?

    init(conversation: ConversationID, revert: @escaping () -> Void) {
        self.conversation = conversation
        revertAction = revert
    }

    /// Archives the conversation `original` belongs to once a send answering it was queued through `client`: nil when
    /// there is no main window for that client, or the archive changes nothing.
    static func archiveConversation(answering original: MessageID, client: MailClient) -> SendArchive? {
        archiver?.archiveConversation(answering: original, client: client)
    }

    /// Whether the conversation has not been put back yet.
    var isArchived: Bool { revertAction != nil }

    /// Puts the conversation back where it was, once: the send it went with was undone in time.
    func revert() {
        let action = revertAction
        revertAction = nil
        action?()
    }
}
