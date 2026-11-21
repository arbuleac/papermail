import AppKit

/// One segment of a `QuireSplitButton` (spec §5.23): the action (a glyph and the label) or the menu (the chevron behind
/// the divider).
///
/// Each segment is a control of its own, with its own hover, press, keyboard focus, enabled state, tooltip, target and
/// VoiceOver name, so the Tab loop, the pointer and VoiceOver meet two buttons where the eye sees one; the split button
/// decides the face they share (accent, raised while the window is not key, quiet while the action cannot act) and
/// draws the focus ring of whichever has the keyboard. A segment is made by its split button.
@MainActor
public final class QuireSplitSegment: QuireControl {
    public let kind: Kind

    /// The label (action segment).
    public var title: String {
        didSet { if oldValue != title { contentDidChange() } }
    }

    /// A leading symbol at the size's glyph size (action segment).
    public var symbolName: String? {
        didSet { if oldValue != symbolName { contentDidChange() } }
    }

    /// Work is running: a spinner in the label colour takes the glyph's place and the label reads `loadingTitle`.
    public var isLoading = false {
        didSet { if oldValue != isLoading { loadingDidChange() } }
    }

    /// The gerund shown while loading (“Sending…”).
    public var loadingTitle: String? {
        didSet { if oldValue != loadingTitle { contentDidChange() } }
    }

    /// The split button this segment belongs to; it owns both segments, so this never outlives it.
    weak var split: QuireSplitButton?

    /// Internal so a gallery can show a revealed spinner without waiting out its delay.
    var spinner: QuireSpinnerView?

