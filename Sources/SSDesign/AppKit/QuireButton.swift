import AppKit

/// A Quire text button (spec §5.24): primary, secondary, ghost, destructive or link, in three sizes, with an
/// optional leading symbol and an optional keycap beside it.
///
/// States follow the §5.24 table: hover and pressed fills per variant (link buttons never take a wash: they
/// gain the underline, and pressed turns the label `ink2`), the focus ring outside a 1 pt gap (2 pt around
/// the primary and destructive fills), disabled `fill` + `inkDisabled`, and loading, where a 12 pt spinner in
/// the label colour takes the glyph's place and the label becomes the gerund with the width kept. A primary
/// button in a window that is not key draws as a secondary one (§3.4). Under Graphite, link buttons draw their
/// underline at rest (§3.1).
///
/// A keycap is never drawn on a fill: it sits beside the face, `keycapGap` away, before or after it (“⌘↩”
/// beside Send, R · A · F after the reader's footer buttons), and is not part of the face or the ring.
@MainActor
public final class QuireButton: QuireControl {
    public var title: String {
        didSet { if oldValue != title { contentDidChange() } }
    }

    public var variant: Variant {
        didSet { if oldValue != variant { contentDidChange() } }
    }

    public var size: Size {
        didSet { if oldValue != size { contentDidChange() } }
    }

    /// A leading symbol (any `Quire.Icon` name: SF Symbol or `ss.` glyph), at the size's glyph size.
    public var symbolName: String? {
        didSet { if oldValue != symbolName { contentDidChange() } }
    }

    /// A keycap legend drawn beside the face (“⌘↩”, “R”). nil draws none.
    public var keycap: String? {
        didSet { if oldValue != keycap { contentDidChange() } }
    }

    /// Puts the keycap before the face instead of after it (the quick reply's “⌘↩ Send”, §5.18).
    public var keycapLeads = false {
        didSet { if oldValue != keycapLeads { contentDidChange() } }
    }

    /// The distance between the face and its keycap: 8 pt beside Send (`composer.barKeycapGap`), 6 pt after
    /// the reader's footer buttons (`reader.targetKeycapGap`).
    public var keycapGap: CGFloat = Quire.Layout.Composer.barKeycapGap {
        didSet { if oldValue != keycapGap { contentDidChange() } }
    }

    /// Work is running: the spinner replaces the glyph and the label reads `loadingTitle`.
    public var isLoading = false {
        didSet { if oldValue != isLoading { loadingDidChange() } }
    }

    /// The gerund shown while loading (“Sending…”). The button keeps the wider of its two widths so nothing
    /// moves when loading starts.
    public var loadingTitle: String? {
        didSet { if oldValue != loadingTitle { contentDidChange() } }
    }

    /// A key equivalent such as "\r"; with `keyEquivalentModifierMask` it activates the button from anywhere in
    /// the window, as `NSButton`'s does.
    public var keyEquivalent = ""
    public var keyEquivalentModifierMask: NSEvent.ModifierFlags = []

    /// Internal so a gallery can show a revealed spinner without waiting out its delay.
    var spinner: QuireSpinnerView?

