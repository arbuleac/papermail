import Foundation

/// Everything the conversation shell's JavaScript needs for one `ss.render` call.
///
/// The property names are the JSON keys the shell reads, so they are a contract with
/// `ConversationShellAssets.js`; a test snapshots the key list so a rename on either side fails
/// loudly instead of rendering blank cards. Every value is already display-ready (dates formatted,
/// initials derived, HTML sanitized at sync time) so rendering never touches the store or parses HTML.
public struct RenderPayload: Hashable, Codable, Sendable {
    public struct Sender: Hashable, Codable, Sendable {
        public var name: String
        public var address: String
        public var initials: String
        /// Hex color for the avatar circle, derived from the address so a sender keeps one color everywhere.
        public var color: String

        public init(name: String, address: String, initials: String, color: String) {
            self.name = name
            self.address = address
            self.initials = initials
            self.color = color
        }
    }

    public struct Attachment: Hashable, Codable, Sendable {
        /// Provider attachment id; echoed back in `openAttachment` actions.
        public var id: String
        public var name: String
        /// Human-readable size ("1.2 MB"), formatted here so the shell stays locale-free.
        public var size: String
        public var mime: String

        public init(id: String, name: String, size: String, mime: String) {
            self.id = id
            self.name = name
            self.size = size
            self.mime = mime
        }
    }

    public struct Message: Hashable, Codable, Sendable {
        /// Opaque render key (see `RenderPayload.messageKey(for:)`); the shell echoes it in actions.
        public var id: String
        public var from: Sender
        /// Display string of the To recipients ("Ada, me").
        public var to: String
        public var cc: String
        public var dateISO: String
        public var dateDisplay: String
        public var snippet: String
        public var isUnread: Bool
        public var isStarred: Bool
        /// False while the body is still being hydrated; `html` then carries a snippet fallback.
        public var hasBody: Bool
        /// Sanitized HTML (or a text fallback) loaded into a sandboxed iframe via `srcdoc`.
        public var html: String
        public var hasQuotedContent: Bool
        public var blockedRemoteImageCount: Int
        public var attachments: [Attachment]

        public init(
            id: String,
            from: Sender,
            to: String,
            cc: String,
            dateISO: String,
            dateDisplay: String,
            snippet: String,
            isUnread: Bool,
            isStarred: Bool,
            hasBody: Bool,
            html: String,
            hasQuotedContent: Bool,
            blockedRemoteImageCount: Int,
            attachments: [Attachment]
        ) {
            self.id = id
            self.from = from
            self.to = to
            self.cc = cc
            self.dateISO = dateISO
            self.dateDisplay = dateDisplay
            self.snippet = snippet
            self.isUnread = isUnread
            self.isStarred = isStarred
            self.hasBody = hasBody
            self.html = html
            self.hasQuotedContent = hasQuotedContent
            self.blockedRemoteImageCount = blockedRemoteImageCount
            self.attachments = attachments
        }
    }

    public var subject: String
    /// Oldest first, the order the cards are stacked in.
    public var messages: [Message]

    public init(subject: String, messages: [Message]) {
        self.subject = subject
        self.messages = messages
    }

    // MARK: Message keys

    /// Separates account id and provider id in a render key. Account ids are UUID strings and never contain
    /// it, so splitting at the first occurrence is unambiguous even when a provider id does.
    public static let messageKeySeparator: Character = "|"

    public static func messageKey(for id: MessageID) -> String {
        id.accountID.rawValue + String(messageKeySeparator) + id.providerID
    }

    public static func messageID(fromKey key: String) -> MessageID? {
        guard let separator = key.firstIndex(of: messageKeySeparator) else { return nil }
        let account = String(key[key.startIndex..<separator])
        let provider = String(key[key.index(after: separator)...])
        guard !account.isEmpty, !provider.isEmpty else { return nil }
        return MessageID(accountID: AccountID(account), providerID: provider)
    }

    /// The JSON literal handed to `ss.render`. JSONEncoder escapes slashes, which keeps the literal inert
    /// even if it ever ends up inside a `<script>` element.
    public func jsonString() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}
