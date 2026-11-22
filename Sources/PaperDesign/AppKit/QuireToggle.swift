import AppKit
import QuartzCore

/// A Quire switch (spec §5.26): a 30 × 18 track and a 14 pt knob inset 2 pt. Off, the track is `fill` with a
/// 1 pt `ruleStrong` edge and the knob leads; on, the track is `accentFill` and the knob trails. The knob face is
/// `knob` with its own 1 pt `ruleStrong` edge (the edge is what shows where it sits) and a static contact shadow
/// (`layout.toggle.knobShadow`).
///
/// Neither the track nor the knob ever takes a wash, so every state keeps its 3:1 pairs: hover changes nothing,
/// and a press is a shape, the knob stretching from 14 to 18 pt toward the track's centre (instantly on
/// mouse-down, back over `dur.quick` on release, or as it travels). The knob travels over `dur.quick`
/// `ease.glide`, instantly under Reduce Motion. Focus rings the track outside a 1 pt gap (2 pt when on);
/// disabled draws the switch at 0.45 opacity with the label `inkDisabled`.
///
/// With a `leadingSymbolName` it is a switch standing on its own in a bar (the reader header's reader mode, §5.59):
/// the symbol, then the label, then the track, so the words come before the switch, as they do in a bar.
@MainActor
public final class QuireToggle: QuireControl {
    public var title: String? {
        didSet { if oldValue != title { contentDidChange() } }
    }

    /// A symbol before the label and the switch (§5.26, “In a bar”): `inText`, in `ink2`, `toggle.symbolGap` from the
    /// label, which is then `label` `ink2`, `checkbox.labelGap` from the track at the trailing edge. nil, the default,
    /// is the form switch: the track first, its label after it in `body` `ink`.
    public var leadingSymbolName: String? {
        didSet { if oldValue != leadingSymbolName { contentDidChange() } }
    }

