import AppKit
import SSCore
import SSDesign

/// Everything a row draws, built once per (summary version, context, environment) and shared through
/// `RowContentCache` (spec §5.7, performance contract).
///
/// A class because `NSCache` stores objects; immutable so the same instance can back several rows at once.
/// Text never changes colour with selection or window key state (spec §3.4), so nothing here depends on them.
@MainActor
final class ConversationRowContent {
    let sender: NSAttributedString
    let time: NSAttributedString
    /// Measured once so `layout()` never has to ask the text system for a size.
    let timeWidth: CGFloat
    let subject: NSAttributedString
    let snippet: NSAttributedString
    /// Compact density's line 2: the subject, " — " and the snippet on the subject's baseline.
    let compactLine: NSAttributedString
    let messageCount: Int?
    let badgeSize: NSSize
    let initials: String
    let tint: Quire.AvatarTint
    let isUnread: Bool
    let isStarred: Bool
    let hasAttachments: Bool
    let showsOtherTag: Bool
    let status: ConversationRowText.Status
    /// The failed row's tooltip: “Couldn't archive”.
    let failureText: String?
    let accessibilityLabel: String

    init(text: ConversationRowText) {
        let unread = text.isUnread
        sender = Style.sender(text, unread: unread)
        time = QuireFont.attributedString(text.timeText, role: unread ? .metaStrong : .meta, color: unread ? .qAccent : .qInk3)
        timeWidth = ceil(time.size().width)
        subject = Style.subject(text, unread: unread)
        snippet = QuireFont.attributedString(text.snippetText, role: .snippet, color: .qInk2)
        compactLine = Style.compactLine(subject: subject, snippet: text.snippetText)
        messageCount = text.messageCount
        badgeSize = text.messageCount.map { QuireBadge.size(for: .messageCount($0)) } ?? .zero
        initials = text.initials
        tint = QuireAvatarRenderer.tint(forAddress: text.avatarAddress)
        isUnread = unread
        isStarred = text.isStarred
        hasAttachments = text.hasAttachments
        showsOtherTag = text.showsOtherTag
        status = text.status
        if case .failed(let kind) = text.status {
            failureText = ConversationRowText.failureText(for: kind)
        } else {
            failureText = nil
        }
        accessibilityLabel = text.accessibilityLabel
    }

    /// Attribute building shared by every row. Roles come from `QuireFont`, which caches fonts and paragraph
    /// styles; only the placeholder italics are derived here.
    private enum Style {
        static func sender(_ text: ConversationRowText, unread: Bool) -> NSAttributedString {
            if text.isSenderPlaceholder {
                return placeholder(text.senderNames, role: .sender)
            }
            let result = NSMutableAttributedString()
            if let prefix = text.senderPrefix {
                // The prefix says what kind of row this is, not who; it stays Regular `ink2` even when unread.
                result.append(QuireFont.attributedString(text.senderNames.isEmpty ? prefix : prefix + " ", role: .sender, color: .qInk2))
            }
            if !text.senderNames.isEmpty {
                result.append(QuireFont.attributedString(text.senderNames, role: .sender, color: .qInk, unread: unread))
            }
            return result
        }

        static func subject(_ text: ConversationRowText, unread: Bool) -> NSAttributedString {
            if text.isSubjectPlaceholder {
                return placeholder(text.subjectText, role: .subject)
            }
            return QuireFont.attributedString(text.subjectText, role: .subject, color: .qInk, unread: unread)
        }

        /// Missing data reads in the role it replaces, italic `ink3`, Regular even when unread (spec §4.1).
        static func placeholder(_ string: String, role: QuireFont.Role) -> NSAttributedString {
            let used = QuireFont.resolvedRole(role, for: string)
            var attributes = QuireFont.attributes(used, color: .qInk3)
            attributes[.font] = italic(used)
            return NSAttributedString(string: string, attributes: attributes)
        }

        private static var italics: [QuireFont.Role: NSFont] = [:]

        static func italic(_ role: QuireFont.Role) -> NSFont {
            if let font = italics[role] { return font }
            let base = QuireFont.font(role)
            let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.italic))
            let font = NSFont(descriptor: descriptor, size: base.pointSize) ?? base
            italics[role] = font
            return font
        }

        /// The snippet joins the subject's line box: its own font and colour, but the subject's paragraph style
        /// and baseline offset, so both sit on one baseline inside the 18 pt line.
        static func compactLine(subject: NSAttributedString, snippet: String) -> NSAttributedString {
            guard !snippet.isEmpty, subject.length > 0 else { return subject }
            let line = NSMutableAttributedString(attributedString: subject)
            var attributes = subject.attributes(at: 0, effectiveRange: nil)
            attributes[.font] = QuireFont.font(.snippet)
            attributes[.foregroundColor] = NSColor.qInk2
            attributes[.kern] = nil
            line.append(NSAttributedString(string: " — " + snippet, attributes: attributes))
            return line
        }
    }
}
