import AppKit
import SSCore
import SSDesign

/// The quoted original beneath the editor (spec §5.15, §5.20): folded, a glyph-only 22 pt elision chip
/// (`ss.elide`) followed by the attribution, “On 1 Nov 2026 at 23:39, Ben Carter wrote:”, in `snippet` `ink3`;
/// clicking either unfolds it. Unfolded, the chip turns `accentWash` and the original shows in the shared quote style: a 2 pt `rule`
/// bar, a 12 pt indent, `writing` in `ink2`. The height animates over `dur.standard` (instant under Reduce
/// Motion).
///
/// It is never editable: the exporter appends the real HTML after the typed content on send, so what shows
/// here is only a preview.
@MainActor
final class QuotedOriginalView: NSView {
    var rendering: QuotedReply.Rendering? {
        didSet { update() }
    }

    /// Called after the height changed, so the document can follow.
    var onHeightChange: (() -> Void)?

    /// Long threads make a long preview; past this the layout gets sluggish for no benefit.
    private static let previewLimit = 20_000
    private static let topGap: CGFloat = 16
    private static let quoteGap: CGFloat = 12
    private static let bottomPad: CGFloat = 20

    let chip = ElisionChip()
    private let attribution = AttributionLabel()
    /// The unfolded preview's own TextKit stack: laid out once per width, and only the lines in the dirty rect
    /// are drawn, so scrolling or resizing past a long quote does not set the whole thread again.
    private let quoteStorage = NSTextStorage()
    private let quoteLayout = NSLayoutManager()
    private let quoteContainer = NSTextContainer(size: .zero)
    private(set) var isExpanded = false
    private var measuredHeight: CGFloat = 0
    private var measuredWidth: CGFloat = 0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        wantsLayer = true
        layer?.masksToBounds = true
        QuireFont.configure(quoteLayout)
        // Folded, nothing is laid out: idle-time layout would set the whole quote for nobody.
        quoteLayout.backgroundLayoutEnabled = false
        quoteContainer.lineFragmentPadding = 0
        quoteLayout.addTextContainer(quoteContainer)
        quoteStorage.addLayoutManager(quoteLayout)
        chip.target = self
        chip.action = #selector(toggleExpanded(_:))
        attribution.onClick = { [weak self] in self?.toggleExpanded(nil) }
        addSubview(chip)
        addSubview(attribution)
        update()
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    /// The preview is the composer's body text: a Text size sets it again and measures it again (spec §4.15).
    @objc private func environmentDidChange(_ note: Notification) {
        guard quoteStorage.length > 0 else { return }
        ComposeTextView.setTextSize(ComposeTextView.composerTextSize, of: quoteStorage)
        measuredWidth = 0
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("QuotedOriginalView is built in code")
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: rendering == nil ? 0 : height(forWidth: bounds.width))
    }

    private var foldedHeight: CGFloat { Self.topGap + Quire.Layout.QuotedToggle.composerChip + Self.bottomPad }

    private var textWidth: CGFloat {
        max(40, bounds.width - Quire.Layout.Composer.valueX - Quire.Layout.TextStyle.quoteIndent - Quire.Layout.Composer.bodyPadRight)
    }

    private func height(forWidth width: CGFloat) -> CGFloat {
        guard isExpanded else { return foldedHeight }
        if abs(width - measuredWidth) > 0.5 {
            measuredWidth = width
            measuredHeight = layOutQuote()
        }
        return Self.topGap + Quire.Layout.QuotedToggle.composerChip + Self.quoteGap + measuredHeight + Self.bottomPad
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - frame.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged, isExpanded { invalidateIntrinsicContentSize() }
    }

    override func layout() {
        super.layout()
        let q = Quire.Layout.QuotedToggle.self
        let chipRect = NSRect(x: Quire.Layout.Composer.valueX, y: Self.topGap, width: q.composerChip, height: q.composerChip)
        chip.frame = chip.frame(forVisualRect: chipRect)
        let role = QuireFont.Role.snippet
        let gap: CGFloat = 8
        let width = max(0, min(attribution.intrinsicContentSize.width, bounds.width - chipRect.maxX - gap - Quire.Layout.Composer.bodyPadRight))
        attribution.frame = NSRect(x: chipRect.maxX + gap, y: (chipRect.midY - role.lineHeight / 2).rounded(), width: width,
                                   height: role.lineHeight)
    }

    /// Lays the preview out at the current text width and returns its height.
    private func layOutQuote() -> CGFloat {
        let size = NSSize(width: textWidth, height: .greatestFiniteMagnitude)
        if quoteContainer.size != size { quoteContainer.size = size }
        quoteLayout.ensureLayout(for: quoteContainer)
        return ceil(quoteLayout.usedRect(for: quoteContainer).height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isExpanded else { return }
        let c = Quire.Layout.Composer.self
        let top = Self.topGap + Quire.Layout.QuotedToggle.composerChip + Self.quoteGap
        let barHeight = max(0, min(measuredHeight, bounds.height - top - Self.bottomPad))
        NSColor.qRule.setFill()
        NSRect(x: c.valueX, y: top, width: Quire.Layout.TextStyle.quoteBar, height: barHeight).fill()
        if quoteContainer.size.width != textWidth { _ = layOutQuote() }
        let origin = NSPoint(x: c.valueX + Quire.Layout.TextStyle.quoteIndent, y: top)
        let visible = dirtyRect.offsetBy(dx: -origin.x, dy: -origin.y)
        let glyphs = quoteLayout.glyphRange(forBoundingRect: visible, in: quoteContainer)
        quoteLayout.drawBackground(forGlyphRange: glyphs, at: origin)
        quoteLayout.drawGlyphs(forGlyphRange: glyphs, at: origin)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: Folding

    @objc private func toggleExpanded(_ sender: Any?) {
        setExpanded(!isExpanded, animated: true)
    }

    func setExpanded(_ expanded: Bool, animated: Bool) {
        guard expanded != isExpanded, rendering != nil else { return }
        isExpanded = expanded
        measuredWidth = 0
        chip.isOn = expanded
        invalidateIntrinsicContentSize()
        needsDisplay = true
        guard animated, let container = superview else {
            onHeightChange?()
            return
        }
        Quire.Motion.run(Quire.Motion.standard, .settle, reduced: .instant, participants: [self, container]) { _ in
            container.layoutSubtreeIfNeeded()
        } completion: { [weak self] in
            self?.onHeightChange?()
        }
    }

    private func update() {
        guard let rendering else {
            isHidden = true
            invalidateIntrinsicContentSize()
            return
        }
        isHidden = false
        attribution.text = rendering.foldedAttribution()
        var text = rendering.originalText.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > Self.previewLimit {
            text = String(text.prefix(Self.previewLimit)) + "…"
        }
        let header = rendering.header.trimmingCharacters(in: .whitespacesAndNewlines)
        quoteStorage.setAttributedString(Self.quoteString(header.isEmpty ? text : header + "\n" + text))
        measuredWidth = 0
        chip.isOn = isExpanded
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    /// `writing` in `ink2` on the composer's 21 pt lines, wrapping.
    private static func quoteString(_ text: String) -> NSAttributedString {
        var attributes = ComposeTextView.defaultTypingAttributes
        attributes[.foregroundColor] = NSColor.qInk2
        return NSAttributedString(string: text, attributes: attributes)
    }
}

/// The elision chip (§5.15): `fill` with `ss.elide` 14 pt in `ink2` while folded (hover and pressed wash it, the
/// glyph turns `ink`); unfolded, `accentWash` with the glyph in `accent`. The ring sits outside a 1 pt gap.
@MainActor
final class ElisionChip: QuireControl {
    var isOn = false {
        didSet {
            guard oldValue != isOn else { return }
            toolTip = title
            stateDidChange()
            NSAccessibility.post(element: self, notification: .titleChanged)
        }
    }

    private var title: String { isOn ? "Hide quoted text" : "Show quoted text" }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ElisionChip is built in code")
    }

    override var intrinsicContentSize: NSSize {
        let side = Quire.Layout.QuotedToggle.composerChip
        return NSSize(width: side, height: side)
    }

    override func draw(_ dirtyRect: NSRect) {
        let q = Quire.Layout.QuotedToggle.self
        let face = faceRect
        let state = interactionState
        let glyph: NSColor
        if isOn {
            let fill: NSColor = state == .pressed ? .qAccentWashPressed : state == .hover ? .qAccentWashHover : .qAccentWash
            QuireDraw.fill(face, radius: q.radius, fill)
            glyph = .qAccent
        } else {
            QuireDraw.fill(face, radius: q.radius, .qFill)
            if state == .pressed { QuireDraw.fill(face, radius: q.radius, .qPressed) }
            if state == .hover { QuireDraw.fill(face, radius: q.radius, .qHover) }
            glyph = state == .rest ? .qInk2 : .qInk
        }
        QuireSymbol.draw(Quire.Icon.quotedText, size: .custom(q.glyph), color: glyph, centredIn: face)
        if showsFocusRing {
            QuireFocusRing.draw(around: face, cornerRadius: q.radius, gap: QuireFocusRing.gap)
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { title }
}

/// “On 1 Nov 2026 at 23:39, Ben Carter wrote:”: clicking it unfolds the quote, like the chip.
@MainActor
private final class AttributionLabel: NSView {
    var text = "" {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }
    var onClick: (() -> Void)?

    override var isFlipped: Bool { true }

    private var string: NSAttributedString { QuireFont.attributedString(text, role: .snippet, color: .qInk3) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(string.size().width) + 1, height: QuireFont.Role.snippet.lineHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        string.draw(with: bounds, options: QuireFont.drawingOptions, context: nil)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .staticText }
    override func accessibilityLabel() -> String? { text }
}
