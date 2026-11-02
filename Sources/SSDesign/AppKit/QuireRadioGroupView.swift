import AppKit

/// One choice among a few (spec §5.26, §8.3 “QuireRadioGroupView”): a row (or column) of `QuireRadioButton`s that
/// is one Tab stop, the selected radio, with ← → (and ↑ ↓) moving the choice and the focus together, skipping
/// disabled radios. It sends its action when the choice changes. Accessibility: a radio group whose children
/// are the radios.
@MainActor
public final class QuireRadioGroupView: NSControl {
    public private(set) var buttons: [QuireRadioButton] = []

    public var selectedIndex: Int? {
        get { buttons.firstIndex { $0.isSelected } }
        set {
            for (index, button) in buttons.enumerated() { button.isSelected = index == newValue }
        }
    }

    public var orientation: NSUserInterfaceLayoutOrientation = .horizontal {
        didSet { invalidateIntrinsicContentSize(); needsLayout = true }
    }

    /// Between radios: 16 pt in a row, 8 pt in a column by default.
    public var spacing: CGFloat = Quire.Space.s6 {
        didSet { invalidateIntrinsicContentSize(); needsLayout = true }
    }

    /// Called with the new index whenever the user changes the choice.
    public var onChange: (@MainActor (Int) -> Void)?

    public init(titles: [String], selectedIndex: Int? = nil, orientation: NSUserInterfaceLayoutOrientation = .horizontal) {
        self.orientation = orientation
        super.init(frame: .zero)
        if orientation == .vertical { spacing = Quire.Space.s4 }
        setTitles(titles)
        self.selectedIndex = selectedIndex
        setFrameSize(frame(forAlignmentRect: NSRect(origin: .zero, size: intrinsicContentSize)).size)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireRadioGroupView is built in code") }

    public override var isFlipped: Bool { true }

    /// Replaces the radios.
    public func setTitles(_ titles: [String]) {
        buttons.forEach { $0.removeFromSuperview() }
        buttons = titles.map { QuireRadioButton(title: $0) }
        for button in buttons {
            button.group = self
            addSubview(button)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // MARK: Geometry

    public override var alignmentRectInsets: NSEdgeInsets {
        let m = QuireFocusRing.margin
        return NSEdgeInsets(top: m, left: m, bottom: m, right: m)
    }

    public override var intrinsicContentSize: NSSize {
        let sizes = buttons.map(\.intrinsicContentSize)
        let gaps = CGFloat(max(0, sizes.count - 1)) * spacing
        if orientation == .horizontal {
            return NSSize(width: sizes.reduce(0) { $0 + $1.width } + gaps, height: sizes.map(\.height).max() ?? 0)
        }
        return NSSize(width: sizes.map(\.width).max() ?? 0, height: sizes.reduce(0) { $0 + $1.height } + gaps)
    }

    public override func layout() {
        super.layout()
        let m = QuireFocusRing.margin
        var origin = NSPoint(x: m, y: m)
        let height = intrinsicContentSize.height
        for button in buttons {
            let size = button.intrinsicContentSize
            var visual = NSRect(origin: origin, size: size)
            if orientation == .horizontal {
                visual.origin.y = m + (height - size.height) / 2
                origin.x += size.width + spacing
            } else {
                origin.y += size.height + spacing
            }
            button.frame = button.frame(forVisualRect: visual)
        }
    }

    // MARK: Choosing

    func select(_ radio: QuireRadioButton, sendAction: Bool) {
        guard let index = buttons.firstIndex(where: { $0 === radio }) else { return }
        let changed = selectedIndex != index
        selectedIndex = index
        guard sendAction, changed else { return }
        onChange?(index)
        self.sendAction(action, to: target)
    }

    /// Moves the choice (and the focus) to the next enabled radio in `step`'s direction, wrapping.
    func moveSelection(from radio: QuireRadioButton, by step: Int) {
        guard let start = buttons.firstIndex(where: { $0 === radio }), !buttons.isEmpty else { return }
        var index = start
        for _ in buttons.indices {
            index = (index + step + buttons.count) % buttons.count
            if buttons[index].isEnabled { break }
        }
        guard index != start, buttons[index].isEnabled else { return }
        select(buttons[index], sendAction: true)
        window?.makeFirstResponder(buttons[index])
    }

    /// The selected radio when it is enabled, otherwise the first enabled one.
    func isTabStop(_ radio: QuireRadioButton) -> Bool {
        if let selected = buttons.first(where: { $0.isSelected && $0.isEnabled }) { return selected === radio }
        return buttons.first(where: \.isEnabled) === radio
    }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .radioGroup }
    public override func accessibilityChildren() -> [Any]? { buttons }
}
