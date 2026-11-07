import Foundation

/// Everything the conversation shell's JavaScript needs for one `ss.render` call.
///
/// The property names are the JSON keys the shell reads, so they are a contract with
/// `ConversationShellAssets.js`; a test snapshots the key list so a rename on either side fails
/// loudly instead of rendering blank cards. Every value is already display-ready (dates formatted,
/// initials derived, HTML sanitized at sync time) so rendering never touches the store or parses HTML.
public struct RenderPayload: Hashable, Codable, Sendable {
    public struct Sender: Hashable, Codable, Sendable {
        /// Empty when the message has no sender; the shell then sets "No sender" in the placeholder style.
        public var name: String
        public var address: String
        public var initials: String
        /// The avatar tint (spec §4.3): FNV-1a of the lowercased address modulo the eight tints, the same
        /// index `Quire.avatarTintIndex(forAddress:)` gives, so a sender has one face in the list and the reader.
        public var tint: Int

        public init(name: String, address: String, initials: String, tint: Int) {
            self.name = name
            self.address = address
            self.initials = initials
            self.tint = tint
        }
    }

    /// One recipient of the expanded recipients block (spec §5.14).
    public struct Person: Hashable, Codable, Sendable {
        /// "me" for the user's own addresses; the display name, or empty when the address has none.
        public var name: String
        public var address: String

        public init(name: String, address: String) {
            self.name = name
            self.address = address
        }
    }

    /// One field of the expanded recipients block: "To", "Cc" or "Bcc".
    public struct RecipientField: Hashable, Codable, Sendable {
        public var label: String
        public var people: [Person]

        public init(label: String, people: [Person]) {
            self.label = label
            self.people = people
        }
    }

    public struct Attachment: Hashable, Codable, Sendable {
        /// Provider attachment id; echoed back in `openAttachment` actions.
        public var id: String
        public var name: String
        /// Human-readable size ("1.2 MB"), formatted here so the shell stays locale-free.
        public var size: String
        public var mime: String
        /// The type tile's SF Symbol (spec §5.17): one of the reader symbols `doc`, `doc.richtext`, `photo`,
        /// `tablecells`, `doc.zipper`, `film`.
        public var symbol: String
        /// The kind named in the chip's meta line, "PDF · 240 KB".
        public var kind: String

        public init(id: String, name: String, size: String, mime: String, symbol: String = "doc", kind: String = "") {
            self.id = id
            self.name = name
            self.size = size
            self.mime = mime
            self.symbol = symbol
            self.kind = kind
        }
    }

    /// What the reader shows where a body belongs (spec §5.14, §8.4).
    public enum BodyState: String, Codable, Sendable, CaseIterable {
        /// The stored body is in `html`.
        case ready
        /// No body yet and a fetch is running: skeleton bars after 300 ms.
        case loading
        /// No body and the fetch cannot run offline: the snippet preview and the `wifi.slash` notice.
        case offline
        /// No body and the fetch failed online: "Couldn't load this message · Retry".
        case failed
        /// A draft that is open in a composer window: the sheet reads “Open in a composer window” in place of
        /// the body, which is being changed elsewhere (spec §5.19). The reader sends no body with it.
        case inComposer
    }

    public struct Message: Hashable, Codable, Sendable {
        /// Opaque render key (see `RenderPayload.messageKey(for:)`); the shell echoes it in actions.
        public var id: String
        public var from: Sender
        /// Display string of the To recipients ("Ada, me").
        public var to: String
        public var cc: String
        /// The expanded recipients: To, Cc, and Bcc on messages the user sent.
        public var recipients: [RecipientField]
        public var dateISO: String
        public var dateDisplay: String
        public var snippet: String
        public var isUnread: Bool
        public var isStarred: Bool
        /// A draft (Drafts view): read-only, set in `writing`, with Continue editing and Discard draft.
        public var isDraft: Bool
        /// A reply still in the outbox (`PendingSheet`): the date reads “Sending…” with a spinner and the sheet
        /// offers no actions (spec §5.14).
        public var isPending: Bool
        /// False while the body is still being hydrated; `html` then carries a snippet fallback.
        public var hasBody: Bool
        public var bodyState: BodyState
        /// Sanitized HTML (or a text fallback) loaded into a sandboxed iframe via `srcdoc`.
        public var html: String
        public var hasQuotedContent: Bool
        public var blockedRemoteImageCount: Int
        public var attachments: [Attachment]
        /// The stored `BodyTypesetting` (encoded as its name): `plain` and `unstyled` bodies are set on the Quire
        /// reading page, `styled` ones keep the sender's design. Bodies stored before it was kept are `styled`.
        public var typesetting: BodyTypesetting
        /// The stored `SanitizedBody.declaresColors`; true when unknown for a styled body, as §8.5 asks.
        public var declaresColors: Bool
        /// The stored `SanitizedBody.coveredByNewYork`; false when unknown.
        public var coveredByNewYork: Bool

