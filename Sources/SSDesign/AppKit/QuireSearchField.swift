import AppKit

/// The list's search field (spec §5.6): 168 × 26 at rest, radius 6, `sheet` with a resting 1 pt `ruleStrong`
/// edge, `magnifyingglass` 12 pt `ink3` at x = 8, text from x = 26, and on the trailing side, 5 pt in: the “/”
/// keycap (16 pt) while empty and not focused, or, while results show, the clear button with “38 results” in
/// `meta` `ink3` 6 pt before it (the query truncates before the count does).
///
/// States: hover `sheet + hover`; focused keeps the edge and adds the ring outside a 1 pt gap; searching swaps
/// the magnifier for a 12 pt spinner, only once the spinner's 150 ms delay has passed; disabled (no accounts)
/// is `fill` with no edge and `inkDisabled`. Esc clears the query, and in an empty field calls `onCancel` so the
/// owner returns focus to the list. The width animation on focus belongs to the list header.
@MainActor
public final class QuireSearchField: QuireControl, NSTextFieldDelegate {
    public let textField: NSTextField

    public var query: String {
        get { textField.stringValue }
        set { textField.stringValue = newValue; contentDidChange() }
    }

    /// “Search”, “Search Starred”, “Search Inbox” (§5.6).
    public var placeholder = "Search" {
        didSet { applyText() }
    }

    /// The result count while results show; nil hides the count and the clear button.
    public var resultCount: Int? {
        didSet { if oldValue != resultCount { contentDidChange() } }
    }

    /// The first page is being fetched: the spinner replaces the magnifier after its delay.
    public var isSearching = false {
        didSet { if oldValue != isSearching { searchingDidChange() } }
    }

    public var onQueryChange: (@MainActor (String) -> Void)?
    public var onSubmit: (@MainActor (String) -> Void)?
    /// Esc in an empty field: give focus back to the list.
    public var onCancel: (@MainActor () -> Void)?
    /// The query was cleared by Esc or the clear button.
    public var onClear: (@MainActor () -> Void)?

    private var inner: QuireInnerTextField { textField as! QuireInnerTextField }
    private let clearButton = QuireSearchClearButton(frame: .zero)
    private let spinner = QuireSpinnerView(size: .small, color: .qInk3)

    public init(placeholder: String = "Search") {
        textField = QuireInnerTextField(frame: .zero)
        self.placeholder = placeholder
        super.init(frame: .zero)
        // The text field inside takes keyboard focus; the container never sits in the key-view loop itself.
        refusesFirstResponder = true
        textField.delegate = self
        inner.onFocusChange = { [weak self] _ in self?.contentDidChange() }
        clearButton.target = self
        clearButton.action = #selector(clearClicked(_:))
        clearButton.refusesFirstResponder = true
        spinner.onReveal = { [weak self] in self?.needsDisplay = true }
        addSubview(textField)
        addSubview(clearButton)
        addSubview(spinner)
        applyText()
        contentDidChange()
        setFrameSize(frame(forAlignmentRect: NSRect(origin: .zero, size: intrinsicContentSize)).size)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireSearchField is built in code") }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: Quire.Layout.ListHeader.searchWidth, height: Quire.Layout.ListHeader.searchHeight)
    }

    // MARK: State

    public override var hasKeyboardFocus: Bool { inner.isEditing }

    public override var isEnabled: Bool {
        didSet { textField.isEnabled = isEnabled; applyText(); contentDidChange() }
    }

    /// The “/” keycap shows while the field is empty and not focused.
    public var showsKeycap: Bool { isEnabled && query.isEmpty && !hasKeyboardFocus && displayState != .focused }
    /// The clear button and the count show while results show.
    public var showsResults: Bool { isEnabled && resultCount != nil && !query.isEmpty }

    private var resultsString: NSAttributedString? {
        guard showsResults, let count = resultCount else { return nil }
        let text = count == 1 ? "1 result" : "\(QuireDraw.grouped(count)) results"
        return QuireDraw.line(text, .meta, .qInk3)
    }

