import Foundation

/// A message waiting in the outbox as a row: a Send Later message in the Drafts view (spec §5.19, §5.23), and every send
/// the provider has not taken yet in the Outbox (§5.53), undo-sends included. Each is a one-message conversation under its
/// account, read-only like a kept draft, built from the outbox row alone, so the row and the sheet show what will be
/// sent. A Drafts row's time slot reads “Sends Mon 09:00”; an Outbox row's says where the send is (`OutboxState`).
///
/// Its ids are a kind of kept-draft id (`LocalDraftConversation.providerPrefix` leads them), so every guard that keeps a
/// kept draft away from the store (no operation queued, no body fetched, no mark acknowledged) keeps these away too;
/// `LocalDraftConversation.draftID(of:)` finds no draft in them. A Send Later message has the same id in both views, so
/// what opens it, cancels it or continues it from Drafts does so from the Outbox too. Pure, so the rows and the sheet are
/// tested without files or windows.
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
        return row(for: send, sendLater: state, outbox: nil)
    }

    // MARK: The Outbox (§5.53)

    /// The sends the Outbox lists: every one the provider has not taken yet (a `sent` row only waits for the app to clear
    /// its kept draft away), in the order they go: those that go by themselves soonest first, by `sendAfter` (what goes
    /// now, then what counts down, waits to retry, or waits for its Send Later time), then those waiting for the user
    /// (missed, failed), newest first. A row moves only when its send's time does.
    public static func outboxListed(_ sends: [PendingSendSummary]) -> [PendingSendSummary] {
        let listed = sends.compactMap { send in OutboxState(send).map { (send, $0.goesByItself) } }
        return listed.sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 }
            if lhs.1 {
                if lhs.0.sendAfter != rhs.0.sendAfter { return lhs.0.sendAfter < rhs.0.sendAfter }
            } else if lhs.0.createdAt != rhs.0.createdAt {
                return lhs.0.createdAt > rhs.0.createdAt
            }
            return lhs.0.id < rhs.0.id
        }.map(\.0)
    }

    /// The Outbox row, dated when Send was pressed, with its state for the time slot; nil for a send the provider took.
    /// It carries no Send Later state, so nothing reads it as a Drafts row.
    public static func outboxSummary(for send: PendingSendSummary) -> ConversationSummary? {
        guard let state = OutboxState(send) else { return nil }
        return row(for: send, sendLater: nil, outbox: state)
    }

    private static func row(for send: PendingSendSummary, sendLater: SendLaterState?, outbox: OutboxState?) -> ConversationSummary {
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
            sendLater: sendLater,
            outbox: outbox
        )
    }

    // MARK: The message

    /// The message as the one message of its conversation, from `sender` (the account) to its recipients: the row names
    /// them (“Draft to Ben Carter” in Drafts, “To Ben Carter” in the Outbox) and the reader's draft sheet heads with them.
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
