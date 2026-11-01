import AppKit

/// The visible content of one row.
///
/// Laid out by hand in `layout()` with a flipped coordinate system, because Auto Layout inside table rows is the
/// single biggest scrolling cost on long lists. Text lives in `NSTextField` labels so it can be truncated and
/// read by accessibility; the dots and the count badge are drawn directly since they are a few fills.
final class ConversationCellView: NSView {
    static let identifier = NSUserInterfaceItemIdentifier("ConversationCell")

    enum Metrics {
        static let rowHeight: CGFloat = 72
        static let avatarDiameter: CGFloat = 36
        static let avatarX: CGFloat = 16
        static let avatarY: CGFloat = 18
        static let accountDotDiameter: CGFloat = 10
        static let unreadDotDiameter: CGFloat = 8
        static let textX: CGFloat = 64
        static let trailingInset: CGFloat = 14
        static let glyphSize: CGFloat = 14
        static let glyphSpacing: CGFloat = 5
        static let badgeHeight: CGFloat = 16
    }

    private let avatarView = NSImageView()
    private let senderLabel = ConversationCellView.makeLabel()
    private let timeLabel = ConversationCellView.makeLabel()
    private let subjectLabel = ConversationCellView.makeLabel()
    private let snippetLabel = ConversationCellView.makeLabel()
    private let starView = ConversationCellView.makeGlyph(symbol: "star.fill", tint: .systemYellow, description: "Starred")
    private let attachmentView = ConversationCellView.makeGlyph(symbol: "paperclip", tint: .secondaryLabelColor, description: "Has attachments")

    private var content: ConversationRowContent?
    private var avatarKey: AvatarCache.Key?
    private var badgeRect = CGRect.zero
    private var accountColor: NSColor?

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = ConversationCellView.identifier
        wantsLayer = true
        avatarView.imageScaling = .scaleNone
        avatarView.wantsLayer = true
        for subview in [avatarView, senderLabel, timeLabel, subjectLabel, snippetLabel, starView, attachmentView] {
            addSubview(subview)
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func configure(with content: ConversationRowContent, accountColor: NSColor?, avatarCache: AvatarCache) {
        self.content = content
        self.accountColor = accountColor
        senderLabel.attributedStringValue = content.sender
        timeLabel.attributedStringValue = content.time
        subjectLabel.attributedStringValue = content.subject
        snippetLabel.attributedStringValue = content.snippet
        starView.isHidden = !content.isStarred
        attachmentView.isHidden = !content.hasAttachments
        // A queued operation has already been applied locally; the fade says "on its way", not "disabled".
        alphaValue = content.hasPendingOperations ? 0.6 : 1

        let key = AvatarCache.Key(initials: content.initials, colorIndex: content.avatarColorIndex)
        avatarKey = key
        avatarView.image = avatarCache.image(for: key) { [weak self] image in
            // The row may have been reused for another conversation while the render was in flight.
            guard let self, self.avatarKey == key else { return }
            self.avatarView.image = image
        }
        needsLayout = true
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        let right = width - Metrics.trailingInset

        avatarView.frame = CGRect(x: Metrics.avatarX, y: Metrics.avatarY, width: Metrics.avatarDiameter, height: Metrics.avatarDiameter)

        let timeWidth = content?.timeWidth ?? 0
        timeLabel.frame = CGRect(x: right - timeWidth, y: 11, width: timeWidth, height: 15)
        senderLabel.frame = CGRect(x: Metrics.textX, y: 9, width: max(0, timeLabel.frame.minX - 8 - Metrics.textX), height: 18)

        // Glyphs stack leftwards from the trailing edge under the time, in a fixed order so the eye can rely on it.
        var cursor = right
        let glyphY: CGFloat = 30
        if !starView.isHidden {
            starView.frame = CGRect(x: cursor - Metrics.glyphSize, y: glyphY, width: Metrics.glyphSize, height: Metrics.glyphSize)
            cursor -= Metrics.glyphSize + Metrics.glyphSpacing
        }
        if !attachmentView.isHidden {
            attachmentView.frame = CGRect(x: cursor - Metrics.glyphSize, y: glyphY, width: Metrics.glyphSize, height: Metrics.glyphSize)
            cursor -= Metrics.glyphSize + Metrics.glyphSpacing
        }
        if let content, content.badge != nil {
            badgeRect = CGRect(x: cursor - content.badgeWidth, y: glyphY - 1, width: content.badgeWidth, height: Metrics.badgeHeight)
            cursor -= content.badgeWidth + Metrics.glyphSpacing
        } else {
            badgeRect = .zero
        }

        subjectLabel.frame = CGRect(x: Metrics.textX, y: 28, width: max(0, cursor - 6 - Metrics.textX), height: 17)
        snippetLabel.frame = CGRect(x: Metrics.textX, y: 46, width: max(0, right - Metrics.textX), height: 16)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let content else { return }

        if content.isUnread {
            NSColor.controlAccentColor.setFill()
            let dot = CGRect(
                x: 4,
                y: (bounds.height - Metrics.unreadDotDiameter) / 2,
                width: Metrics.unreadDotDiameter,
                height: Metrics.unreadDotDiameter
            )
            NSBezierPath(ovalIn: dot).fill()
        }

        if let accountColor {
            let dot = CGRect(
                x: Metrics.avatarX + Metrics.avatarDiameter - Metrics.accountDotDiameter + 2,
                y: Metrics.avatarY + Metrics.avatarDiameter - Metrics.accountDotDiameter + 2,
                width: Metrics.accountDotDiameter,
                height: Metrics.accountDotDiameter
            )
            // A ring in the row background keeps the dot legible where it overlaps the avatar.
            NSColor.controlBackgroundColor.setFill()
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.5, dy: -1.5)).fill()
            accountColor.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }

        if let badge = content.badge, !badgeRect.isEmpty {
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: badgeRect, xRadius: Metrics.badgeHeight / 2, yRadius: Metrics.badgeHeight / 2).fill()
            let size = badge.size()
            badge.draw(at: CGPoint(x: badgeRect.midX - size.width / 2, y: badgeRect.midY - size.height / 2))
        }
    }

    // MARK: Factories

    private static func makeLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.cell?.truncatesLastVisibleLine = true
        label.allowsDefaultTighteningForTruncation = false
        label.drawsBackground = false
        label.isBezeled = false
        label.isEditable = false
        label.isSelectable = false
        return label
    }

    private static func makeGlyph(symbol: String, tint: NSColor, description: String) -> NSImageView {
        let view = NSImageView()
        view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        view.contentTintColor = tint
        view.imageScaling = .scaleProportionallyDown
        view.isHidden = true
        return view
    }
}
