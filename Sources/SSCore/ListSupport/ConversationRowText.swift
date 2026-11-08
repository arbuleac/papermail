import Foundation

/// The plain strings and marks one message-list row shows (spec §5.7), derived from a `ConversationSummary`
/// without AppKit so the derivation can be measured and tested on its own. The app layer only wraps these in
/// attributed strings and draws the marks.
public struct ConversationRowText: Hashable, Sendable {
    /// Placeholders for missing data (spec §4.1): set in the role they replace, italic `ink3`, never Semibold.
    public static let noSender = "No sender"
    public static let noSubject = "No subject"
    /// How the user appears in a sender line.
    public static let me = "me"
    /// Enough names to see who is in a thread without turning the line into a list of everyone who ever replied.
    public static let maxSenderNames = 3
    /// The tag on an Inbox row that came back from Later, while it is unread (spec §5.7), and the word before a Later
    /// row's time (“Back Tue 09:00”).
    public static let back = "Back"

    /// Which sender line a row gets: the senders, or, in Drafts and Sent, the people the mail is going to.
    public enum Kind: Int, Hashable, Sendable {
        case received
        /// "Draft to Ben Carter"
        case draft
        /// "To Ben Carter"
        case sent
    }

    /// The row's queued or failed mark before the time (spec §5.7).
    public enum Status: Hashable, Sendable {
        case none
        /// `ss.queued`: applied on this Mac, waiting to reach the server.
        case queued
        /// The triangle: the operation was given up and the row restored.
        case failed(OperationKind)
    }

    /// Which date a row's time slot shows (spec §5.7).
    public enum TimeSource: Int, Hashable, Sendable {
        /// The latest message's: every view but the two below.
        case latestMessage
        /// The Inbox's own (`ConversationSummary.inboxDate`), so a conversation back from Later shows when it came
        /// back, under the head it sorts under; and its “Back” tag while it is unread.
        case inbox
        /// When the snooze ends, in Later: “Back Tue 09:00”.
        case snoozeEnd
    }

    /// Everything about the row's surroundings the strings depend on.
    public struct Context: Hashable, Sendable {
        public var kind: Kind
        public var timeStyle: DateFormatting.Style
        /// The user's own addresses, lowercased: they read "me" in a sender line.
        public var ownAddresses: Set<String>
        /// The sender of the conversation's newest message, whose face the row shows (spec §5.29). Nil falls
        /// back to the newest distinct sender in `participants`.
        public var latestSender: EmailAddress?
        /// Drafts and Sent: who the newest draft or sent message is addressed to.
        public var recipients: [EmailAddress]
        /// The account's name for VoiceOver, which ends every row label with it (spec §4.2).
        public var accountName: String?
        public var timeSource: TimeSource

        public init(
            kind: Kind = .received,
            timeStyle: DateFormatting.Style = .relative,
            ownAddresses: Set<String> = [],
            latestSender: EmailAddress? = nil,
            recipients: [EmailAddress] = [],
            accountName: String? = nil,
            timeSource: TimeSource = .latestMessage
        ) {
            self.kind = kind
            self.timeStyle = timeStyle
            self.ownAddresses = ownAddresses
            self.latestSender = latestSender
            self.recipients = recipients
            self.accountName = accountName
            self.timeSource = timeSource
        }
    }

    /// "Draft to" or "To", set in `ink2` before the names; nil for received mail.
    public let senderPrefix: String?
    /// The names, or `noSender`.
    public let senderNames: String
    public let isSenderPlaceholder: Bool
    public let timeText: String
    public let subjectText: String
    public let isSubjectPlaceholder: Bool
    public let snippetText: String
    /// At most two letters for the face (spec §4.3).
    public let initials: String
    /// The lowercased address the face's tint is hashed from, so a sender looks the same in every account.
    public let avatarAddress: String
    /// The message count when the conversation holds two or more messages.
    public let messageCount: Int?
    public let isUnread: Bool
    public let isStarred: Bool
    public let hasAttachments: Bool
    /// The Inbox row came back from Later and is unread: it carries the “Back” tag before the time (spec §5.7).
    public let showsBackTag: Bool
    public let status: Status
    /// What VoiceOver reads for the row (spec §4.14).
    public let accessibilityLabel: String

