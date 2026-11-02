import Foundation

/// A draft kept on this Mac (spec §5.19: “Drafts you start here are kept on this Mac”), shown as the Drafts
/// view and the reader show any draft: a one-message conversation under its account, read-only, set as typed.
///
/// Its ids carry `providerPrefix`, which no provider id has, so the shell can tell a kept draft from mail
/// in the store and never queues an operation, fetches a body or acknowledges a mark for it. Pure, so the
/// Drafts rows and the reader's draft sheet are built and tested without files or windows.
public enum LocalDraftConversation {
    public static let providerPrefix = "ss-local-draft:"

    public static func conversationID(draftID: UUID, account: AccountID) -> ConversationID {
        ConversationID(accountID: account, providerID: providerPrefix + draftID.uuidString)
    }

    public static func messageID(draftID: UUID, account: AccountID) -> MessageID {
        MessageID(accountID: account, providerID: providerPrefix + draftID.uuidString)
    }

    /// The kept draft behind a Drafts row, or nil for mail in the store.
    public static func draftID(of id: ConversationID) -> UUID? {
        draftID(providerID: id.providerID)
    }

    public static func draftID(of id: MessageID) -> UUID? {
        draftID(providerID: id.providerID)
    }

    public static func isLocal(_ id: ConversationID) -> Bool {
        id.providerID.hasPrefix(providerPrefix)
    }

    public static func isLocal(_ id: MessageID) -> Bool {
        id.providerID.hasPrefix(providerPrefix)
    }

    private static func draftID(providerID: String) -> UUID? {
        guard providerID.hasPrefix(providerPrefix) else { return nil }
        return UUID(uuidString: String(providerID.dropFirst(providerPrefix.count)))
    }

    /// The Drafts row: dated when it was last edited, never unread, starred or in the inbox.
    public static func summary(for record: ComposeDraftRecord) -> ConversationSummary {
        ConversationSummary(
            id: conversationID(draftID: record.id, account: record.accountID),
            subject: record.subject,
            snippet: record.preview ?? "",
            participants: [],
            latestDate: record.editedAt,
            messageCount: 1,
            unreadCount: 0,
            isStarred: false,
            hasAttachments: record.attachments.contains { $0.contentID == nil },
            inInbox: false,
            inboxSection: .focused,
            latestMessageID: messageID(draftID: record.id, account: record.accountID),
            hasPendingOperations: false
        )
    }

    /// The draft as the one message of its conversation, from `sender` (the account) to its recipients; the row
    /// names them (“Draft to Ben Carter”) and the reader's draft sheet heads with them.
    public static func message(for record: ComposeDraftRecord, sender: EmailAddress) -> MessageMetadata {
        MessageMetadata(
            id: messageID(draftID: record.id, account: record.accountID),
            conversationID: conversationID(draftID: record.id, account: record.accountID),
            subject: record.subject,
            snippet: record.preview ?? "",
            from: sender,
            to: record.to,
            cc: record.cc,
            bcc: record.bcc,
            date: record.editedAt,
            roles: [.drafts],
            isRead: true,
            isStarred: false,
            inboxSection: .focused,
            hasAttachments: record.attachments.contains { $0.contentID == nil }
        )
    }

    /// The body the reader renders: the text as typed, escaped with its line breaks kept, then a reply's
    /// quoted original folded behind the elision chip, as received quotes are.
    public static func body(text: String, quoted: QuotedReply.Rendering?) -> StoredBody {
        let rendered = PlainTextRenderer.render(text)
        var html = rendered.html
        if let quoted, !quoted.html.isEmpty {
            html += "<div class=\"ss-quote\">" + quoted.html + "</div>"
        }
        return StoredBody(
            body: MessageBody(html: nil, text: text),
            renderedHTML: html,
            plainText: text,
            hasQuotedContent: rendered.hasQuotedContent || quoted != nil,
            blockedRemoteImageCount: 0
        )
    }
}
