import Foundation

/// What a new-mail notification says (spec §5.41). macOS draws the notification; this decides its words, so
/// the rules can be tested without a notification center.
public struct NewMailNotificationContent: Equatable, Sendable {
    public var title: String
    public var subtitle: String
    /// Nil when previews are off: the notification then shows no body at all.
    public var body: String?

    public init(title: String, subtitle: String, body: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
    }

    /// More than this many notifications for one account within `summaryWindow` become one summary.
    public static let summaryThreshold = 3
    public static let summaryWindow: TimeInterval = 30
    /// The body is the snippet's first line, cut to this many characters.
    public static let bodyMaxCharacters = 120

    /// One new conversation. With previews on: the sender's name (else the address, else “No sender”), the
    /// subject (else “No subject”) and the snippet's first line. With previews off: “New message” over the
    /// account's name, and no body, so neither the sender nor the subject shows on a locked or shared screen.
    public static func conversation(_ row: ConversationSummary, accountName: String, showPreviews: Bool) -> NewMailNotificationContent {
        guard showPreviews else { return NewMailNotificationContent(title: "New message", subtitle: accountName) }
        let sender = row.participants.last
        let name = sender?.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let address = sender?.address.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = !name.isEmpty ? name : !address.isEmpty ? address : "No sender"
        let subject = row.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return NewMailNotificationContent(title: title, subtitle: subject.isEmpty ? "No subject" : subject, body: firstLine(of: row.snippet))
    }

    /// Several conversations for one account at once: “3 new messages” over the account's name, whatever the
    /// preview setting, because it names no sender.
    public static func summary(count: Int, accountName: String) -> NewMailNotificationContent {
        NewMailNotificationContent(title: "\(count) new messages", subtitle: accountName)
    }

    /// The snippet's first non-empty line, at most `bodyMaxCharacters` long (with “…” when cut); nil when empty.
    static func firstLine(of snippet: String) -> String? {
        let line = snippet.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard !line.isEmpty else { return nil }
        guard line.count > bodyMaxCharacters else { return line }
        return String(line.prefix(bodyMaxCharacters - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
