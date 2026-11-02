import AppKit

/// An empty state (spec §5.9): one serif sentence and one hint, centred, at most 300 pt wide. The sentence is
/// `aside` (New York Italic 17/24, or its sans twin when New York cannot set it) in `ink`; the hint is
/// `snippet` in `ink3`, 4 pt below, and may carry keycaps inline (“J K to move · ↩ to open”), which wrap with
/// the words. Inbox zero adds the sparrow, offline the `wifi.slash` glyph, 8 pt above the sentence.
///
/// The block centres itself in the view's bounds, so the view can simply fill the pane.
@MainActor
public final class QuireEmptyStateView: NSView {
    public var sentence: String {
        didSet { contentDidChange() }
    }

    public var hint: [HintPart] {
        didSet { contentDidChange() }
    }

    public var glyph: Glyph? {
        didSet { contentDidChange() }
    }

    public init(sentence: String, hint: [HintPart] = [], glyph: Glyph? = nil) {
        self.sentence = sentence
        self.hint = hint
        self.glyph = glyph
        super.init(frame: .zero)
        setFrameSize(intrinsicContentSize)
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    /// A hint of words only.
    public convenience init(sentence: String, hint: String, glyph: Glyph? = nil) {
        self.init(sentence: sentence, hint: hint.isEmpty ? [] : [.text(hint)], glyph: glyph)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireEmptyStateView is built in code") }

    public override var isFlipped: Bool { true }

    private static var maxWidth: CGFloat { Quire.Layout.EmptyState.maxWidth }

    // MARK: Strings

    private func paragraph(lineHeight: CGFloat) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        style.baseWritingDirection = .natural
        return style
    }

    private func sentenceString() -> NSAttributedString {
        let role = QuireFont.resolvedRole(.aside, for: sentence)
        let font = QuireFont.font(role)
        var attributes = QuireFont.attributes(role, color: .qInk)
        attributes[.paragraphStyle] = paragraph(lineHeight: role.lineHeight)
        attributes[.baselineOffset] = QuireFont.baselineOffset(for: font, lineHeight: role.lineHeight)
        return NSAttributedString(string: sentence, attributes: attributes)
    }

    /// Keycaps are taller than the snippet's 15 pt line, so a hint that carries them sets its lines at the
    /// cap height plus 2 pt above and below.
    private var hintLineHeight: CGFloat {
        let hasKeys = hint.contains { if case .keys = $0 { return true } else { return false } }
        let base = QuireFont.Role.snippet.lineHeight
        return hasKeys ? max(base, QuireKeycap.Style.standard.height + 2 * Quire.Space.s1) : base
    }

    private func hintString() -> NSAttributedString? {
        guard !hint.isEmpty else { return nil }
        let font = QuireFont.font(.snippet)
        let lineHeight = hintLineHeight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.qInk3,
            .paragraphStyle: paragraph(lineHeight: lineHeight),
            .baselineOffset: QuireFont.baselineOffset(for: font, lineHeight: lineHeight),
        ]
        let result = NSMutableAttributedString()
        for (index, part) in hint.enumerated() {
            if index > 0 { result.append(NSAttributedString(string: " ", attributes: attributes)) }
            switch part {
            case .text(let words):
                result.append(NSAttributedString(string: words, attributes: attributes))
            case .keys(let keys):
                for key in keys {
                    let attachment = NSTextAttachment()
                    // Caps sit 4 pt apart, as on the cheat sheet: 2 pt of margin on each side.
                    attachment.attachmentCell = QuireKeycapAttachmentCell(legend: key, margin: Quire.Space.s1, font: font)
                    let cap = NSMutableAttributedString(attachment: attachment)
                    cap.addAttributes(attributes, range: NSRange(location: 0, length: cap.length))
                    result.append(cap)
                }
            }
        }
        return result
    }

    // MARK: Layout

    private func height(of string: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(string.boundingRect(with: NSSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height)
    }

    private func singleLineWidth(of string: NSAttributedString) -> CGFloat {
        ceil(string.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                 options: [.usesLineFragmentOrigin]).width)
    }

    private var glyphMetrics: (name: String, size: CGFloat, gap: CGFloat)? {
        guard let glyph else { return nil }
        let e = Quire.Layout.EmptyState.self
        switch glyph {
        case .sparrow: return (Quire.Icon.brand, e.glyph, e.glyphGap)
        case .offline: return (Quire.Icon.offline, e.offlineGlyph, e.offlineGlyphGap)
        }
    }

    private var blockWidth: CGFloat {
        var width = singleLineWidth(of: sentenceString())
        if let hint = hintString() { width = max(width, singleLineWidth(of: hint)) }
        return min(QuireEmptyStateView.maxWidth, width)
    }

    private func blockHeight(width: CGFloat) -> CGFloat {
        var height = height(of: sentenceString(), width: width)
        if let g = glyphMetrics { height += g.size + g.gap }
        if let hint = hintString() { height += Quire.Layout.EmptyState.lineGap + self.height(of: hint, width: width) }
        return height
    }

    public override var intrinsicContentSize: NSSize {
        let width = blockWidth
        return NSSize(width: width, height: blockHeight(width: width))
    }

    public override func draw(_ dirtyRect: NSRect) {
        let width = min(blockWidth, bounds.width)
        let x = (bounds.midX - width / 2).rounded()
        var y = (bounds.midY - blockHeight(width: width) / 2).rounded()
        if let g = glyphMetrics {
            let rect = NSRect(x: bounds.midX - g.size / 2, y: y, width: g.size, height: g.size)
            QuireDraw.symbol(g.name, size: .custom(g.size), color: .qInk3, centredIn: rect)
            y += g.size + g.gap
        }
        let sentence = sentenceString()
        let sentenceHeight = height(of: sentence, width: width)
        sentence.draw(with: NSRect(x: x, y: y, width: width, height: sentenceHeight), options: [.usesLineFragmentOrigin], context: nil)
        y += sentenceHeight
        if let hint = hintString() {
            y += Quire.Layout.EmptyState.lineGap
            let hintHeight = height(of: hint, width: width)
            hint.draw(with: NSRect(x: x, y: y, width: width, height: hintHeight), options: [.usesLineFragmentOrigin], context: nil)
        }
    }

    private func contentDidChange() {
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    @objc private func environmentDidChange(_ note: Notification) {
        needsDisplay = true
    }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .staticText }

    public override func accessibilityLabel() -> String? {
        if let explicit = super.accessibilityLabel() { return explicit }
        let words = hint.map { part -> String in
            switch part {
            case .text(let text): return text
            case .keys(let keys): return keys.joined(separator: " ")
            }
        }
        return ([sentence] + (words.isEmpty ? [] : [words.joined(separator: " ")])).joined(separator: " ")
    }
}
