import AppKit
import SSCore

/// Everything a row draws, built once per summary version and shared through `RowContentCache`.
///
/// A class because `NSCache` stores objects; immutable so the same instance can back several rows at once.
@MainActor
final class ConversationRowContent {
    let sender: NSAttributedString
    let time: NSAttributedString
    /// Measured once so `layout()` never has to ask the text system for a size.
    let timeWidth: CGFloat
    let subject: NSAttributedString
    let snippet: NSAttributedString
    let badge: NSAttributedString?
    let badgeWidth: CGFloat
    let initials: String
    let avatarColorIndex: Int
    let isUnread: Bool
    let isStarred: Bool
    let hasAttachments: Bool
    let hasPendingOperations: Bool

    init(text: ConversationRowText, summary: ConversationSummary) {
        let unread = text.isUnread
        sender = NSAttributedString(string: text.senderLine, attributes: unread ? Style.senderUnread : Style.sender)
        time = NSAttributedString(string: text.timeText, attributes: Style.time)
        timeWidth = ceil(time.size().width) + 2
        subject = NSAttributedString(string: text.subjectText, attributes: unread ? Style.subjectUnread : Style.subject)
        snippet = NSAttributedString(string: text.snippetText, attributes: Style.snippet)
        if let count = text.countBadge {
            let badge = NSAttributedString(string: count, attributes: Style.badge)
            self.badge = badge
            badgeWidth = max(Style.badgeMinimumWidth, ceil(badge.size().width) + Style.badgePadding)
        } else {
            badge = nil
            badgeWidth = 0
        }
        initials = text.initials
        avatarColorIndex = AvatarCache.colorIndex(for: text.avatarSeed)
        isUnread = unread
        isStarred = summary.isStarred
        hasAttachments = summary.hasAttachments
        hasPendingOperations = summary.hasPendingOperations
    }

    /// Attribute dictionaries are shared, not rebuilt per row, because `NSFont` lookups are not free.
    private enum Style {
        static let badgeMinimumWidth: CGFloat = 18
        static let badgePadding: CGFloat = 10

        static let truncating: NSParagraphStyle = {
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            style.allowsDefaultTighteningForTruncation = false
            return style
        }()

        static let sender: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: truncating,
        ]
        static let senderUnread: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .bold),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: truncating,
        ]
        static let subject: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: truncating,
        ]
        static let subjectUnread: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: truncating,
        ]
        static let snippet: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: truncating,
        ]
        static let time: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        static let badge: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
    }
}
