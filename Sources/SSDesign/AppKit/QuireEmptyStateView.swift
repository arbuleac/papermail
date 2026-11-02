import AppKit

/// An empty state (spec §5.9): one serif sentence and one hint, centred, at most 300 pt wide. The sentence is
/// `aside` (New York Italic 17/24, or its sans twin when New York cannot set it) in `ink`; the hint is
/// `snippet` in `ink3`, 4 pt below, and may carry keycaps inline (“J K to move · ↩ to open”). A hint with
/// keycaps is a row of commands, so it may use the whole pane rather than the sentence's 300 pt, and it wraps
/// only between commands: a keycap never ends a line apart from the words it goes with. Inbox zero adds the
/// sparrow, offline the `wifi.slash` glyph, 8 pt above the sentence.
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
        let base = QuireFont.Role.snippet.lineHeight
        return hintHasKeys ? max(base, QuireKeycap.Style.standard.height + 2 * Quire.Space.s1) : base
    }

    private var hintHasKeys: Bool {
        hint.contains { if case .keys = $0 { return true } else { return false } }
    }

    private static let noBreakSpace = "\u{00A0}"
    private static let wordJoiner = "\u{2060}"


    func hintString() -> NSAttributedString? {
        guard !hint.isEmpty else { return nil }
        let font = QuireFont.font(.snippet)
        let lineHeight = hintLineHeight
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.qInk3,
            .paragraphStyle: paragraph(lineHeight: lineHeight),
            .baselineOffset: QuireFont.baselineOffset(for: font, lineHeight: lineHeight),
        ]
        // Commands stay whole: inside a keycap and the words after it every space is a no-break space and the
        // caps are joined, so a line can break only before the next keycap.
        let grouped = hintHasKeys
        let result = NSMutableAttributedString()
        for (index, part) in hint.enumerated() {
            if index > 0 {
                let startsCommand: Bool
                if case .keys = part { startsCommand = true } else { startsCommand = false }
                let space = grouped && !startsCommand ? Self.noBreakSpace : " "
                result.append(NSAttributedString(string: space, attributes: attributes))
            }
            switch part {
            case .text(let words):
                let text = grouped ? words.replacingOccurrences(of: " ", with: Self.noBreakSpace) : words
                result.append(NSAttributedString(string: text, attributes: attributes))
            case .keys(let keys):
                for (keyIndex, key) in keys.enumerated() {
                    if grouped, keyIndex > 0 { result.append(NSAttributedString(string: Self.wordJoiner, attributes: attributes)) }
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

    /// The sentence's width, and a words-only hint's: the longer line, at most 300.
    private var blockWidth: CGFloat {
        var width = singleLineWidth(of: sentenceString())
        if !hintHasKeys, let hint = hintString() { width = max(width, singleLineWidth(of: hint)) }
        return min(QuireEmptyStateView.maxWidth, width)
    }

    /// A keycap hint's width: one line when `available` allows, else `available`, wrapping between commands.
    private func hintWidth(_ hint: NSAttributedString, block: CGFloat, available: CGFloat) -> CGFloat {
        guard hintHasKeys else { return block }
        return min(singleLineWidth(of: hint), available)
    }

    /// The hint's box in a pane `available` points wide (tests measure where it wraps).
    func hintSize(available: CGFloat) -> NSSize {
        guard let hint = hintString() else { return .zero }
        let width = hintWidth(hint, block: min(blockWidth, available), available: available)
        return NSSize(width: width, height: height(of: hint, width: width))
    }

    private func blockHeight(width: CGFloat, available: CGFloat) -> CGFloat {
        var height = height(of: sentenceString(), width: width)
        if let g = glyphMetrics { height += g.size + g.gap }
        if let hint = hintString() {
            height += Quire.Layout.EmptyState.lineGap + self.height(of: hint, width: hintWidth(hint, block: width, available: available))
        }
        return height
    }

    /// 300 pt at most, even for a keycap hint that may draw wider: the pane decides how wide the view is, and a
    /// wide intrinsic size would hold the reader open.
    public override var intrinsicContentSize: NSSize {
        let width = blockWidth
        return NSSize(width: width, height: blockHeight(width: width, available: QuireEmptyStateView.maxWidth))
    }

    public override func draw(_ dirtyRect: NSRect) {
        let width = min(blockWidth, bounds.width)
        let x = (bounds.midX - width / 2).rounded()
        var y = (bounds.midY - blockHeight(width: width, available: bounds.width) / 2).rounded()
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
            let hintWidth = hintWidth(hint, block: width, available: bounds.width)
            let hintHeight = height(of: hint, width: hintWidth)
            let hintX = (bounds.midX - hintWidth / 2).rounded()
            hint.draw(with: NSRect(x: hintX, y: y, width: hintWidth, height: hintHeight), options: [.usesLineFragmentOrigin], context: nil)
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
