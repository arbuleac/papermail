import Foundation

/// The plain strings one message-list row shows, derived from a `ConversationSummary` without AppKit so the
/// derivation can be measured and tested on its own. The app layer only wraps these in attributed strings.
public struct ConversationRowText: Hashable, Sendable {
    public static let noSender = "No sender"
    public static let noSubject = "(No subject)"
    /// Enough names to see who is in a thread without turning the line into a list of everyone who ever replied.
    public static let maxSenderNames = 3

    public let senderLine: String
    public let timeText: String
    public let subjectText: String
    public let snippetText: String
    public let initials: String
    /// Stable hash of the first participant's address; the app maps it onto its avatar palette.
    public let avatarSeed: UInt64
    /// "3" when the conversation holds more than one message, otherwise nil.
    public let countBadge: String?
    public let isUnread: Bool

    public init(summary: ConversationSummary, reference: DateFormatting.Reference, formatter: DateFormatting) {
        senderLine = ConversationRowText.senderLine(for: summary.participants)
        timeText = formatter.string(for: summary.latestDate, reference: reference)
        let subject = summary.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        subjectText = subject.isEmpty ? ConversationRowText.noSubject : subject
        snippetText = ConversationRowText.singleLine(summary.snippet)
        let first = summary.participants.first
        initials = first.map(ConversationRowText.initials(for:)) ?? "?"
        avatarSeed = StableHasher.hash(first?.address.lowercased() ?? "")
        countBadge = summary.messageCount > 1 ? String(summary.messageCount) : nil
        isUnread = summary.unreadCount > 0
    }

    /// The last few distinct senders, oldest first, matching how the store orders `participants`.
    public static func senderLine(for participants: [EmailAddress]) -> String {
        guard !participants.isEmpty else { return noSender }
        var names: [String] = []
        names.reserveCapacity(maxSenderNames)
        for participant in participants.suffix(maxSenderNames) {
            let name = participant.shortDisplay.trimmingCharacters(in: .whitespacesAndNewlines)
            names.append(name.isEmpty ? localPart(of: participant.address) : name)
        }
        return names.joined(separator: ", ")
    }

    /// Up to two characters: the first letter of the first two words of the display name, so "Ada Lovelace"
    /// gives "AL" and a bare local part such as "ada.lovelace" still gives "AL". A display name that yields
    /// nothing (whitespace, punctuation) falls back to the address, which providers do send in that shape.
    public static func initials(for address: EmailAddress) -> String {
        let fromName = initials(in: address.shortDisplay)
        if !fromName.isEmpty { return fromName.uppercased() }
        let fromAddress = initials(in: localPart(of: address.address))
        return fromAddress.isEmpty ? "?" : fromAddress.uppercased()
    }

    private static func localPart(of address: String) -> String {
        address.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? address
    }

    private static func initials(in source: String) -> String {
        var result = ""
        var atWordStart = true
        for scalar in source.unicodeScalars {
            let isSeparator: Bool
            switch scalar {
            case " ", ".", "_", "-", "\t", "\n", "\r", "'", "\"", "(", ")", "<", ">", ",":
                isSeparator = true
            default:
                isSeparator = false
            }
            if isSeparator {
                atWordStart = true
                continue
            }
            if atWordStart, scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                result.unicodeScalars.append(scalar)
                if result.unicodeScalars.count == 2 { break }
            }
            atWordStart = false
        }
        return result
    }

    /// Hash of everything that changes what a row looks like, plus the day so cached "14:05" strings expire
    /// when they would become "Tue". The hash is 64-bit, so an accidental collision is far rarer than a bug.
    public static func cacheKey(for summary: ConversationSummary, dayStamp: Int) -> UInt64 {
        var hasher = StableHasher()
        hasher.combine(summary.id.accountID.rawValue)
        hasher.combine(summary.id.providerID)
        hasher.combine(summary.latestDate)
        hasher.combine(summary.unreadCount)
        hasher.combine(summary.messageCount)
        hasher.combine(summary.isStarred)
        hasher.combine(summary.hasAttachments)
        hasher.combine(summary.hasPendingOperations)
        hasher.combine(summary.subject)
        hasher.combine(summary.snippet)
        hasher.combine(summary.participants.count)
        for participant in summary.participants {
            hasher.combine(participant.name ?? "")
            hasher.combine(participant.address)
        }
        hasher.combine(dayStamp)
        return hasher.finalized
    }

    /// Collapses every run of whitespace, newlines included, into one space. Provider snippets arrive with
    /// the line breaks of the original mail and a one-line label would otherwise show only the first line.
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