    /// The whole sender line as one string, prefix included.
    public var senderLine: String {
        guard let senderPrefix else { return senderNames }
        return senderNames.isEmpty ? senderPrefix : senderPrefix + " " + senderNames
    }

    public init(
        summary: ConversationSummary,
        reference: DateFormatting.Reference,
        formatter: DateFormatting,
        context: Context = Context()
    ) {
        let own = context.ownAddresses
        switch context.kind {
        case .received:
            senderPrefix = nil
            senderNames = ConversationRowText.senderLine(for: summary.participants, ownAddresses: own)
            isSenderPlaceholder = summary.participants.isEmpty
        case .draft, .sent:
            let names = ConversationRowText.names(context.recipients, ownAddresses: own)
            if context.kind == .draft {
                // A draft with nobody on it yet is just "Draft"; "Draft to" with nothing after reads as broken.
                senderPrefix = names.isEmpty ? "Draft" : "Draft to"
                senderNames = names
                isSenderPlaceholder = false
            } else if names.isEmpty {
                senderPrefix = nil
                senderNames = ConversationRowText.senderLine(for: summary.participants, ownAddresses: own)
                isSenderPlaceholder = summary.participants.isEmpty
            } else {
                senderPrefix = "To"
                senderNames = names
                isSenderPlaceholder = false
            }
        }
        switch context.timeSource {
        case .latestMessage:
            timeText = formatter.string(for: summary.latestDate, reference: reference, style: context.timeStyle)
        case .inbox:
            timeText = formatter.string(for: summary.inboxDate, reference: reference, style: context.timeStyle)
        case .snoozeEnd:
            if let due = summary.snoozedUntil {
                timeText = ConversationRowText.back + " " + formatter.dueTime(for: due, reference: reference)
            } else {
                timeText = formatter.string(for: summary.latestDate, reference: reference, style: context.timeStyle)
            }
        }
        let subject = ConversationRowText.singleLine(summary.subject)
        isSubjectPlaceholder = subject.isEmpty
        subjectText = subject.isEmpty ? ConversationRowText.noSubject : subject
        snippetText = ConversationRowText.singleLine(summary.snippet)

        let face = ConversationRowText.facePerson(summary: summary, context: context)
        initials = face.map(ConversationRowText.initials(for:)) ?? "?"
        avatarAddress = face?.address.lowercased() ?? ""

        messageCount = summary.messageCount > 1 ? summary.messageCount : nil
        isUnread = summary.unreadCount > 0
        isStarred = summary.isStarred
        hasAttachments = summary.hasAttachments
        showsBackTag = context.timeSource == .inbox && summary.unreadCount > 0 && summary.inboxDate != summary.latestDate
        if let failed = summary.failedOperation {
            status = .failed(failed)
        } else if summary.hasPendingOperations {
            status = .queued
        } else {
            status = .none
        }

        var parts: [String] = []
        if isUnread { parts.append("Unread") }
        if isStarred { parts.append("Starred") }
        if showsBackTag { parts.append("Back from Later") }
        let names = senderNames
        if isSenderPlaceholder {
            parts.append(ConversationRowText.noSender)
        } else if let prefix = senderPrefix {
            parts.append(names.isEmpty ? prefix : prefix + " " + names)
        } else {
            parts.append(names)
        }
        parts.append(subjectText)
        if !snippetText.isEmpty { parts.append(snippetText) }
        parts.append(timeText)
        if let count = messageCount { parts.append("\(count) messages") }
        if hasAttachments { parts.append("Has attachments") }
        switch status {
        case .none: break
        case .queued: parts.append("Waiting to sync")
        case .failed(let kind): parts.append(ConversationRowText.failureText(for: kind))
        }
        if let accountName = context.accountName, !accountName.isEmpty { parts.append("\(accountName) account") }
        accessibilityLabel = parts.map { $0.hasSuffix(".") || $0.hasSuffix("?") || $0.hasSuffix("!") || $0.hasSuffix("…") ? $0 : $0 + "." }
            .joined(separator: " ")
    }

