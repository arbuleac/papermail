import Foundation

/// Builds the `OutgoingMessage` for a quick reply typed under a conversation. Pure so the recipient,
/// subject and paragraph rules can be tested without AppKit.
public enum QuickReplyComposer {
    /// Reply-To wins; otherwise the sender, unless the latest message is one the user sent, in which case
    /// the reply continues to its original recipients.
    public static func replyRecipients(to latest: MessageMetadata, accounts: [AccountID: Account]) -> [EmailAddress] {
        let own = ownAddresses(accounts)
        let candidates: [EmailAddress]
        if !latest.replyTo.isEmpty {
            candidates = latest.replyTo
        } else if let from = latest.from, !own.contains(from.address.lowercased()) {
            candidates = [from]
        } else if !latest.to.isEmpty {
            candidates = latest.to
        } else if let from = latest.from {
            candidates = [from]
        } else {
            candidates = []
        }
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.address.lowercased()).inserted }
    }

    /// Name shown in the "Reply to …" placeholder.
    public static func replyTargetName(for latest: MessageMetadata, accounts: [AccountID: Account]) -> String {
        let recipients = replyRecipients(to: latest, accounts: accounts)
        guard let first = recipients.first else { return "" }
        if recipients.count > 1 { return first.shortDisplay + " and \(recipients.count - 1) more" }
        return first.shortDisplay
    }

    public static func replySubject(for subject: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("re:") { return trimmed }
        return trimmed.isEmpty ? "Re:" : "Re: " + trimmed
    }

    /// Blank lines separate paragraphs; single newlines become `<br>`. Text is escaped, never trusted.
    /// Right-to-left paragraphs say so with `dir`, or recipients' clients lay them out left to right.
    public static func paragraphsHTML(from text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let paragraphs = normalized
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .newlines) }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return paragraphs.map { paragraph in
            "<p\(TextDirection.attribute(for: paragraph))>" + RenderPayloadBuilder.escapeHTML(paragraph).replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        }.joined()
    }

    public static func outgoingMessage(
        text: String,
        replyingTo latest: MessageMetadata,
        accounts: [AccountID: Account]
    ) -> OutgoingMessage {
        var references = latest.references
        if let messageID = latest.internetMessageID, !references.contains(messageID) {
            references.append(messageID)
        }
        return OutgoingMessage(
            accountID: latest.id.accountID,
            to: replyRecipients(to: latest, accounts: accounts),
            subject: replySubject(for: latest.subject),
            html: paragraphsHTML(from: text),
            text: text,
            inReplyTo: latest.id,
            inReplyToInternetMessageID: latest.internetMessageID,
            references: references
        )
    }

    private static func ownAddresses(_ accounts: [AccountID: Account]) -> Set<String> {
        Set(accounts.values.map { $0.email.lowercased() })
    }
}