    init(kind: Kind, title: String = "", symbolName: String? = nil) {
        self.kind = kind
        self.title = title
        self.symbolName = symbolName
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireSplitSegment is built in code") }

    // MARK: Geometry

    var size: QuireButton.Size { split?.size ?? .regular }

    private var metrics: Metrics { Metrics(size: size) }

    public override var intrinsicContentSize: NSSize {
        switch kind {
        case .action: return NSSize(width: actionWidth(symbolName: symbolName), height: size.height)
        case .menu: return NSSize(width: metrics.menuWidth, height: size.height)
        }
    }

    /// The action's face with `symbolName` as its glyph: its content at rest (glyph, label) or loading (spinner, gerund),
    /// whichever is wider, padded on both sides, so the face never moves when work starts. Widths use the strong role,
    /// the widest the face can draw in. Public so a host can ask whether the glyph fits before it shows it (the quick
    /// reply's tool row, §5.18).
    public func actionWidth(symbolName: String?) -> CGFloat {
        let padX = metrics.padX
        let role = size.strongRole
        let lead = symbolName.map { glyphWidth($0) }
        let rest = 2 * padX + contentWidth(title, role: role, lead: lead)
        guard let loadingTitle else { return ceil(rest) }
        let loadingLead = max(lead ?? 0, QuireSpinnerView.Size.small.diameter)
        return ceil(max(rest, 2 * padX + contentWidth(loadingTitle, role: role, lead: loadingLead)))
    }

    private func contentWidth(_ text: String, role: QuireFont.Role, lead: CGFloat?) -> CGFloat {
        let label = text.isEmpty ? 0 : QuireDraw.width(QuireDraw.line(text, role, .black))
        guard let lead else { return label }
        return lead + (label > 0 ? Quire.Layout.Button.glyphGap : 0) + label
    }

    private func glyphWidth(_ name: String) -> CGFloat {
        QuireDraw.symbolSize(name, size: .custom(size.glyph)).width
    }

    /// Clicks count over the face grown to the minimum hit size (§4.14), never across the divider: a segment narrower
    /// than the minimum grows away from it, into the ring margin on the button's outer side.
    public override var hitRect: NSRect {
        let face = faceRect
        let minHit = Quire.Layout.Button.minHit
        let dy = max(0, (minHit - face.height) / 2)
        var hit = face.insetBy(dx: 0, dy: -dy)
        let grow = max(0, minHit - face.width)
        hit.size.width += grow
        if kind == .action { hit.origin.x -= grow }
        return hit.intersection(bounds)
    }

    // MARK: Look

    /// What the face shows, from the split button's look and this segment's own state (§5.23 States).
    struct Palette {
        var fills: [NSColor]
        var edge: NSColor?
        var ink: NSColor
        var divider: NSColor
        var spinner: NSColor
    }

    var palette: Palette {
        let look = split?.look ?? .accent
        let state = interactionState
        let wash: [NSColor] = !isEnabled ? [] : state == .pressed ? [.qPressed] : state == .hover ? [.qHover] : []
        switch look {
        case .accent:
            let fill: NSColor = !isEnabled ? .qAccentFill
                : state == .pressed ? .qAccentFillPressed : state == .hover ? .qAccentFillHover : .qAccentFill
            // The face can act but this segment cannot (the chevron while Send sends): its ink steps back.
            let ink: NSColor = isEnabled ? .qOnAccent : NSColor.qOnAccent.withAlphaComponent(Quire.Layout.SplitButton.dimAlpha)
            return Palette(fills: [fill], edge: nil, ink: ink,
                           divider: NSColor.qOnAccent.withAlphaComponent(Quire.Layout.SplitButton.dividerAlpha), spinner: .qOnAccent)
        case .raised:
            let ink: NSColor
            switch kind {
            case .action: ink = isEnabled ? .qInk : .qInkDisabled
            case .menu: ink = !isEnabled ? .qInkDisabled : state == .rest ? .qInk2 : .qInk
            }
            return Palette(fills: [.qRaised] + wash, edge: .qRuleStrong, ink: ink,
                           divider: .qRuleStrong, spinner: isEnabled ? .qInk3 : .qInkDisabled)
        case .quiet:
            let ink: NSColor
            switch kind {
            case .action: ink = .qInkDisabled
            case .menu: ink = !isEnabled ? .qInkDisabled : state == .rest ? .qInk2 : .qInk
            }
            return Palette(fills: [.qFill] + wash, edge: nil, ink: ink,
                           divider: NSColor.qInk.withAlphaComponent(Quire.Layout.SplitButton.dividerAlpha / 2), spinner: .qInkDisabled)
        }
    }

    /// The label's role: the strong one, as a primary's, unless the window is not key, where the face is a secondary
    /// button's (§3.4), as `QuireButton` draws it.
    private var role: QuireFont.Role {
        (split?.actionSegment.isWindowKey ?? isWindowKey) ? size.strongRole : size.role
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let face = faceRect
        let palette = palette
        let radius = size.cornerRadius
        // The face's corners are round on the button's outer side and square at the divider: the shape is drawn a radius
        // longer on the joined side and clipped to the segment, so the two halves meet edge to edge.
        var shape = face
        shape.size.width += radius
        if kind == .menu { shape.origin.x -= radius }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: face).addClip()
        for fill in palette.fills { QuireDraw.fill(shape, radius: radius, fill) }
        if let edge = palette.edge { QuireDraw.strokeInside(shape, radius: radius, width: Quire.Border.Strong.width, edge) }
        NSGraphicsContext.restoreGraphicsState()

        switch kind {
        case .menu: drawMenu(in: face, palette: palette)
        case .action: drawAction(in: face, palette: palette)
        }
    }

    private func drawMenu(in face: NSRect, palette: Palette) {
        let m = metrics
        let divider = NSRect(x: face.minX, y: face.minY + m.dividerInsetY, width: m.divider, height: max(0, face.height - 2 * m.dividerInsetY))
        palette.divider.setFill()
        divider.fill()
        let chevron = NSRect(x: face.minX + m.divider, y: face.minY, width: max(0, face.width - m.divider), height: face.height)
        QuireDraw.symbol(Quire.Icon.titleMenu, size: .custom(Quire.Layout.Popup.chevron), color: palette.ink, centredIn: chevron)
    }

    private func drawAction(in face: NSRect, palette: Palette) {
        let content = contentLayout(in: face)
        if let lead = content.lead, !isLoading, let symbolName {
            QuireDraw.symbol(symbolName, size: .custom(size.glyph), color: palette.ink, centredIn: lead)
        }
        if let label = content.label {
            let string = QuireDraw.line(content.title, role, palette.ink)
            QuireDraw.draw(string, x: label.minX, top: label.minY, maxWidth: label.width, lineHeight: role.lineHeight)
        }
    }