    public init(title: String, variant: Variant = .secondary, size: Size = .regular, symbolName: String? = nil,
                target: AnyObject? = nil, action: Selector? = nil) {
        self.title = title
        self.variant = variant
        self.size = size
        self.symbolName = symbolName
        super.init(frame: .zero)
        self.target = target
        self.action = action
        setFrameSize(frame(forAlignmentRect: NSRect(origin: .zero, size: intrinsicContentSize)).size)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireButton is built in code") }

    /// Maps a `layout.button.*.font` token name to its role.
    nonisolated static func role(named name: String) -> QuireFont.Role {
        QuireFont.Role(rawValue: name) ?? .body
    }

    // MARK: Geometry

    private var padX: CGFloat { variant == .link ? Quire.Layout.Button.linkPadX : size.padX }

    private var keycapSize: NSSize? {
        keycap.map { QuireKeycap.size(for: $0, style: .standard) }
    }

    /// The face's own width for its content: padding, the glyph or spinner slot, the label.
    private var faceWidth: CGFloat {
        let normal = contentWidth(title: title, role: widestRole, lead: symbolName.map { glyphWidth($0) })
        guard let loadingTitle else { return 2 * padX + normal }
        let loadingLead = max(symbolName.map { glyphWidth($0) } ?? 0, QuireSpinnerView.Size.small.diameter)
        let loading = contentWidth(title: loadingTitle, role: widestRole, lead: loadingLead)
        return 2 * padX + max(normal, loading)
    }

    private func contentWidth(title: String, role: QuireFont.Role, lead: CGFloat?) -> CGFloat {
        let label = title.isEmpty ? 0 : QuireDraw.width(QuireDraw.line(title, role, .black))
        guard let lead else { return label }
        return lead + (label > 0 ? Quire.Layout.Button.glyphGap : 0) + label
    }

    private func glyphWidth(_ name: String) -> CGFloat {
        QuireDraw.symbolSize(name, size: .custom(size.glyph)).width
    }

    /// The strong role for primary and destructive (wider than the Medium a non-key primary uses), so the
    /// width never changes with key state.
    private var widestRole: QuireFont.Role {
        variant == .primary || variant == .destructive ? size.strongRole : size.role
    }

    public override var intrinsicContentSize: NSSize {
        var width = faceWidth
        if let keycapSize { width += keycapGap + keycapSize.width }
        return NSSize(width: ceil(width), height: size.height)
    }

    public override var faceRect: NSRect {
        var face = bodyRect
        guard let keycapSize else { return face }
        let taken = keycapGap + keycapSize.width
        face.size.width = max(0, face.width - taken)
        if keycapLeads { face.origin.x += taken }
        return face
    }

    private var keycapRect: NSRect? {
        guard let keycapSize else { return nil }
        let body = bodyRect
        let x = keycapLeads ? body.minX : body.maxX - keycapSize.width
        return NSRect(x: x, y: (body.midY - keycapSize.height / 2).rounded(), width: keycapSize.width, height: keycapSize.height)
    }

    // MARK: Look

    /// The variant this button draws as now: a primary button in a window that is not key draws as secondary.
    public var drawnVariant: Variant {
        variant == .primary && !isWindowKey ? .secondary : variant
    }

    private var drawnRole: QuireFont.Role {
        let v = drawnVariant
        return v == .primary || v == .destructive ? size.strongRole : size.role
    }

    private struct Look {
        var fill: [NSColor] = []
        var edge: NSColor?
        var label: NSColor
        var underline = false
    }

    private var look: Look {
        let state = interactionState
        guard isEnabled else {
            switch drawnVariant {
            case .ghost, .link: return Look(label: .qInkDisabled)
            case .primary, .secondary, .destructive: return Look(fill: [.qFill], label: .qInkDisabled)
            }
        }
        switch drawnVariant {
        case .primary:
            let fill: NSColor = state == .pressed ? .qAccentFillPressed : state == .hover ? .qAccentFillHover : .qAccentFill
            return Look(fill: [fill], label: .qOnAccent)
        case .destructive:
            let fill: NSColor = state == .pressed ? .qDangerFillPressed : state == .hover ? .qDangerFillHover : .qDangerFill
            return Look(fill: [fill], label: .qOnDanger)
        case .secondary:
            let wash: [NSColor] = state == .pressed ? [.qPressed] : state == .hover ? [.qHover] : []
            return Look(fill: [.qRaised] + wash, edge: .qRuleStrong, label: .qInk)
        case .ghost:
            let wash: [NSColor] = state == .pressed ? [.qPressed] : state == .hover ? [.qHover] : []
            return Look(fill: wash, label: state == .rest ? .qInk2 : .qInk)
        case .link:
            let underline = state != .rest || QuireEnvironment.isGraphite
            return Look(label: state == .pressed ? .qInk2 : .qAccent, underline: underline)
        }
    }

    /// The ring's gap: 2 pt around the accent and danger fills, 1 pt otherwise.
    private var ringGap: CGFloat {
        let v = drawnVariant
        return isEnabled && (v == .primary || v == .destructive) ? QuireFocusRing.gapOnFill : QuireFocusRing.gap
    }

    private var spinnerColor: NSColor {
        guard isEnabled else { return .qInkDisabled }
        switch drawnVariant {
        case .primary: return .qOnAccent
        case .destructive: return .qOnDanger
        case .secondary, .ghost, .link: return .qInk3
        }
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let face = faceRect
        let look = look
        let radius = size.cornerRadius
        for color in look.fill { QuireDraw.fill(face, radius: radius, color) }
        if let edge = look.edge, isEnabled { QuireDraw.strokeInside(face, radius: radius, width: Quire.Border.Strong.width, edge) }

        let content = contentLayout(in: face)
        if let lead = content.lead, !isLoading, let symbolName {
            QuireDraw.symbol(symbolName, size: .custom(size.glyph), color: look.label, centredIn: lead)
        }
        if let label = content.label {
            let role = drawnRole
            let string = QuireDraw.line(content.title, role, look.label)
            QuireDraw.draw(string, x: label.minX, top: label.minY, maxWidth: label.width, lineHeight: role.lineHeight)
            if look.underline {
                let y = label.minY + QuireDraw.baselineFromTop(role) + Quire.Layout.TextStyle.linkUnderlineOffset
                let width = min(label.width, QuireDraw.width(string))
                look.label.setFill()
                NSRect(x: label.minX, y: y.rounded(), width: width, height: Quire.Layout.TextStyle.linkUnderline).fill()
            }
        }
        if let keycap, let rect = keycapRect {
            QuireKeycap.draw(keycap, style: .standard, in: rect)
        }
        if showsFocusRing {
            QuireFocusRing.draw(around: face, cornerRadius: radius, gap: ringGap)
        }
    }

    private struct ContentLayout {
        var lead: NSRect?
        var label: NSRect?
        var title: String
    }

    /// The glyph (or spinner) slot and the label box, centred together in the face.
    private func contentLayout(in face: NSRect) -> ContentLayout {
        let role = drawnRole
        let text = isLoading ? (loadingTitle ?? title) : title
        var leadWidth: CGFloat?
        if let symbolName { leadWidth = glyphWidth(symbolName) }
        if isLoading { leadWidth = max(leadWidth ?? 0, QuireSpinnerView.Size.small.diameter) }
        let labelWidth = text.isEmpty ? 0 : QuireDraw.width(QuireDraw.line(text, role, .black))
        let gap = leadWidth != nil && labelWidth > 0 ? Quire.Layout.Button.glyphGap : 0
        let total = (leadWidth ?? 0) + gap + labelWidth
        let available = face.width - 2 * padX
        var x = (face.midX - min(total, available) / 2).rounded()
        var result = ContentLayout(title: text)
        if let leadWidth {
            let h = max(size.glyph, QuireSpinnerView.Size.small.diameter)
            result.lead = NSRect(x: x, y: face.midY - h / 2, width: leadWidth, height: h)
            x += leadWidth + gap
        }
        if labelWidth > 0 {
            let lineHeight = role.lineHeight
            result.label = NSRect(x: x, y: (face.midY - lineHeight / 2).rounded(), width: max(0, face.maxX - padX - x), height: lineHeight)
        }
        return result
    }

    public override func layout() {
        super.layout()
        guard let spinner else { return }
        let lead = contentLayout(in: faceRect).lead ?? .zero
        let d = QuireSpinnerView.Size.small.diameter
        spinner.frame = NSRect(x: (lead.midX - d / 2).rounded(), y: (lead.midY - d / 2).rounded(), width: d, height: d)
    }

    // MARK: Changes

    private func contentDidChange() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        stateDidChange()
    }

