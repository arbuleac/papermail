import Foundation

/// A Send Later message waiting in the outbox (spec §5.19, §5.23), as the Drafts view lists it and the reader shows it:
/// a one-message conversation under its account, read-only like a kept draft, built from the outbox row alone, so the
/// row and the sheet show what will be sent. Its time slot reads “Sends Mon 09:00”.
///
/// Its ids are a kind of kept-draft id (`LocalDraftConversation.providerPrefix` leads them), so every guard that keeps a
/// kept draft away from the store (no operation queued, no body fetched, no mark acknowledged) keeps these away too;
/// `LocalDraftConversation.draftID(of:)` finds no draft in them. Pure, so the rows and the sheet are tested without
/// files or windows.
public enum SendLaterConversation {
    public static let providerPrefix = LocalDraftConversation.providerPrefix + "send-later:"

    public static func conversationID(sendID: String, account: AccountID) -> ConversationID {
        ConversationID(accountID: account, providerID: providerPrefix + sendID)
    }

    public static func messageID(sendID: String, account: AccountID) -> MessageID {
        MessageID(accountID: account, providerID: providerPrefix + sendID)
    }

    /// The outbox row behind a Drafts row, or nil for any other row.
    public static func sendID(of id: ConversationID) -> String? {
        sendID(providerID: id.providerID)
    }

    public static func sendID(of id: MessageID) -> String? {
        sendID(providerID: id.providerID)
    }

    private static func sendID(providerID: String) -> String? {
        guard providerID.hasPrefix(providerPrefix) else { return nil }
        let id = String(providerID.dropFirst(providerPrefix.count))
        return id.isEmpty ? nil : id
    }

    /// The sends the Drafts view lists: those a Send Later state describes (waiting, missed, or going with its draft).
    public static func listed(_ sends: [PendingSendSummary]) -> [PendingSendSummary] {
        sends.filter { SendLaterState($0) != nil }
    }

    /// The Drafts row, dated when it was scheduled, with its state for the time slot; nil for a send that is not one.
    public static func summary(for send: PendingSendSummary) -> ConversationSummary? {
        guard let state = SendLaterState(send) else { return nil }
        let account = send.accountID
        return ConversationSummary(
            id: conversationID(sendID: send.id, account: account),
            subject: send.subject,
            snippet: ComposeDraftRecord.preview(of: send.text),
            participants: [],
            latestDate: send.createdAt,
            messageCount: 1,
            unreadCount: 0,
            isStarred: false,
            hasAttachments: send.hasFiles,
            inInbox: false,
            inboxSection: .focused,
            latestMessageID: messageID(sendID: send.id, account: account),
            hasPendingOperations: false,
            sendLater: state
        )
    }

    /// The message as the one message of its conversation, from `sender` (the account) to its recipients: the row names
    /// them (“Draft to Ben Carter”) and the reader's draft sheet heads with them.
    public static func message(for send: PendingSendSummary, sender: EmailAddress) -> MessageMetadata {
        MessageMetadata(
            id: messageID(sendID: send.id, account: send.accountID),
            conversationID: conversationID(sendID: send.id, account: send.accountID),
            subject: send.subject,
            snippet: ComposeDraftRecord.preview(of: send.text),
            from: sender,
            to: send.to,
            cc: send.cc,
            bcc: send.bcc,
            date: send.createdAt,
            roles: [.drafts],
            isRead: true,
            isStarred: false,
            inboxSection: .focused,
            hasAttachments: send.hasFiles
        )
    }

    /// The body the reader renders: the message's plain-text part as it will be sent, set as typed (string work, never
    /// an HTML parse), its quoted original folded as a received quote is.
    public static func body(for send: PendingSendSummary) -> StoredBody {
        LocalDraftConversation.body(text: send.text, quoted: nil)
    }
}
