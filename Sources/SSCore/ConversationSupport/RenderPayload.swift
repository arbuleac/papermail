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
        /// The file mark's family (spec §5.57): the band's ink, `--q-file-<family>`.
        public var family: FileFamily
        /// The type in capitals on the mark's band (“PDF”), or empty for a plain sheet.
        public var label: String
        /// The kind named in the chip's meta line, "PDF · 240 KB".
        public var kind: String

        public init(id: String, name: String, size: String, mime: String, family: FileFamily = .other, label: String = "",
                    kind: String = "") {
            self.id = id
            self.name = name
            self.size = size
            self.mime = mime
            self.family = family
            self.label = label
            self.kind = kind
        }

        /// The chip of a stored attachment, its mark and kind from `FileMark` (spec §5.57).
        public init(id: String, name: String, size: String, mime: String, mark: FileMark) {
            self.init(id: id, name: name, size: size, mime: mime, family: mark.family, label: mark.label, kind: mark.kind)
        }
    }

    /// The invitation card above a message's body (spec §5.14), every line display-ready.
    public struct Invitation: Hashable, Codable, Sendable {
        public var title: String
        /// “Tue 10 Nov · 15:00 – 16:00”, in this Mac's zone (or as written, for all-day and floating events).
        public var when: String
        /// The same in the event's own zone with its name, when that zone is at another offset: “Tue 10 Nov · 09:00 –
        /// 10:00 Eastern Time”.
        public var whenElsewhere: String?
        /// The repeat rule in words.
        public var repeats: String?
        public var location: String?
        /// The location again, when it is exactly a web address: drawn as a link.
        public var locationURL: String?
        /// A meeting link the invitation names apart from its location.
        public var conferenceURL: String?
        /// The organizer's name, or “You”.
        public var organizer: String?
        /// “You, Ada Lovelace, Sam Lee, Tom Hughes +3 more”: the first four, then a count.
        public var guests: String?
        /// The organizer called it off: marked Cancelled, no answer buttons.
        public var isCancelled: Bool
        /// Accept · Tentative · Decline are offered (not cancelled, not the user's own event, an organizer to answer, and
        /// no later revision in the conversation).
        public var canAnswer: Bool
        /// The user's answer as the card shows it chosen (`accepted`, `tentative`, `declined`); nil for none yet.
        public var response: InvitationResponse?
        /// The answer waits for permission to update the calendar: the card asks to reconnect.
        public var needsPermission: Bool
        /// Open in Calendar is offered: the message has calendar text to hand over.
        public var canOpen: Bool
        /// “Overlaps 1:1 with Sam, 13:30 - 14:00”: what the invitation overlaps on the user's calendars (spec §5.14). Nil,
        /// and then absent from the JSON, when it overlaps nothing or the card cannot say so.
        public var overlap: String?

        public init(title: String, when: String, whenElsewhere: String? = nil, repeats: String? = nil, location: String? = nil,
                    locationURL: String? = nil, conferenceURL: String? = nil, organizer: String? = nil, guests: String? = nil,
                    isCancelled: Bool = false, canAnswer: Bool = false, response: InvitationResponse? = nil,
                    needsPermission: Bool = false, canOpen: Bool = false, overlap: String? = nil) {
            self.title = title
            self.when = when
            self.whenElsewhere = whenElsewhere
            self.repeats = repeats
            self.location = location
            self.locationURL = locationURL
            self.conferenceURL = conferenceURL
            self.organizer = organizer
            self.guests = guests
            self.isCancelled = isCancelled
            self.canAnswer = canAnswer
            self.response = response
            self.needsPermission = needsPermission
            self.canOpen = canOpen
            self.overlap = overlap
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

    /// A draft sheet shown in the Outbox (spec §5.53): a message on its way, which the footer never offers to discard.
    public struct OutboxSheet: Hashable, Codable, Sendable {
        /// A Send Later message still held: the footer offers Continue editing, which cancels its schedule and opens its
        /// draft, as from Drafts. Nothing else on a message on its way is the user's to change from here.
        public var continues: Bool
        /// It failed: the date line, which then gives the reason, is set in `danger`.
        public var failed: Bool

        public init(continues: Bool, failed: Bool) {
            self.continues = continues
            self.failed = failed
        }
    }

    /// What reader mode shows of a message (spec §5.59), named on the line in its banner area.
    public enum ReaderView: String, Hashable, Codable, Sendable {
        /// The sender's text part: “Text version”, with Show original.
        case text
        /// The text taken from the HTML when it was stored: “Text from the email's design”, with Show original.
        case extracted
        /// Neither version has words (a design of pictures): the provider's snippet, “Preview text”, with Show original.
        case snippet
        /// Shown as sent at the user's word for the session: “Original”, with Show text.
        case original
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
        /// The parked images the sanitizer marked as trackers (spec §5.60), part of `blockedRemoteImageCount`: while
        /// `RenderPayload.blocksTrackers` is on, Load images leaves them parked, the banner does not count them, and the
        /// card says how many were blocked. Zero for a body stored before the marks, whose known pixels the shell tells by
        /// their address (`unmarkedTrackers`).
        public var trackerImageCount: Int
        public var attachments: [Attachment]
        /// The stored `BodyTypesetting` (encoded as its name): `plain` and `unstyled` bodies are set on the Quire
        /// reading page, `styled` ones keep the sender's design. Bodies stored before it was kept are `styled`.
        public var typesetting: BodyTypesetting
        /// The stored `SanitizedBody.declaresColors`; true when unknown for a styled body, as §8.5 asks.
        public var declaresColors: Bool
        /// The stored `SanitizedBody.coveredByNewYork`; false when unknown.
        public var coveredByNewYork: Bool
        /// The message's list headers offer a way to unsubscribe (`UnsubscribeMethod`): its sheet header shows the
        /// Unsubscribe link beside the sender (spec §5.14). Never on a draft or a pending reply.
        public var unsubscribe: Bool
        /// The invitation card above the body; nil (and absent from the JSON) for every message without one.
        public var invitation: Invitation?
        /// A Send Later message still waiting for its time (Drafts, spec §5.19): its date line reads “Sends Mon 09:00”
        /// and Cancel follows it, which takes the schedule back and leaves the draft.
        public var cancelsSendLater: Bool
        /// Set on a draft sheet shown in the Outbox (spec §5.53); nil (and absent from the JSON) everywhere else.
        public var outbox: OutboxSheet?
        /// The paperclip on the row and the header (spec §5.13), as in the list. Once the body is here it means
        /// attachments the reader shows (inline pictures are part of the body, not attachments); until then it is
        /// the provider's flag, the one the list row draws from.
        public var hasAttachments: Bool
        /// Reader mode's view of the message (spec §5.59); nil, and absent from the JSON, while reader mode is off and on a
        /// message it leaves alone (a draft, a reply on its way, one with no words yet).
        public var reader: ReaderView?

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
            trackerImageCount: Int = 0,
            attachments: [Attachment],
            typesetting: BodyTypesetting = .styled,
            declaresColors: Bool = true,
            coveredByNewYork: Bool = false,
            unsubscribe: Bool = false,
            invitation: Invitation? = nil,
            cancelsSendLater: Bool = false,
            outbox: OutboxSheet? = nil,
            hasAttachments: Bool? = nil,
            reader: ReaderView? = nil
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
            self.trackerImageCount = trackerImageCount
            self.attachments = attachments
            self.typesetting = typesetting
            self.declaresColors = declaresColors
            self.coveredByNewYork = coveredByNewYork
            self.unsubscribe = unsubscribe
            self.invitation = invitation
            self.cancelsSendLater = cancelsSendLater
            self.outbox = outbox
            self.hasAttachments = hasAttachments ?? !attachments.isEmpty
            self.reader = reader
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
    /// The reader's Text size (spec §4.15), by name: `small`, `default`, `large` or `larger`. The shell puts every
    /// other size's `html.ss-text-<name>` class on itself and on each body document.
    public var textSize: String
    /// The Original colors notice was dismissed for good (`originalColorsNoticeDismissed`, spec §5.16).
    public var colorsNoticeDismissed: Bool
    /// Settings › Appearance › Dark Mode, “Adapt mail that sets its own colours” (spec §5.14): in a dark appearance, styled
    /// mail that declares its own colours opens adapted (true) or as sent on the white page (false). Nil leaves the shell
    /// with the default it was last told, adapted until told otherwise, and is not encoded.
    public var adaptsColours: Bool?
    /// Settings › Experimental › Block trackers (spec §5.60): images marked as trackers stay parked when the others load,
    /// and each card that had some says how many were blocked.
    public var blocksTrackers: Bool

    public init(
        subject: String,
        participants: String = "",
        messages: [Message],
        loadRemoteImages: Bool = false,
        inkSlot: Int = 0,
        readingSans: Bool = false,
        textSize: String = "default",
        colorsNoticeDismissed: Bool = false,
        adaptsColours: Bool? = nil,
        blocksTrackers: Bool = false
    ) {
        self.subject = subject
        self.participants = participants
        self.messages = messages
        self.loadRemoteImages = loadRemoteImages
        self.inkSlot = inkSlot
        self.readingSans = readingSans
        self.textSize = textSize
        self.colorsNoticeDismissed = colorsNoticeDismissed
        self.adaptsColours = adaptsColours
        self.blocksTrackers = blocksTrackers
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