    // MARK: Sender lines

    /// The last few distinct senders, oldest first, matching how the store orders `participants`; the user's
    /// own addresses read "me".
    public static func senderLine(for participants: [EmailAddress], ownAddresses: Set<String> = []) -> String {
        guard !participants.isEmpty else { return noSender }
        return names(Array(participants.suffix(maxSenderNames)), ownAddresses: ownAddresses)
    }

    static func names(_ people: [EmailAddress], ownAddresses: Set<String>) -> String {
        var names: [String] = []
        names.reserveCapacity(min(people.count, maxSenderNames))
        for person in people.prefix(maxSenderNames) {
            names.append(displayName(of: person, ownAddresses: ownAddresses))
        }
        return names.joined(separator: ", ")
    }

    static func displayName(of person: EmailAddress, ownAddresses: Set<String>) -> String {
        if !ownAddresses.isEmpty, ownAddresses.contains(person.address.lowercased()) { return me }
        let name = person.shortDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? localPart(of: person.address) : name
    }

    /// The person whose face the row shows: in Drafts and Sent the first recipient, otherwise the most recent
    /// sender (spec §5.29, "a group conversation shows its most recent sender"), as `latestSender(in:)` picks.
    static func facePerson(summary: ConversationSummary, context: Context) -> EmailAddress? {
        if context.kind != .received, let first = context.recipients.first { return first }
        return context.latestSender ?? summary.participants.last
    }

    /// The sender of the newest message someone other than the user sent; the user only when nobody else has
    /// written. A face of yourself on your own inbox row would say nothing about the conversation.
    public static func latestSender(in messages: [MessageMetadata], ownAddresses: Set<String>) -> EmailAddress? {
        var mine: EmailAddress?
        for message in messages.reversed() {
            guard let from = message.from else { continue }
            if ownAddresses.contains(from.address.lowercased()) {
                if mine == nil { mine = from }
                continue
            }
            return from
        }
        return mine
    }

    /// Who a Drafts or Sent row names: the newest message in that role, To first, then Cc, then Bcc.
    public static func recipients(in messages: [MessageMetadata], kind: Kind) -> [EmailAddress] {
        let role: MailboxRole
        switch kind {
        case .received: return []
        case .draft: role = .drafts
        case .sent: role = .sent
        }
        guard let message = messages.last(where: { $0.roles.contains(role) }) ?? messages.last else { return [] }
        if !message.to.isEmpty { return message.to }
        if !message.cc.isEmpty { return message.cc }
        return message.bcc
    }

    /// "Couldn't archive": the failed row's tooltip and VoiceOver words (spec §5.7, §4.13).
    public static func failureText(for kind: OperationKind) -> String {
        switch kind {
        case .archive: return "Couldn't archive"
        case .moveToInbox: return "Couldn't move to Inbox"
        case .markRead: return "Couldn't mark as read"
        case .markUnread: return "Couldn't mark as unread"
        case .star: return "Couldn't star"
        case .unstar: return "Couldn't unstar"
        case .trash: return "Couldn't move to Trash"
        case .restoreFromTrash: return "Couldn't restore from Trash"
        case .unsubscribe: return "Couldn't unsubscribe"
        }
    }

    // MARK: Initials

    /// At most two letters (spec §4.3): the first letters of the first and last words of the display name,
    /// else the first letter or digit of the address. "?" when nothing yields one.
    public static func initials(for address: EmailAddress) -> String {
        let fromName = initials(in: address.name ?? "")
        if !fromName.isEmpty { return fromName.uppercased() }
        let local = localPart(of: address.address)
        if let first = local.unicodeScalars.first(where: isInitialScalar) ?? address.address.unicodeScalars.first(where: isInitialScalar) {
            return String(Character(first)).uppercased()
        }
        return "?"
    }

