import Foundation

/// A reply on its way out, shown in its conversation as the last sheet until it leaves (spec §5.14, “Pending
/// send”: full contrast, the date reads “Sending…” with a 12 pt spinner). Built from the outbox row alone, so
/// the reader keeps reading only the store; the body is the reply's plain-text part, set by
/// `PlainTextRenderer` (string work, never an HTML parse), and its id can never collide with a provider's.
public struct PendingSheet: Hashable, Sendable {
    public var metadata: MessageMetadata
    public var body: StoredBody
    /// The message the reply answers, which places it in that message's conversation.
    public var original: MessageID

    /// Provider ids never start with this.
    static let idPrefix = "ss-pending-"

    public static func isPending(_ id: MessageID) -> Bool {
        id.providerID.hasPrefix(idPrefix)
    }

    /// The sheets for `sends` that answer one of `messages` (a conversation's), oldest first. Forwards start a
    /// new conversation and failed or finished sends are not on their way, so neither shows.
    public static func sheets(for sends: [PendingSend], answering messages: [MessageMetadata], accounts: [AccountID: Account]) -> [PendingSheet] {
        guard !sends.isEmpty, !messages.isEmpty else { return [] }
        let byID = Dictionary(messages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return sends
            .filter { $0.status == .scheduled || $0.status == .sending }
            .sorted { $0.createdAt < $1.createdAt }
            .compactMap { send -> PendingSheet? in
                guard !send.message.isForward, let originalID = send.message.inReplyTo, let original = byID[originalID] else { return nil }
                return sheet(for: send, original: original, account: accounts[send.message.accountID])
            }
    }

    static func sheet(for send: PendingSend, original: MessageMetadata, account: Account?) -> PendingSheet {
        let message = send.message
        let text = message.text
        let rendered = PlainTextRenderer.render(text)
        let html = "<div class=\"\(HTMLSanitizer.bodyClass) \(HTMLSanitizer.plainBodyClass)\">" + rendered.html + "</div>"
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let snippet = String(plain.split(whereSeparator: \.isNewline).first.map(String.init)?.prefix(200) ?? "")
        let id = MessageID(accountID: message.accountID, providerID: idPrefix + send.id)
        let from = account.map { EmailAddress(name: $0.displayName, address: $0.email) }
        let metadata = MessageMetadata(
            id: id, conversationID: original.conversationID, subject: message.subject, snippet: snippet, from: from,
            to: message.to, cc: message.cc, bcc: message.bcc, date: send.createdAt, roles: [.sent], isRead: true,
            isStarred: false, hasAttachments: false
        )
        let body = StoredBody(
            body: MessageBody(html: nil, text: text), renderedHTML: html, plainText: plain,
            hasQuotedContent: rendered.hasQuotedContent, blockedRemoteImageCount: 0, typesetting: .plain,
            declaresColors: false, coveredByNewYork: NewYorkCoverage.covers(plain)
        )
        return PendingSheet(metadata: metadata, body: body, original: original.id)
    }
}