    private func applyText() {
        let font = QuireFont.font(.body)
        textField.font = font
        textField.textColor = isEnabled ? .qInk : .qInkDisabled
        textField.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
            .font: font,
            .foregroundColor: isEnabled ? NSColor.qInk3 : NSColor.qInkDisabled,
        ])
        textField.setAccessibilityLabel(placeholder)
        textField.cell?.setAccessibilityLabel(placeholder)
        needsDisplay = true
    }

    private func contentDidChange() {
        clearButton.isHidden = !showsResults
        needsLayout = true
        stateDidChange()
    }

    private func searchingDidChange() {
        if isSearching { spinner.startAnimation() } else { spinner.stopAnimation() }
        needsDisplay = true
    }

    // MARK: Layout

    private var trailingStart: CGFloat {
        let s = Quire.Layout.Search.self
        let face = faceRect
        var x = face.maxX - s.trailingInset
        if showsKeycap {
            x -= QuireKeycap.size(for: "/", style: .inField).width
        } else if let results = resultsString {
            x -= s.clearVisual + s.resultsGap + QuireDraw.width(results)
        }
        return x
    }

    public override func layout() {
        super.layout()
        let s = Quire.Layout.Search.self
        let face = faceRect
        let clear = NSRect(x: face.maxX - s.trailingInset - s.clearVisual, y: (face.midY - s.clearVisual / 2).rounded(),
                           width: s.clearVisual, height: s.clearVisual)
        clearButton.frame = clearButton.frame(forVisualRect: clear)
        let height = textField.intrinsicContentSize.height
        let x = face.minX + s.textX - QuireInnerTextField.cellInset
        let end = trailingStart - s.resultsGap + QuireInnerTextField.cellInset
        textField.frame = NSRect(x: x, y: (face.midY - height / 2).rounded(), width: max(0, end - x), height: height)
        let d = QuireSpinnerView.Size.small.diameter
        spinner.frame = NSRect(x: face.minX + s.glyphX, y: (face.midY - d / 2).rounded(), width: d, height: d)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let s = Quire.Layout.Search.self
        let face = faceRect
        let radius = s.radius
        guard isEnabled else {
            QuireDraw.fill(face, radius: radius, .qFill)
            drawMagnifier(in: face, color: .qInkDisabled)
            return
        }
        QuireDraw.fill(face, radius: radius, .qSheet)
        if interactionState != .rest { QuireDraw.fill(face, radius: radius, .qHover) }
        QuireDraw.strokeInside(face, radius: radius, width: Quire.Border.Strong.width, .qRuleStrong)
        if !spinner.isRevealed { drawMagnifier(in: face, color: .qInk3) }
        if showsKeycap {
            let size = QuireKeycap.size(for: "/", style: .inField)
            let rect = NSRect(x: face.maxX - s.trailingInset - size.width, y: (face.midY - size.height / 2).rounded(),
                              width: size.width, height: size.height)
            QuireKeycap.draw("/", style: .inField, in: rect)
        } else if let results = resultsString {
            let width = QuireDraw.width(results)
            let lineHeight = QuireFont.Role.meta.lineHeight
            QuireDraw.draw(results, x: face.maxX - s.trailingInset - s.clearVisual - s.resultsGap - width,
                           top: (face.midY - lineHeight / 2).rounded(), maxWidth: width + 1, lineHeight: lineHeight)
        }
        if showsFocusRing {
            QuireFocusRing.draw(around: face, cornerRadius: radius, gap: QuireFocusRing.gap)
        }
    }

    private func drawMagnifier(in face: NSRect, color: NSColor) {
        let s = Quire.Layout.Search.self
        let rect = NSRect(x: face.minX + s.glyphX, y: face.midY - s.glyph / 2, width: s.glyph, height: s.glyph)
        QuireDraw.symbol(Quire.Icon.search, size: .custom(s.glyph), color: color, centredIn: rect)
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(textField)
    }

    // MARK: Editing

    @objc private func clearClicked(_ sender: Any?) {
        clear()
        window?.makeFirstResponder(textField)
    }

    private func clear() {
        textField.stringValue = ""
        contentDidChange()
        onQueryChange?("")
        onClear?()
    }

    public func controlTextDidChange(_ obj: Notification) {
        contentDidChange()
        onQueryChange?(query)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            if query.isEmpty {
                onCancel?()
            } else {
                clear()
            }
            return true
        case #selector(NSResponder.insertNewline(_:)):
            onSubmit?(query)
            return true
        default:
            return false
        }
    }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { false }
}