    private func loadingDidChange() {
        if isLoading {
            let spinner = self.spinner ?? QuireSpinnerView(size: .small, color: spinnerColor)
            if self.spinner == nil {
                addSubview(spinner)
                self.spinner = spinner
            }
            spinner.color = spinnerColor
            spinner.startAnimation()
        } else {
            spinner?.stopAnimation()
            spinner?.removeFromSuperview()
            spinner = nil
        }
        contentDidChange()
    }

    public override func stateDidChange() {
        super.stateDidChange()
        if let spinner, !spinner.color.isEqual(spinnerColor) { spinner.color = spinnerColor }
    }

    // MARK: Keyboard

    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEnabled, !keyEquivalent.isEmpty, QuireButton.matches(event, keyEquivalent: keyEquivalent, modifiers: keyEquivalentModifierMask)
        else { return super.performKeyEquivalent(with: event) }
        activate()
        return true
    }

    /// NSButton's matching: Caps Lock, the keypad and the function-key flag never stop a match, and keypad
    /// Enter (U+0003) counts as Return.
    static func matches(_ event: NSEvent, keyEquivalent: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
        guard flags == modifiers.intersection(.deviceIndependentFlagsMask) else { return false }
        var characters = event.charactersIgnoringModifiers ?? ""
        // Caps Lock can uppercase the characters of an unshifted letter; the equivalent is still meant.
        if event.modifierFlags.contains(.capsLock), !flags.contains(.shift) { characters = characters.lowercased() }
        if characters == keyEquivalent { return true }
        return keyEquivalent == "\r" && characters == "\u{3}"
    }

    // MARK: Accessibility

    public override func accessibilityRole() -> NSAccessibility.Role? { .button }

    public override func accessibilityLabel() -> String? {
        super.accessibilityLabel() ?? (isLoading ? (loadingTitle ?? title) : title)
    }
}
