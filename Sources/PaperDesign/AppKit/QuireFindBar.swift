import AppKit

/// The find bar of Find in conversation (spec §5.50): a `raised` panel, 320 × 40, radius 8, `e2`, with a hairline
/// `rule` edge (`ruleStrong` in Increase Contrast), padding 6. In it, the field (28 pt, radius 6, `sheet` with a 1 pt
/// `ruleStrong` edge, `magnifyingglass` 12 pt `ink3` at x = 8, the query from x = 26, and the count, “3 of 12” or “No
/// matches”, in `meta` `ink3` 5 pt in from its trailing edge; the query truncates before the count does), then 6 pt,
/// Previous Match (`chevron.up`), Next Match (`chevron.down`) and Close (`xmark`), 24 pt icon buttons 2 pt apart.
///
/// ↩ in the field asks for the next match, ⇧↩ the previous one, and Esc closes; the owner decides what each does.
/// Previous and Next are disabled while nothing matches. The count is announced to VoiceOver as it changes while the
/// field has the keyboard.
@MainActor
public final class QuireFindBar: NSView, QuirePointerTarget {
    public var textField: NSTextField { field.textField }
    public let previousButton = QuireIconButton(symbolName: Quire.Icon.findPrevious, size: .medium, accessibilityLabel: "Previous Match")
    public let nextButton = QuireIconButton(symbolName: Quire.Icon.findNext, size: .medium, accessibilityLabel: "Next Match")
    public let closeButton = QuireIconButton(symbolName: Quire.Icon.dismiss, size: .medium, accessibilityLabel: "Close")

    public static let placeholder = "Find in conversation"

    public var query: String {
        get { field.textField.stringValue }
        set { field.textField.stringValue = newValue; field.contentDidChange() }
    }

    /// “3 of 12”, “No matches”, or nil while there is nothing to find.
    public var countText: String? {
        didSet {
            guard oldValue != countText else { return }
            field.contentDidChange()
            if field.hasKeyboardFocus, let spoken = announcement ?? countText {
                QuireAccessibility.announce(spoken, from: field.textField, priority: .medium)
            }
        }
    }

    /// What VoiceOver hears for the count: “Match 3 of 12”. Defaults to the count itself.
    public var announcement: String?

    /// Previous and Next are enabled only while something matches.
    public var hasMatches = false {
        didSet {
            previousButton.isEnabled = hasMatches
            nextButton.isEnabled = hasMatches
        }
    }

    public var onQueryChange: (@MainActor (String) -> Void)?
    public var onNext: (@MainActor () -> Void)?
    public var onPrevious: (@MainActor () -> Void)?
    public var onClose: (@MainActor () -> Void)?

    public static var size: NSSize { NSSize(width: Quire.Layout.FindBar.width, height: Quire.Layout.FindBar.height) }

    private let surface = QuireSurfaceView(frame: .zero)
    private let field = FindField()

    public init() {
        super.init(frame: NSRect(origin: .zero, size: QuireFindBar.size))
        wantsLayer = true
        clipsToBounds = false
        let f = Quire.Layout.FindBar.self
        surface.fillColor = .qRaised
        surface.cornerRadius = f.radius
        surface.elevation = Quire.Elevation.e2
        surface.edge = { mode in
            mode.isIncreasedContrast ? .solid(.qRuleStrong, width: Quire.Border.IcOutline.width) : .hairline(.qRule)
        }
        addSubview(surface)
        addSubview(field)
        field.owner = self
        for (button, tip) in [(previousButton, "Previous Match  ⇧⌘G"), (nextButton, "Next Match  ⌘G"), (closeButton, "Close  esc")] {
            button.toolTip = tip
            button.target = self
            addSubview(button)
        }
        previousButton.action = #selector(previousClicked(_:))
        nextButton.action = #selector(nextClicked(_:))
        closeButton.action = #selector(closeClicked(_:))
        previousButton.isEnabled = false
        nextButton.isEnabled = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(QuireFindBar.placeholder)
        needsLayout = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireFindBar is built in code") }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { QuireFindBar.size }

    /// Gives the field the keyboard, the query selected so typing replaces it.
    public func focus() {
        window?.makeFirstResponder(field.textField)
        field.textField.currentEditor()?.selectAll(nil)
    }

    /// True while the field has the keyboard.
    public var isEditing: Bool { field.hasKeyboardFocus }

    // MARK: Motion

    /// Fades in over `dur.quick` (a fade under Reduce Motion too).
    public func show() {
        isHidden = false
        guard let layer else { return }
        layer.opacity = 0
        Quire.Motion.animate(layer, keyPath: "opacity", to: Float(1), duration: Quire.Motion.quick, curve: .settle, reduced: .keep)
    }

    /// Fades out over `dur.quick`, then hides.
    public func hide(completion: (@MainActor () -> Void)? = nil) {
        guard let layer, !isHidden else { completion?(); return }
        Quire.Motion.animate(layer, keyPath: "opacity", to: Float(0), duration: Quire.Motion.quick, curve: .leave, reduced: .keep) { [weak self] in
            self?.isHidden = true
            self?.layer?.opacity = 1
            completion?()
        }
    }

    // MARK: Layout

    /// The field's visual rect and each button's, in the bar's coordinates.
    var fieldRect: NSRect {
        let f = Quire.Layout.FindBar.self
        let side = QuireIconButton.Size.medium.side
        let width = bounds.width - 2 * f.pad - f.fieldGap - 3 * side - 2 * f.buttonGap
        let height = Quire.Layout.TextField.height
        return NSRect(x: f.pad, y: ((bounds.height - height) / 2).rounded(), width: max(0, width), height: height)
    }

    func buttonRect(_ position: Int) -> NSRect {
        let f = Quire.Layout.FindBar.self
        let side = QuireIconButton.Size.medium.side
        let x = fieldRect.maxX + f.fieldGap + CGFloat(position) * (side + f.buttonGap)
        return NSRect(x: x, y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
    }

    public override func layout() {
        super.layout()
        surface.frame = bounds
        field.frame = field.frame(forVisualRect: fieldRect)
        for (position, button) in [previousButton, nextButton, closeButton].enumerated() {
            button.frame = button.frame(forVisualRect: buttonRect(position))
        }
        pointerRegionsDidChange()
    }

    // MARK: Pointer

    /// The arrow over the panel around the field and buttons (§4.17): the bar lies on the reader's page, whose own
    /// cursor (a link's hand, the body's I-beam) would otherwise show through it.
    public var pointerRegions: [QuirePointerRegion] {
        QuirePointerRegion.regions(bounds, cursor: .arrow, cutting: childPointerAreas())
    }

    public override func resetCursorRects() {
        addPointerRects()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        pointerRegionsDidChange()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        pointerRegionsDidChange()
    }

    // MARK: Actions

    @objc private func previousClicked(_ sender: Any?) { onPrevious?() }
    @objc private func nextClicked(_ sender: Any?) { onNext?() }
    @objc private func closeClicked(_ sender: Any?) { onClose?() }

    fileprivate func fieldDidChange() { onQueryChange?(query) }

    fileprivate func fieldCommand(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // ⇧↩ arrives as the same command; the key-down behind it says which. A command with no key behind it
            // (VoiceOver, a stale event left from an earlier key) is plain ↩.
            let event = NSApp.currentEvent
            let shifted = event?.type == .keyDown && event?.modifierFlags.contains(.shift) == true
            if shifted { onPrevious?() } else { onNext?() }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose?()
            return true
        default:
            return false
        }
    }

    /// The resolved panel, for tests.
    var surfaceView: QuireSurfaceView { surface }
    var countShown: String? { field.countShown }
}

/// The bar's field: the search field's face and magnifier (§5.6), with the count where the search field shows results.
@MainActor
private final class FindField: QuireControl, NSTextFieldDelegate {
    let textField: NSTextField = QuireInnerTextField(frame: .zero)
    weak var owner: QuireFindBar?

