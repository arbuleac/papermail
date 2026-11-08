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

    /// Reply all: the reply's recipients in To, and everyone else the latest message went to in Cc, without
    /// the user's own addresses or anyone twice.
    public static func replyAllRecipients(to latest: MessageMetadata, accounts: [AccountID: Account]) -> (to: [EmailAddress], cc: [EmailAddress]) {
        let own = ownAddresses(accounts)
        let to = replyRecipients(to: latest, accounts: accounts)
        var seen = Set(to.map { $0.address.lowercased() }).union(own)
        var cc: [EmailAddress] = []
        for address in latest.to + latest.cc where seen.insert(address.address.lowercased()).inserted {
            cc.append(address)
        }
        return (to, cc)
    }

    /// Reply All is offered only when it reaches someone Reply would not (spec §5.12, §5.18).
    public static func replyAllAvailable(for latest: MessageMetadata, accounts: [AccountID: Account]) -> Bool {
        let all = replyAllRecipients(to: latest, accounts: accounts)
        return all.to.count + all.cc.count > 1
    }

    /// Name shown in the "Reply all to …" placeholder: "Ben Carter and 2 others".
    public static func replyAllTargetName(for latest: MessageMetadata, accounts: [AccountID: Account]) -> String {
        let all = replyAllRecipients(to: latest, accounts: accounts)
        let everyone = all.to + all.cc
        guard let first = everyone.first else { return "" }
        switch everyone.count {
        case 1: return first.shortDisplay
        case 2: return first.shortDisplay + " and 1 other"
        default: return first.shortDisplay + " and \(everyone.count - 1) others"
        }
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

    /// The reply as sent. `signature` is the sending account's signature as the composer exports it (§5.20): it
    /// follows the typed text after one blank line, which in the quick reply's own paragraphs is a paragraph break,
    /// and it adds nothing when it is nil or holds no text.
    public static func outgoingMessage(
        text: String,
        replyingTo latest: MessageMetadata,
        accounts: [AccountID: Account],
        all: Bool = false,
        signature: ComposerHTMLExporter.Output? = nil
    ) -> OutgoingMessage {
        var references = latest.references
        if let messageID = latest.internetMessageID, !references.contains(messageID) {
            references.append(messageID)
        }
        let signed = signature.flatMap { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let recipients: (to: [EmailAddress], cc: [EmailAddress]) = all
            ? replyAllRecipients(to: latest, accounts: accounts)
            : (replyRecipients(to: latest, accounts: accounts), [])
        return OutgoingMessage(
            accountID: latest.id.accountID,
            to: recipients.to,
            cc: recipients.cc,
            subject: replySubject(for: latest.subject),
            html: paragraphsHTML(from: text) + (signed.map { $0.html } ?? ""),
            text: signed.map { text.trimmingTrailingWhitespace() + "\n\n" + $0.text } ?? text,
            inReplyTo: latest.id,
            inReplyToInternetMessageID: latest.internetMessageID,
            references: references
        )
    }

    private static func ownAddresses(_ accounts: [AccountID: Account]) -> Set<String> {
        Set(accounts.values.map { $0.email.lowercased() })
    }
}

private extension String {
    /// Without the spaces and line breaks at its end, so the blank line before a signature is exactly one.
    func trimmingTrailingWhitespace() -> String {
        var result = self
        while let last = result.last, last.isWhitespace || last.isNewline { result.removeLast() }
        return result
    }
}