    private func contentDidChange() {
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    /// On or off. Setting it moves the knob without animation; the user's toggles animate.
    public var isOn: Bool {
        get { storedOn }
        set { setOn(newValue, animated: false) }
    }

    public var state: NSControl.StateValue {
        get { isOn ? .on : .off }
        set { isOn = newValue == .on }
    }

    private var storedOn = false
    let knob = CALayer()
    private var colors: QuireLayerColors!

    public init(title: String? = nil, isOn: Bool = false, target: AnyObject? = nil, action: Selector? = nil) {
        self.title = title
        super.init(frame: .zero)
        storedOn = isOn
        self.target = target
        self.action = action
        wantsLayer = true
        colors = QuireLayerColors(view: self)
        knob.borderWidth = Quire.Layout.Toggle.knobEdge
        knob.actions = ["position": NSNull(), "bounds": NSNull(), "opacity": NSNull(), "shadowColor": NSNull(), "shadowOpacity": NSNull()]
        layer?.addSublayer(knob)
        colors.set(.qKnob, for: \CALayer.backgroundColor, of: knob)
        colors.set(.qRuleStrong, for: \CALayer.borderColor, of: knob)
        setFrameSize(frame(forAlignmentRect: NSRect(origin: .zero, size: intrinsicContentSize)).size)
        applyKnobShadow()
        moveKnob(animated: false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireToggle is built in code") }

    private static var trackSize: NSSize { NSSize(width: Quire.Layout.Toggle.width, height: Quire.Layout.Toggle.height) }

    public override var intrinsicContentSize: NSSize {
        guard let symbol = leadingSymbolName else { return QuireChoiceDrawing.size(control: QuireToggle.trackSize, title: title) }
        let glyph = QuireDraw.symbolSize(symbol, size: .inText)
        var width = glyph.width + QuireToggle.trackSize.width
        if let words = barLabel(enabled: true) {
            width += Quire.Layout.Toggle.symbolGap + QuireDraw.width(words) + QuireChoiceDrawing.labelGap
        } else {
            width += QuireChoiceDrawing.labelGap
        }
        let height = max(QuireToggle.trackSize.height, QuireFont.Role.label.lineHeight, glyph.height)
        return NSSize(width: ceil(width), height: ceil(height))
    }

    public var trackRect: NSRect {
        guard leadingSymbolName != nil else { return QuireChoiceDrawing.controlRect(QuireToggle.trackSize, in: bodyRect) }
        let size = QuireToggle.trackSize
        return NSRect(x: bodyRect.maxX - size.width, y: (bodyRect.midY - size.height / 2).rounded(), width: size.width, height: size.height)
    }

    /// The label as a bar sets it, before the switch.
    private func barLabel(enabled: Bool) -> NSAttributedString? {
        guard let title, !title.isEmpty else { return nil }
        return QuireDraw.line(title, .label, enabled ? .qInk2 : .qInkDisabled)
    }

    /// Whether the knob is drawn stretched: a press in progress, or a forced pressed state.
    public var isKnobStretched: Bool { interactionState == .pressed }

    /// Where the knob sits for a given on state and stretch.
    func knobFrame(on: Bool, stretched: Bool) -> NSRect {
        let t = Quire.Layout.Toggle.self
        let track = trackRect
        let width = stretched ? t.knobPressedWidth : t.knob
        let x = on ? track.maxX - t.inset - width : track.minX + t.inset
        return NSRect(x: x, y: track.minY + t.inset, width: width, height: t.knob)
    }

    /// The knob's current model frame, for tests.
    public var knobRect: NSRect { knob.frame }

    // MARK: Changes

    private func setOn(_ on: Bool, animated: Bool) {
        guard on != storedOn else { return }
        storedOn = on
        moveKnob(animated: animated)
        needsDisplay = true
        QuireAccessibility.valueChanged(self)
    }

    private func moveKnob(animated: Bool) {
        let target = knobFrame(on: storedOn, stretched: isKnobStretched)
        let position = NSValue(point: NSPoint(x: target.midX, y: target.midY))
        let bounds = NSValue(rect: NSRect(origin: .zero, size: target.size))
        let duration = animated ? Quire.Motion.quick : 0
        Quire.Motion.animate(knob, keyPath: "position", to: position, duration: duration, curve: .glide, reduced: .instant)
        Quire.Motion.animate(knob, keyPath: "bounds", to: bounds, duration: duration, curve: .glide, reduced: .instant)
        let radius = Quire.Layout.Toggle.knob / 2
        knob.cornerRadius = radius
        // An explicit shadow path, as every shadowed layer has (§4.8); it follows the stretch at once.
        knob.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: target.size), cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    public override func layout() {
        super.layout()
        moveKnob(animated: false)
    }

    public override func stateDidChange() {
        super.stateDidChange()
        // A forced pressed state, or a press starting, stretches the knob at once; it is never animated in.
        let expected = knobFrame(on: storedOn, stretched: isKnobStretched)
        if knob.frame.width != expected.width, isKnobStretched { moveKnob(animated: false) }
        knob.opacity = isEnabled ? 1 : Float(Quire.Layout.Checkbox.disabledOpacity)
    }

    public override func pressDidEnd(activated: Bool) {
        // Released without toggling: the knob shrinks back over dur.quick. A toggle animates in activate().
        if !activated { moveKnob(animated: true) }
    }

    public override func activate() {
        setOn(!storedOn, animated: true)
        super.activate()
    }

    public override func appearanceDidChange() {
        super.appearanceDidChange()
        colors.refresh()
        applyKnobShadow()
    }

    /// The knob's contact shadow per mode: offset (0, 1), blur 2, its own colour in each of the four modes.
    private func applyKnobShadow() {
        let s = Quire.Layout.Toggle.KnobShadow.self
        let mode = QuireMode(effectiveAppearance)
        let hex: String
        switch mode {
        case .light: hex = s.light
        case .dark: hex = s.dark
        case .lightHC: hex = s.lightHC
        case .darkHC: hex = s.darkHC
        }
        QuireShadowLayer(x: s.x, y: s.y, blur: s.blur, spread: s.spread, rgba: QuireDraw.rgba(hex: hex)).apply(to: knob, in: self)
    }

    // MARK: Drawing

    public override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        let radius = track.height / 2
        QuireChoiceDrawing.withDisabledOpacity(isEnabled, in: track) {
            if storedOn {
                QuireDraw.fill(track, radius: radius, .qAccentFill)
            } else {
                QuireDraw.fill(track, radius: radius, .qFill)
                QuireDraw.strokeInside(track, radius: radius, width: Quire.Border.Strong.width, .qRuleStrong)
            }
        }
        if let symbol = leadingSymbolName {
            drawBarLead(symbol, before: track)
        } else {
            QuireChoiceDrawing.drawLabel(title, enabled: isEnabled, after: track, in: bodyRect)
        }
        if showsFocusRing {
            QuireFocusRing.draw(around: track, cornerRadius: radius, gap: storedOn ? QuireFocusRing.gapOnFill : QuireFocusRing.gap)
        }
    }

    /// The symbol and the label before the track, centred on the body's line.
    private func drawBarLead(_ symbol: String, before track: NSRect) {
        let body = bodyRect
        let glyph = QuireDraw.symbolSize(symbol, size: .inText)
        let glyphRect = NSRect(x: body.minX, y: body.midY - glyph.height / 2, width: glyph.width, height: glyph.height)
        QuireDraw.symbol(symbol, size: .inText, color: isEnabled ? .qInk2 : .qInkDisabled, centredIn: glyphRect)
        guard let words = barLabel(enabled: isEnabled) else { return }
        let lineHeight = QuireFont.Role.label.lineHeight
        let x = glyphRect.maxX + Quire.Layout.Toggle.symbolGap
        QuireDraw.draw(words, x: x, top: (body.midY - lineHeight / 2).rounded(), maxWidth: track.minX - QuireChoiceDrawing.labelGap - x,
                       lineHeight: lineHeight)
    }

    // MARK: Accessibility

    public override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    public override func accessibilitySubrole() -> NSAccessibility.Subrole? { .switch }
    public override func accessibilityLabel() -> String? { super.accessibilityLabel() ?? title }
    public override func accessibilityValue() -> Any? { NSNumber(value: isOn ? 1 : 0) }
}