        public init(
            id: String,
            from: Sender,
            to: String,
            cc: String,
            recipients: [RecipientField] = [],
            dateISO: String,
            dateDisplay: String,
            snippet: String,
            isUnread: Bool,
            isStarred: Bool,
            isDraft: Bool = false,
            isPending: Bool = false,
            hasBody: Bool,
            bodyState: BodyState? = nil,
            html: String,
            hasQuotedContent: Bool,
            blockedRemoteImageCount: Int,
            attachments: [Attachment],
            typesetting: BodyTypesetting = .styled,
            declaresColors: Bool = true,
            coveredByNewYork: Bool = false
        ) {
            self.id = id
            self.from = from
            self.to = to
            self.cc = cc
            self.recipients = recipients
            self.dateISO = dateISO
            self.dateDisplay = dateDisplay
            self.snippet = snippet
            self.isUnread = isUnread
            self.isStarred = isStarred
            self.isDraft = isDraft
            self.isPending = isPending
            self.hasBody = hasBody
            self.bodyState = bodyState ?? (hasBody ? .ready : .loading)
            self.html = html
            self.hasQuotedContent = hasQuotedContent
            self.blockedRemoteImageCount = blockedRemoteImageCount
            self.attachments = attachments
            self.typesetting = typesetting
            self.declaresColors = declaresColors
            self.coveredByNewYork = coveredByNewYork
        }
    }

    /// The read and star state of one card, for `ss.flags`: a mark-read or star needs no bodies.
    public struct FlagPatch: Hashable, Codable, Sendable {
        public var id: String
        public var isUnread: Bool
        public var isStarred: Bool

        public init(id: String, isUnread: Bool, isStarred: Bool) {
            self.id = id
            self.isUnread = isUnread
            self.isStarred = isStarred
        }
    }

    /// A body state change for one card, for `ss.bodyStates`: a fetch starting, failing or going offline
    /// changes what stands in for the body without a new payload.
    public struct BodyStatePatch: Hashable, Codable, Sendable {
        public var id: String
        public var bodyState: BodyState

        public init(id: String, bodyState: BodyState) {
            self.id = id
            self.bodyState = bodyState
        }
    }

    public var subject: String
    /// The participants line above the stack (spec §5.13): up to four names, then "+3".
    public var participants: String
    /// Oldest first, the order the cards are stacked in.
    public var messages: [Message]
    /// The "Load remote images" preference: when false, bodies render under a policy that blocks every
    /// remote fetch until the user loads images for a message, whatever the stored HTML holds.
    public var loadRemoteImages: Bool
    /// The conversation's account palette slot (`Account.inkSlot`); a conversation never spans accounts.
    public var inkSlot: Int
    /// Settings › General › Font is SF Pro (spec §4.4): plain and unstyled bodies use `readingSans`, and the
    /// shell's avatar initials `monogramSans` (`html.ss-sf`).
    public var readingSans: Bool
    /// The Original colors notice was dismissed for good (`originalColorsNoticeDismissed`, spec §5.16).
    public var colorsNoticeDismissed: Bool

    public init(
        subject: String,
        participants: String = "",
        messages: [Message],
        loadRemoteImages: Bool = false,
        inkSlot: Int = 0,
        readingSans: Bool = false,
        colorsNoticeDismissed: Bool = false
    ) {
        self.subject = subject
        self.participants = participants
        self.messages = messages
        self.loadRemoteImages = loadRemoteImages
        self.inkSlot = inkSlot
        self.readingSans = readingSans
        self.colorsNoticeDismissed = colorsNoticeDismissed
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