    private static func isInitialScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private static func localPart(of address: String) -> String {
        address.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? address
    }

    /// The first letter of the first and of the last word. Words break at whitespace and commas only, so
    /// "Mary-Jane O'Neil" stays two words ("MO"), as the face's renderer splits them.
    private static func initials(in source: String) -> String {
        var firstLetters: [Unicode.Scalar] = []
        for word in source.split(whereSeparator: { $0.isWhitespace || $0 == "," }) {
            if let letter = word.unicodeScalars.first(where: isInitialScalar) { firstLetters.append(letter) }
        }
        guard let first = firstLetters.first else { return "" }
        var result = String(Character(first))
        if firstLetters.count > 1, let last = firstLetters.last { result.append(Character(last)) }
        return result
    }

    // MARK: Cache key

    /// Hash of everything that changes what a row looks like, plus the day so cached "14:05" strings expire
    /// when they would become "Tue". The hash is 64-bit, so an accidental collision is far rarer than a bug.
    public static func cacheKey(for summary: ConversationSummary, dayStamp: Int) -> UInt64 {
        var hasher = StableHasher()
        combine(summary, into: &hasher)
        hasher.combine(dayStamp)
        return hasher.finalized
    }

    /// `cacheKey(for:dayStamp:)` extended with the row's context and a caller's environment key (appearance,
    /// contrast, Graphite, the Font setting), which the app adds because its attributed strings depend on them.
    public static func cacheKey(for summary: ConversationSummary, dayStamp: Int, context: Context, environment: String) -> UInt64 {
        var hasher = StableHasher()
        combine(summary, into: &hasher)
        hasher.combine(dayStamp)
        hasher.combine(context.kind.rawValue)
        hasher.combine(context.timeStyle.rawValue)
        for address in context.ownAddresses.sorted() { hasher.combine(address) }
        hasher.combine(context.latestSender?.name ?? "")
        hasher.combine(context.latestSender?.address ?? "")
        hasher.combine(context.recipients.count)
        for person in context.recipients {
            hasher.combine(person.name ?? "")
            hasher.combine(person.address)
        }
        hasher.combine(context.accountName ?? "")
        hasher.combine(context.timeSource.rawValue)
        hasher.combine(environment)
        return hasher.finalized
    }

    private static func combine(_ summary: ConversationSummary, into hasher: inout StableHasher) {
        hasher.combine(summary.id.accountID.rawValue)
        hasher.combine(summary.id.providerID)
        hasher.combine(summary.latestDate)
        hasher.combine(summary.latestMessageID.providerID)
        hasher.combine(summary.unreadCount)
        hasher.combine(summary.messageCount)
        hasher.combine(summary.isStarred)
        hasher.combine(summary.hasAttachments)
        hasher.combine(summary.hasPendingOperations)
        hasher.combine(summary.failedOperation?.rawValue ?? "")
        hasher.combine(summary.returnedAt ?? .distantPast)
        hasher.combine(summary.snoozedUntil ?? .distantPast)
        hasher.combine(summary.subject)
        hasher.combine(summary.snippet)
        hasher.combine(summary.participants.count)
        for participant in summary.participants {
            hasher.combine(participant.name ?? "")
            hasher.combine(participant.address)
        }
    }

    // MARK: Text shaping

    /// Collapses every run of whitespace, newlines included, into one space and trims the ends. Provider
    /// snippets arrive with the line breaks of the original mail and a one-line row would otherwise show only
    /// the first line.
    static func singleLine(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            let isWhitespace: Bool
            switch scalar {
            case " ", "\n", "\r", "\t", "\u{0B}", "\u{0C}", "\u{A0}", "\u{2028}", "\u{2029}":
                isWhitespace = true
            default:
                isWhitespace = false
            }
            if isWhitespace {
                pendingSpace = !result.isEmpty
            } else {
                if pendingSpace {
                    result.unicodeScalars.append(" ")
                    pendingSpace = false
                }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
