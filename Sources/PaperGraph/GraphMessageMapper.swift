import Foundation
import PaperCore

/// Turns decoded Graph resources into the shared model types.
struct GraphMessageMapper: Sendable {
    let accountID: AccountID
    let folders: GraphWellKnownFolders

    func metadata(from message: GraphMessage) -> MessageMetadata {
        MessageMetadata(
            id: MessageID(accountID: accountID, providerID: message.id),
            // Drafts can lack a conversation id; threading them to themselves keeps the store's invariant.
            conversationID: ConversationID(accountID: accountID, providerID: message.conversationId ?? message.id),
            internetMessageID: message.internetMessageId,
            subject: message.subject ?? "",
            snippet: message.bodyPreview ?? "",
            from: Self.address(message.from),
            to: Self.addresses(message.toRecipients),
            cc: Self.addresses(message.ccRecipients),
            bcc: Self.addresses(message.bccRecipients),
            replyTo: Self.addresses(message.replyTo),
            date: message.receivedDateTime.flatMap(GraphDate.parse) ?? Date(timeIntervalSince1970: 0),
            roles: folders.roles(folderID: message.parentFolderId, isDraft: message.isDraft ?? false),
            isRead: message.isRead ?? true,
            isStarred: message.flag?.flagStatus == "flagged",
            inboxSection: Self.section(message.inferenceClassification),
            hasAttachments: message.hasAttachments ?? false,
            folderID: message.parentFolderId,
            providerVersion: message.changeKey
        )
    }

    static func body(from message: GraphMessage, attachments: [GraphAttachment]) -> MessageBody {
        let isHTML = message.body?.contentType?.lowercased() == "html"
        // List and delta calls cannot select internet headers, so the body fetch is where the list headers arrive.
        let listUnsubscribe = UnsubscribeMethod.capturedHeader(header("List-Unsubscribe", in: message))
        return MessageBody(
            html: isHTML ? message.body?.content : nil,
            text: isHTML ? nil : message.body?.content,
            attachments: attachments.map(attachmentInfo),
            listUnsubscribe: listUnsubscribe,
            listUnsubscribePost: listUnsubscribe == nil ? nil : UnsubscribeMethod.capturedHeader(header("List-Unsubscribe-Post", in: message))
        )
    }

    /// The first internet header of that name, in any case.
    static func header(_ name: String, in message: GraphMessage) -> String? {
        message.internetMessageHeaders?.first { $0.name?.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func attachmentInfo(_ attachment: GraphAttachment) -> AttachmentInfo {
        AttachmentInfo(
            id: attachment.id,
            filename: attachment.name ?? "",
            mimeType: attachment.contentType ?? "application/octet-stream",
            sizeBytes: attachment.size ?? 0,
            contentID: attachment.contentId.map(stripAngleBrackets),
            isInline: attachment.isInline ?? false
        )
    }

    static func address(_ recipient: GraphRecipient?) -> EmailAddress? {
        guard let address = recipient?.emailAddress?.address, !address.isEmpty else { return nil }
        let name = recipient?.emailAddress?.name?.trimmingCharacters(in: .whitespaces)
        return EmailAddress(name: (name?.isEmpty ?? true) ? nil : name, address: address)
    }

    static func addresses(_ recipients: [GraphRecipient]?) -> [EmailAddress] {
        (recipients ?? []).compactMap(address)
    }

    static func section(_ classification: String?) -> InboxSection {
        switch classification?.lowercased() {
        case "focused": return .focused
        case "other": return .other
        default: return .unknown
        }
    }

    private static func stripAngleBrackets(_ value: String) -> String {
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<") { trimmed.removeFirst() }
        if trimmed.hasSuffix(">") { trimmed.removeLast() }
        return trimmed
    }
}
