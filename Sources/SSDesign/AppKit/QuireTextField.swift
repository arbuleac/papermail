import AppKit

/// A Quire text field (spec §5.25): 28 pt (24 in Settings rows), radius 6, `sheet` with a 1 pt `ruleStrong`
/// inset edge, padding 0 8, `body` (or `mono` for OAuth client IDs), placeholder `ink3`, caret `accent`.
///
/// States: hover turns the edge `ink3`; focus keeps the edge and adds the ring outside a 1 pt gap (never a
/// 1 pt colour change alone); error draws a 1.5 pt `danger` edge and a help line 5 pt below in `meta` `danger`
/// with the triangle; disabled is `fill` with no edge and `inkDisabled` text.
///
/// Secure (`isSecure`): bullets with 2 pt tracking, and a reveal button (`eye`) only while the pointer is over
/// the field; revealed, the text shows and the button (`eye.slash`) stays until it hides the text again.
///
/// The editable `NSTextField` is `textField`: set its delegate, target and action as usual (a secure field
/// swaps it for an `NSSecureTextField` and back, carrying text, delegate, target and action over). The
/// container is not an accessibility element; the text field is.
@MainActor
public final class QuireTextField: QuireControl {
    /// The editable field. Its frame belongs to the container. Secure fields replace it when the text is
    /// revealed or hidden, so read it when needed rather than keeping it.
    public private(set) var textField: NSTextField

    /// Shows bullets instead of the text (OAuth client secrets, §5.40).
    public var isSecure = false {
        didSet {
            guard oldValue != isSecure else { return }
            if !isSecure { isRevealed = false }
            secureDidChange()
        }
    }

    /// A secure field showing its text, after the reveal button was clicked.
    public var isRevealed = false {
        didSet {
            guard oldValue != isRevealed else { return }
            secureDidChange()
        }
    }

    /// The secure field's reveal button, while the field is secure.
    public private(set) var revealButton: QuireIconButton?

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
    /// VoiceOver reads it as the field's help and hears it once when it appears (§4.14).
    public var errorMessage: String? {
        didSet {
            guard oldValue != errorMessage else { return }
            textField.setAccessibilityHelp(errorMessage)
            if let errorMessage { QuireAccessibility.announce(errorMessage, from: textField) }
            contentDidChange()
        }
    }

    /// The field's text.
    public override var stringValue: String {
        get { textField.stringValue }
        set { textField.stringValue = newValue }
    }

    private var inner: any QuireInnerField { textField as! any QuireInnerField }

    public init(placeholder: String? = nil, size: Size = .regular, isSecure: Bool = false) {
        textField = isSecure ? QuireSecureInnerTextField(frame: .zero) : QuireInnerTextField(frame: .zero)
        self.placeholder = placeholder
        self.size = size
        self.isSecure = isSecure
        super.init(frame: .zero)
        // The text field inside takes keyboard focus; the container never sits in the key-view loop itself.
        refusesFirstResponder = true
        addSubview(textField)
        inner.onFocusChange = { [weak self] _ in self?.stateDidChange() }
        if isSecure { updateRevealButton() }
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

    /// The reveal button's visual rect: a small icon button centred in the field's height, as far from the
    /// trailing edge as from the top and bottom.
    private var revealRect: NSRect {
        let face = faceRect
        let side = QuireIconButton.Size.small.side
        let inset = max(1, ((face.height - side) / 2).rounded(.down))
        return NSRect(x: face.maxX - inset - side, y: (face.midY - side / 2).rounded(), width: side, height: side)
    }

    public override func layout() {
        super.layout()
        let face = faceRect
        let padX = Quire.Layout.TextField.padX - QuireInnerTextField.cellInset
        let height = textField.intrinsicContentSize.height
        // A secure field always keeps room for its reveal button (and a 4 pt gap before it), so the text never
        // shifts when the button appears.
        let trailing = isSecure ? face.maxX - revealRect.minX + Quire.Space.s2 - QuireInnerTextField.cellInset : padX
        textField.frame = NSRect(x: face.minX + padX, y: (face.midY - height / 2).rounded(),
                                 width: max(0, face.width - padX - trailing), height: height)
        if let revealButton { revealButton.frame = revealButton.frame(forVisualRect: revealRect) }
    }

    // MARK: Secure

    private func secureDidChange() {
        swapFieldIfNeeded()
        updateRevealButton()
        needsLayout = true
        stateDidChange()
    }

    /// Puts the secure or the plain field in place, carrying over what callers set on it.
    private func swapFieldIfNeeded() {
        let wantsSecure = isSecure && !isRevealed
        guard wantsSecure != (textField is NSSecureTextField) else { return }
        let old = textField
        let wasEditing = old.currentEditor() != nil
        let replacement: NSTextField = wantsSecure ? QuireSecureInnerTextField(frame: old.frame) : QuireInnerTextField(frame: old.frame)
        replacement.stringValue = old.stringValue
        replacement.delegate = old.delegate
        replacement.target = old.target
        replacement.action = old.action
        replacement.isEnabled = old.isEnabled
        replacement.setAccessibilityHelp(old.accessibilityHelp())
        replacement.setAccessibilityLabel(old.accessibilityLabel())
        if wasEditing { window?.makeFirstResponder(nil) }
        replaceSubview(old, with: replacement)
        textField = replacement
        inner.onFocusChange = { [weak self] _ in self?.stateDidChange() }
        applyText()
        if wasEditing, window?.makeFirstResponder(replacement) == true {
            replacement.currentEditor()?.selectedRange = NSRange(location: (replacement.stringValue as NSString).length, length: 0)
        }
    }

    /// The reveal button shows only while the pointer is over the field (or a forced hover), or while the text
    /// is revealed, so it can be hidden again.
    private func updateRevealButton() {
        guard isSecure else {
            revealButton?.removeFromSuperview()
            revealButton = nil
            return
        }
        let button = revealButton ?? {
            let button = QuireIconButton(symbolName: Quire.Icon.reveal, size: .small, target: self, action: #selector(toggleReveal(_:)))
            addSubview(button)
            revealButton = button
            return button
        }()
        button.symbolName = isRevealed ? Quire.Icon.conceal : Quire.Icon.reveal
        button.setAccessibilityLabel(isRevealed ? "Hide secret" : "Show secret")
        button.toolTip = isRevealed ? "Hide Secret" : "Show Secret"
        button.windowKeyOverride = windowKeyOverride
        let pointerOver = isHovered || displayState == .hover
        button.isHidden = !(isEnabled && (pointerOver || isRevealed))
        needsLayout = true
    }

    @objc private func toggleReveal(_ sender: Any?) {
        isRevealed.toggle()
    }

    public override func hoverDidChange() {
        super.hoverDidChange()
        if isSecure { updateRevealButton() }
    }

    public override func stateDidChange() {
        super.stateDidChange()
        if isSecure, revealButton != nil { updateRevealButton() }
    }

    // MARK: State

    public override var hasKeyboardFocus: Bool { inner.isEditing }

    public override var isEnabled: Bool {
        didSet { textField.isEnabled = isEnabled; applyText(); if isSecure { updateRevealButton() } }
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