    struct ContentLayout {
        var lead: NSRect?
        var label: NSRect?
        var title: String
    }

    /// The glyph and the label, or loading the spinner and the gerund, centred in the face between its paddings: a face
    /// wider than its content (the rest content of a face kept as wide as its gerund) centres it.
    func contentLayout(in face: NSRect) -> ContentLayout {
        let m = metrics
        let text = isLoading ? (loadingTitle ?? title) : title
        var lead: CGFloat? = symbolName.map { glyphWidth($0) }
        if isLoading { lead = max(lead ?? 0, QuireSpinnerView.Size.small.diameter) }
        let labelWidth = text.isEmpty ? 0 : ceil(QuireDraw.width(QuireDraw.line(text, role, .black)))
        let gap = lead != nil && labelWidth > 0 ? Quire.Layout.Button.glyphGap : 0
        let natural = 2 * m.padX + (lead ?? 0) + gap + labelWidth
        var x = face.minX + m.padX + max(0, ((face.width - natural) / 2).rounded())
        var result = ContentLayout(title: text)
        if let lead {
            let h = max(size.glyph, QuireSpinnerView.Size.small.diameter)
            result.lead = NSRect(x: x, y: face.midY - h / 2, width: lead, height: h)
            x += lead + gap
        }
        if labelWidth > 0 {
            let lineHeight = role.lineHeight
            result.label = NSRect(x: x, y: (face.midY - lineHeight / 2).rounded(), width: max(0, face.maxX - m.padX - x),
                                  height: lineHeight)
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
        pointerRegionsDidChange()
        split?.segmentContentDidChange()
    }

    private func loadingDidChange() {
        if isLoading {
            let spinner = self.spinner ?? QuireSpinnerView(size: .small, color: palette.spinner)
            if self.spinner == nil {
                addSubview(spinner)
                self.spinner = spinner
            }
            spinner.color = palette.spinner
            spinner.startAnimation()
        } else {
            spinner?.stopAnimation()
            spinner?.removeFromSuperview()
            spinner = nil
        }
        contentDidChange()
    }

    /// The face is shared: a change here (the action enabled or not, a hover) can change the other segment's look and
    /// where the ring is drawn.
    public override func stateDidChange() {
        super.stateDidChange()
        if let spinner {
            let color = palette.spinner
            if !spinner.color.isEqual(color) { spinner.color = color }
        }
        split?.segmentStateDidChange(self)
    }

    /// The arrow while loading: a second click starts nothing (§4.17).
    public override var pointerCursor: NSCursor? {
        isLoading ? .arrow : super.pointerCursor
    }

    // MARK: Mouse

    /// The menu segment acts on mouse-down, as a pull-down's menu opens, and stays pressed while its menu tracks.
    public override func mouseDown(with event: NSEvent) {
        guard kind == .menu else {
            super.mouseDown(with: event)
            return
        }
        guard isEnabled else { return }
        isPressed = true
        stateDidChange()
        displayIfNeeded()
        // The menu takes the mouse-up, so the press ends here rather than in `mouseUp`.
        activate()
        isPressed = false
        stateDidChange()
    }

    // MARK: Accessibility

    public override func accessibilityRole() -> NSAccessibility.Role? {
        kind == .menu ? .menuButton : .button
    }

    public override func accessibilityLabel() -> String? {
        super.accessibilityLabel() ?? (isLoading ? (loadingTitle ?? title) : title)
    }
}

extension QuireSplitSegment {
    /// The size's metrics (`layout.splitButton`, `layout.button`).
    struct Metrics {
        let padX: CGFloat
        let menuWidth: CGFloat
        let divider: CGFloat
        /// The divider is as tall as the size's glyph, centred on the face: its ends level with the paper plane's box.
        let dividerInsetY: CGFloat

        init(size: QuireButton.Size) {
            let s = Quire.Layout.SplitButton.self
            let index = QuireButton.Size.allCases.firstIndex(of: size) ?? 1
            padX = size.padX
            menuWidth = s.menuWidth[index]
            divider = s.divider
            dividerInsetY = ((size.height - size.glyph) / 2).rounded(.down)
        }
    }
}