    private var inner: QuireInnerTextField { textField as! QuireInnerTextField }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        refusesFirstResponder = true
        textField.delegate = self
        textField.font = QuireFont.font(.body)
        textField.textColor = .qInk
        textField.lineBreakMode = .byTruncatingTail
        textField.placeholderAttributedString = NSAttributedString(string: QuireFindBar.placeholder, attributes: [
            .font: QuireFont.font(.body), .foregroundColor: NSColor.qInk3,
        ])
        textField.setAccessibilityLabel(QuireFindBar.placeholder)
        textField.cell?.setAccessibilityLabel(QuireFindBar.placeholder)
        inner.onFocusChange = { [weak self] _ in self?.contentDidChange() }
        addSubview(textField)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Quire.Layout.TextField.height)
    }

    override var hasKeyboardFocus: Bool { inner.isEditing }

    var countShown: String? {
        guard let text = owner?.countText, !(owner?.query.isEmpty ?? true) else { return nil }
        return text
    }

    func contentDidChange() {
        needsLayout = true
        stateDidChange()
    }

    private var countString: NSAttributedString? {
        countShown.map { QuireDraw.line($0, .meta, .qInk3) }
    }

    override func layout() {
        super.layout()
        let s = Quire.Layout.Search.self
        let face = faceRect
        var end = face.maxX - s.trailingInset
        if let count = countString { end -= QuireDraw.width(count) + s.resultsGap }
        let height = textField.intrinsicContentSize.height
        let x = face.minX + s.textX - QuireInnerTextField.cellInset
        textField.frame = NSRect(x: x, y: (face.midY - height / 2).rounded(), width: max(0, end - x + QuireInnerTextField.cellInset),
                                 height: height)
    }

    override func draw(_ dirtyRect: NSRect) {
        let s = Quire.Layout.Search.self
        let face = faceRect
        QuireDraw.fill(face, radius: s.radius, .qSheet)
        if interactionState != .rest { QuireDraw.fill(face, radius: s.radius, .qHover) }
        QuireDraw.strokeInside(face, radius: s.radius, width: Quire.Border.Strong.width, .qRuleStrong)
        let glyph = NSRect(x: face.minX + s.glyphX, y: face.midY - s.glyph / 2, width: s.glyph, height: s.glyph)
        QuireDraw.symbol(Quire.Icon.search, size: .custom(s.glyph), color: .qInk3, centredIn: glyph)
        if let count = countString {
            let width = QuireDraw.width(count)
            let lineHeight = QuireFont.Role.meta.lineHeight
            QuireDraw.draw(count, x: face.maxX - s.trailingInset - width, top: (face.midY - lineHeight / 2).rounded(),
                           maxWidth: width + 1, lineHeight: lineHeight)
        }
        if showsFocusRing {
            QuireFocusRing.draw(around: face, cornerRadius: s.radius, gap: QuireFocusRing.gap)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(textField)
    }

    /// The I-beam over the whole face, as the search field's (§4.17).
    override var pointerCursor: NSCursor? { .iBeam }

    func controlTextDidChange(_ obj: Notification) {
        contentDidChange()
        owner?.fieldDidChange()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        owner?.fieldCommand(commandSelector) ?? false
    }

    override func isAccessibilityElement() -> Bool { false }
}
