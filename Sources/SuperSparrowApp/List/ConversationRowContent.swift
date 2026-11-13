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
    /// The subject's natural width, for compact density, where it gives way to the snippet past 60 % of the line,
    /// and for the tooltip a cut subject gets.
    let subjectWidth: CGFloat
    /// The sender line's natural width: a cut sender gets a tooltip.
    let senderWidth: CGFloat
    /// Compact density's line 2 after the subject: " — " and the snippet, on the subject's baseline.
    let compactSnippet: NSAttributedString?
    let messageCount: Int?
    let badgeSize: NSSize
    let initials: String
    let tint: Quire.AvatarTint
    let isUnread: Bool
    let isStarred: Bool
    let hasAttachments: Bool
    /// The “Back” tag before the time: an Inbox row back from Later, while unread (spec §5.7).
    let showsBackTag: Bool
    let status: ConversationRowText.Status
    /// The failed row's tooltip: “Couldn't archive”.
    let failureText: String?
    let accessibilityLabel: String

    /// The four lines are set at `textSize` (spec §4.15); the marks (badge, tag, tile) keep Default.
    init(text: ConversationRowText, textSize: QuireFont.TextSize = .default) {
        let unread = text.isUnread
        let style = Style(textSize: textSize)
        sender = style.sender(text, unread: unread)
        senderWidth = ceil(sender.size().width)
        time = QuireFont.attributedString(text.timeText, role: unread ? .metaStrong : .meta, color: unread ? .qAccent : .qInk3,
                                          textSize: textSize)
        timeWidth = ceil(time.size().width)
        subject = style.subject(text, unread: unread)
        snippet = QuireFont.attributedString(text.snippetText, role: .snippet, color: .qInk2, textSize: textSize)
        subjectWidth = ceil(subject.size().width)
        compactSnippet = style.compactSnippet(subject: subject, snippet: text.snippetText)
        messageCount = text.messageCount
        badgeSize = text.messageCount.map { QuireBadge.size(for: .messageCount($0)) } ?? .zero
        initials = text.initials
        tint = QuireAvatarRenderer.tint(forAddress: text.avatarAddress)
        isUnread = unread
        isStarred = text.isStarred
        hasAttachments = text.hasAttachments
        showsBackTag = text.showsBackTag
        status = text.status
        if case .failed(let kind) = text.status {
            failureText = ConversationRowText.failureText(for: kind)
        } else {
            failureText = nil
        }
        accessibilityLabel = text.accessibilityLabel
    }

    /// Attribute building shared by every row, at one Text size. Roles come from `QuireFont`, which caches fonts and
    /// paragraph styles; only the placeholder italics are derived here.
    private struct Style {
        let textSize: QuireFont.TextSize

        func sender(_ text: ConversationRowText, unread: Bool) -> NSAttributedString {
            if text.isSenderPlaceholder {
                return placeholder(text.senderNames, role: .sender)
            }
            let result = NSMutableAttributedString()
            if let prefix = text.senderPrefix {
                // The prefix says what kind of row this is, not who; it stays Regular `ink2` even when unread.
                result.append(QuireFont.attributedString(text.senderNames.isEmpty ? prefix : prefix + " ", role: .sender, color: .qInk2,
                                                         textSize: textSize))
            }
            if !text.senderNames.isEmpty {
                result.append(QuireFont.attributedString(text.senderNames, role: .sender, color: .qInk, unread: unread, textSize: textSize))
            }
            return result
        }

        func subject(_ text: ConversationRowText, unread: Bool) -> NSAttributedString {
            if text.isSubjectPlaceholder {
                return placeholder(text.subjectText, role: .subject)
            }
            return QuireFont.attributedString(text.subjectText, role: .subject, color: .qInk, unread: unread, textSize: textSize)
        }

        /// Missing data reads in the role it replaces, italic `ink3`, Regular even when unread (spec §4.1).
        func placeholder(_ string: String, role: QuireFont.Role) -> NSAttributedString {
            let used = QuireFont.resolvedRole(role, for: string)
            var attributes = QuireFont.attributes(used, color: .qInk3, textSize: textSize)
            attributes[.font] = Style.italic(used, textSize: textSize)
            return NSAttributedString(string: string, attributes: attributes)
        }

        private struct ItalicKey: Hashable {
            let role: QuireFont.Role
            let textSize: QuireFont.TextSize
        }

        /// Keyed by the role actually set (the twin under the SF Pro font) and the Text size, so a switch of either
        /// cannot return another face or size.
        private static var italics: [ItalicKey: NSFont] = [:]

        static func italic(_ role: QuireFont.Role, textSize: QuireFont.TextSize) -> NSFont {
            let key = ItalicKey(role: QuireFont.resolvedRole(role), textSize: textSize)
            if let font = italics[key] { return font }
            let base = QuireFont.font(key.role, textSize: textSize)
            let descriptor = base.fontDescriptor.withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(.italic))
            let font = NSFont(descriptor: descriptor, size: base.pointSize) ?? base
            italics[key] = font
            return font
        }

        /// The snippet joins the subject's line box: its own font and colour, but the subject's paragraph style
        /// and baseline offset, so both sit on one baseline inside the subject's line.
        func compactSnippet(subject: NSAttributedString, snippet: String) -> NSAttributedString? {
            guard !snippet.isEmpty, subject.length > 0 else { return nil }
            var attributes = subject.attributes(at: 0, effectiveRange: nil)
            attributes[.font] = QuireFont.font(.snippet, textSize: textSize)
            attributes[.foregroundColor] = NSColor.qInk2
            attributes[.kern] = nil
            return NSAttributedString(string: " — " + snippet, attributes: attributes)
        }
    }
}
