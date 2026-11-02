import AppKit

/// A Quire checkbox (spec §5.26): 14 pt, radius 3. Off is `sheet` with a 1 pt `ruleStrong` edge; on is
/// `accentFill` with a 10 pt `checkmark` in `onAccent`; mixed is `accentFill` with an 8 × 2 bar. Hover and press
/// follow `QuireChoiceDrawing.boxFills`; focus rings the box outside a 1 pt gap (2 pt when on); disabled draws
/// the box at 0.45 opacity with the label `inkDisabled`. The label is `body` `ink`, 8 pt away, and part of the
/// hit area. Window key state changes nothing (on fills stay Iron Gall, §3.4).
@MainActor
public final class QuireCheckbox: QuireControl {
    public var title: String? {
        didSet { if oldValue != title { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }

    /// `.off`, `.on` or `.mixed`.
    public var state: NSControl.StateValue = .off {
        didSet { if oldValue != state { needsDisplay = true } }
    }

    public init(title: String? = nil, state: NSControl.StateValue = .off, target: AnyObject? = nil, action: Selector? = nil) {
        self.title = title
        super.init(frame: .zero)
        self.state = state
        self.target = target
        self.action = action
        setFrameSize(frame(forAlignmentRect: NSRect(origin: .zero, size: intrinsicContentSize)).size)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireCheckbox is built in code") }

    private static var boxSize: NSSize { NSSize(width: Quire.Layout.Checkbox.size, height: Quire.Layout.Checkbox.size) }

    public override var intrinsicContentSize: NSSize {
        QuireChoiceDrawing.size(control: QuireCheckbox.boxSize, title: title)
    }

    /// The box, at the leading edge.
    public var boxRect: NSRect { QuireChoiceDrawing.controlRect(QuireCheckbox.boxSize, in: bodyRect) }

    public override func draw(_ dirtyRect: NSRect) {
        let box = boxRect
        let radius = Quire.Layout.Checkbox.radius
        let on = state != .off
        QuireChoiceDrawing.withDisabledOpacity(isEnabled, in: box) {
            for fill in QuireChoiceDrawing.boxFills(on: on, state: interactionState) {
                QuireDraw.fill(box, radius: radius, fill)
            }
            if !on {
                QuireDraw.strokeInside(box, radius: radius, width: Quire.Border.Strong.width, .qRuleStrong)
            } else if state == .mixed {
                let bar = Quire.Layout.Checkbox.mixedBar
                let rect = NSRect(x: box.midX - bar[0] / 2, y: box.midY - bar[1] / 2, width: bar[0], height: bar[1])
                QuireDraw.fill(rect, radius: bar[1] / 2, .qOnAccent)
            } else {
                QuireDraw.symbol("checkmark", size: .custom(Quire.Layout.Checkbox.glyph), color: .qOnAccent, centredIn: box)
            }
        }
        QuireChoiceDrawing.drawLabel(title, enabled: isEnabled, after: box, in: bodyRect)
        if showsFocusRing {
            QuireFocusRing.draw(around: box, cornerRadius: radius, gap: on ? QuireFocusRing.gapOnFill : QuireFocusRing.gap)
        }
    }

    /// A click, Space or VoiceOver's press: off → on, on → off, mixed → on.
    public override func activate() {
        state = state == .on ? .off : .on
        super.activate()
    }

    // MARK: Accessibility

    public override func accessibilityRole() -> NSAccessibility.Role? { .checkBox }
    public override func accessibilityLabel() -> String? { super.accessibilityLabel() ?? title }

    public override func accessibilityValue() -> Any? {
        switch state {
        case .on: return NSNumber(value: 1)
        case .mixed: return NSNumber(value: 2)
        default: return NSNumber(value: 0)
        }
    }
}
