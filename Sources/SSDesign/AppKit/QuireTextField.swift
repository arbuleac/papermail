import AppKit

/// A Quire text field (spec §5.25): 28 pt (24 in Settings rows), radius 6, `sheet` with a 1 pt `ruleStrong`
/// inset edge, padding 0 8, `body` (or `mono` for OAuth client IDs), placeholder `ink3`, caret `accent`.
///
/// States: hover turns the edge `ink3`; focus keeps the edge and adds the ring outside a 1 pt gap (never a
/// 1 pt colour change alone); error draws a 1.5 pt `danger` edge and a help line 5 pt below in `meta` `danger`
/// with the triangle; disabled is `fill` with no edge and `inkDisabled` text.
///
/// The editable `NSTextField` is `textField`: set its delegate, target and action as usual. The container is
/// not an accessibility element; the text field is.
@MainActor
public final class QuireTextField: QuireControl {
    /// The editable field. Its frame belongs to the container.
    public let textField: NSTextField

    public var size: Size = .regular {
        didSet { if oldValue != size { contentDidChange() } }
    }

    /// Sets the field in `mono` (SF Mono 12/16) instead of `body`.
    public var isMonospaced = false {
        didSet { if oldValue != isMonospaced { applyText() } }
    }

    public var placeholder: String? {
        didSet { applyText() }
    }

    /// The error help line (“That doesn't look like a Google client ID.”); non-nil draws the error state.
    public var errorMessage: String? {
        didSet { if oldValue != errorMessage { contentDidChange() } }
    }

    /// The field's text.
    public override var stringValue: String {
        get { textField.stringValue }
        set { textField.stringValue = newValue }
    }

    private var inner: QuireInnerTextField { textField as! QuireInnerTextField }

    public init(placeholder: String? = nil, size: Size = .regular) {
        textField = QuireInnerTextField(frame: .zero)
        self.placeholder = placeholder
        self.size = size
        super.init(frame: .zero)
        // The text field inside takes keyboard focus; the container never sits in the key-view loop itself.
        refusesFirstResponder = true
        addSubview(textField)
        inner.onFocusChange = { [weak self] _ in self?.stateDidChange() }
        applyText()
        setFrameSize(frame(forAlignmentRect: NSRect(origin: .zero, size: NSSize(width: 220, height: intrinsicContentSize.height))).size)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireTextField is built in code") }

    // MARK: Geometry

    private var role: QuireFont.Role { isMonospaced ? .mono : .body }

    /// The help line wraps under the field rather than truncating: its words are the remedy.
    private func helpString() -> NSAttributedString? {
        guard let errorMessage else { return nil }
        var attributes = QuireFont.attributes(.meta, color: .qDanger)
        let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        attributes[.paragraphStyle] = style
        return NSAttributedString(string: errorMessage, attributes: attributes)
    }

    private func helpTextWidth(fieldWidth: CGFloat) -> CGFloat {
        max(1, fieldWidth - Quire.Layout.TextField.helpGlyph - Quire.Layout.TextField.helpGlyphGap)
    }

    private func helpTextHeight(fieldWidth: CGFloat) -> CGFloat {
        guard let help = helpString() else { return 0 }
        let height = help.boundingRect(with: NSSize(width: helpTextWidth(fieldWidth: fieldWidth), height: .greatestFiniteMagnitude),
                                       options: [.usesLineFragmentOrigin]).height
        return max(QuireFont.Role.meta.lineHeight, ceil(height))
    }

    private func helpHeight(fieldWidth: CGFloat) -> CGFloat {
        errorMessage == nil ? 0 : Quire.Layout.TextField.helpGap + helpTextHeight(fieldWidth: fieldWidth)
    }

    public override var intrinsicContentSize: NSSize {
        let width = bodyRect.width > 0 ? bodyRect.width : 220
        return NSSize(width: NSView.noIntrinsicMetric, height: size.height + helpHeight(fieldWidth: width))
    }

    public override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged, errorMessage != nil { invalidateIntrinsicContentSize() }
    }

    public override var faceRect: NSRect {
        let body = bodyRect
        return NSRect(x: body.minX, y: body.minY, width: body.width, height: size.height)
    }

    public override func layout() {
        super.layout()
        let face = faceRect
        let padX = Quire.Layout.TextField.padX - QuireInnerTextField.cellInset
        let height = textField.intrinsicContentSize.height
        textField.frame = NSRect(x: face.minX + padX, y: (face.midY - height / 2).rounded(),
                                 width: max(0, face.width - 2 * padX), height: height)
    }

    // MARK: State

    public override var hasKeyboardFocus: Bool { inner.isEditing }

    public override var isEnabled: Bool {
        didSet { textField.isEnabled = isEnabled; applyText() }
    }

    private func applyText() {
        textField.font = QuireFont.font(role)
        textField.textColor = isEnabled ? .qInk : .qInkDisabled
        if let placeholder {
            textField.placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: QuireFont.font(role),
                .foregroundColor: isEnabled ? NSColor.qInk3 : NSColor.qInkDisabled,
            ])
        } else {
            textField.placeholderAttributedString = nil
        }
        needsLayout = true
        needsDisplay = true
    }

    private func contentDidChange() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        stateDidChange()
    }

    public override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(textField)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let face = faceRect
        let radius = Quire.Layout.TextField.radius
        guard isEnabled else {
            QuireDraw.fill(face, radius: radius, .qFill)
            return
        }
        QuireDraw.fill(face, radius: radius, .qSheet)
        if errorMessage != nil {
            QuireDraw.strokeInside(face, radius: radius, width: Quire.Border.Error.width, .qDanger)
        } else {
            let hovered = interactionState != .rest && !showsFocusRing
            QuireDraw.strokeInside(face, radius: radius, width: Quire.Border.Strong.width, hovered ? .qInk3 : .qRuleStrong)
        }
        if let help = helpString() {
            let t = Quire.Layout.TextField.self
            let lineHeight = QuireFont.Role.meta.lineHeight
            let top = face.maxY + t.helpGap
            // The glyph aligns to the help text's first line.
            let glyph = NSRect(x: face.minX, y: top + (lineHeight - t.helpGlyph) / 2, width: t.helpGlyph, height: t.helpGlyph)
            QuireDraw.symbol(Quire.Icon.error, size: .custom(t.helpGlyph), color: .qDanger, centredIn: glyph)
            let width = helpTextWidth(fieldWidth: face.width)
            help.draw(with: NSRect(x: glyph.maxX + t.helpGlyphGap, y: top, width: width, height: helpTextHeight(fieldWidth: face.width)),
                      options: [.usesLineFragmentOrigin], context: nil)
        }
        if showsFocusRing {
            QuireFocusRing.draw(around: face, cornerRadius: radius, gap: QuireFocusRing.gap)
        }
    }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { false }
}
