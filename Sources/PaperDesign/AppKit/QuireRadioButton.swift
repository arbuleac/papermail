import AppKit

/// A Quire radio button (spec §5.26): a 14 pt circle, off `sheet` with a 1 pt `ruleStrong` edge, on
/// `accentFill` with a 6 pt `onAccent` dot; hover, press, focus and disabled as the checkbox. Radios belong to a
/// `QuireRadioGroupView`, which makes the group one Tab stop and moves the choice with the arrow keys.
@MainActor
public final class QuireRadioButton: QuireControl {
    public var title: String? {
        didSet { if oldValue != title { invalidateIntrinsicContentSize(); needsDisplay = true } }
    }

    public var isSelected = false {
        didSet {
            guard oldValue != isSelected else { return }
            needsDisplay = true
            pointerRegionsDidChange()
            QuireAccessibility.valueChanged(self)
        }
    }

    /// The group this radio belongs to; set by `QuireRadioGroupView`.
    public internal(set) weak var group: QuireRadioGroupView? {
        didSet { pointerRegionsDidChange() }
    }

    public var state: NSControl.StateValue {
        get { isSelected ? .on : .off }
        set { isSelected = newValue == .on }
    }

    public init(title: String? = nil, isSelected: Bool = false) {
        self.title = title
        self.isSelected = isSelected
        super.init(frame: .zero)
        setFrameSize(frame(forAlignmentRect: NSRect(origin: .zero, size: intrinsicContentSize)).size)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireRadioButton is built in code") }

    private static var circleSize: NSSize { NSSize(width: Quire.Layout.Radio.size, height: Quire.Layout.Radio.size) }

    public override var intrinsicContentSize: NSSize {
        QuireChoiceDrawing.size(control: QuireRadioButton.circleSize, title: title)
    }

    public var circleRect: NSRect { QuireChoiceDrawing.controlRect(QuireRadioButton.circleSize, in: bodyRect) }

    public override func draw(_ dirtyRect: NSRect) {
        let circle = circleRect
        QuireChoiceDrawing.withDisabledOpacity(isEnabled, in: circle) {
            for fill in QuireChoiceDrawing.boxFills(on: isSelected, state: interactionState) {
                QuireDraw.fillCircle(circle, fill)
            }
            if isSelected {
                let d = Quire.Layout.Radio.dot
                QuireDraw.fillCircle(NSRect(x: circle.midX - d / 2, y: circle.midY - d / 2, width: d, height: d), .qOnAccent)
            } else {
                let edge = NSBezierPath(ovalIn: circle.insetBy(dx: 0.5, dy: 0.5))
                edge.lineWidth = Quire.Border.Strong.width
                NSColor.qRuleStrong.setStroke()
                edge.stroke()
            }
        }
        QuireChoiceDrawing.drawLabel(title, enabled: isEnabled, after: circle, in: bodyRect)
        if showsFocusRing {
            QuireFocusRing.draw(around: circle, cornerRadius: circle.height / 2,
                                gap: isSelected ? QuireFocusRing.gapOnFill : QuireFocusRing.gap)
        }
    }

    /// The arrow over a group's chosen radio, which a click leaves as it is (§4.17).
    public override var pointerCursor: NSCursor? {
        group != nil && isSelected ? .arrow : super.pointerCursor
    }

    /// Choosing a radio selects it and deselects the rest of its group.
    public override func activate() {
        if let group {
            group.select(self, sendAction: true)
        } else {
            isSelected = true
            super.activate()
        }
    }

    /// Only the group's selected radio (or its first enabled one) is in the key-view loop.
    public override var canBecomeKeyView: Bool {
        guard super.canBecomeKeyView else { return false }
        return group?.isTabStop(self) ?? true
    }

    public override func keyDown(with event: NSEvent) {
        if let group, let key = event.specialKey {
            switch key {
            case .leftArrow, .upArrow:
                group.moveSelection(from: self, by: -1)
                return
            case .rightArrow, .downArrow:
                group.moveSelection(from: self, by: 1)
                return
            default:
                break
            }
        }
        super.keyDown(with: event)
    }

    // MARK: Accessibility

    public override func accessibilityRole() -> NSAccessibility.Role? { .radioButton }
    public override func accessibilityLabel() -> String? { super.accessibilityLabel() ?? title }
    public override func accessibilityValue() -> Any? { NSNumber(value: isSelected ? 1 : 0) }
}
