import AppKit

/// An icon-only button (spec §5.24, §5.12): a symbol in `ink2` on no fill, `hover` / `pressed` washes with the
/// symbol in `ink`, the focus ring outside a 1 pt gap, `inkDisabled` when disabled, and a 12 pt spinner in
/// place of the symbol while loading. It can also be on: the filled star in `star`, or a quiet toggle in
/// `accent` on `accentWash`; or a menu button that pops its menu on mouse-down (the Send button's drop-down).
///
/// Custom-glyph buttons need a name for VoiceOver: set `accessibilityLabel` (and a tooltip that repeats the
/// command and its shortcut, “Archive  E”, §5.34).
@MainActor
public final class QuireIconButton: QuireControl {
    public var symbolName: String {
        didSet { if oldValue != symbolName { needsDisplay = true } }
    }

    public var size: Size {
        didSet { if oldValue != size { invalidateIntrinsicContentSize(); stateDidChange() } }
    }

    /// The symbol size; nil uses the size's default (15 pt on 28 pt buttons, 14 pt otherwise). Named exceptions
    /// pass their metric: the compose nib at 18 pt, dismiss marks at 9 pt.
    public var symbolSize: QuireSymbolSize? {
        didSet { needsDisplay = true }
    }

    /// The button is on (starred, quiet toggle on).
    public var isOn = false {
        didSet {
            guard oldValue != isOn else { return }
            stateDidChange()
            if togglesOnClick { QuireAccessibility.valueChanged(self) }
        }
    }

    public var onStyle: OnStyle = .star {
        didSet { stateDidChange() }
    }

    /// The symbol drawn while on; nil keeps `symbolName` (`star` → `star.fill`).
    public var onSymbolName: String? {
        didSet { needsDisplay = true }
    }

    /// Flip `isOn` on every activation before sending the action (format toggles).
    public var togglesOnClick = false

    /// A menu button (the Send button's drop-down, §5.23): a click acts on mouse-down, as a pull-down's menu opens, and the
    /// face stays pressed while the action runs, which is while the menu it pops tracks. VoiceOver hears a menu button.
    public var isMenuButton = false

    public var isLoading = false {
        didSet { if oldValue != isLoading { loadingDidChange() } }
    }

    /// Internal so a gallery can show a revealed spinner without waiting out its delay.
    var spinner: QuireSpinnerView?

    public init(symbolName: String, size: Size = .large, accessibilityLabel: String? = nil,
                target: AnyObject? = nil, action: Selector? = nil) {
        self.symbolName = symbolName
        self.size = size
        super.init(frame: .zero)
        self.target = target
        self.action = action
        if let accessibilityLabel { setAccessibilityLabel(accessibilityLabel) }
        setFrameSize(frame(forAlignmentRect: NSRect(origin: .zero, size: intrinsicContentSize)).size)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireIconButton is built in code") }

    public override var intrinsicContentSize: NSSize { NSSize(width: size.side, height: size.side) }

    // MARK: Look

    private var fills: [NSColor] {
        guard isEnabled else { return [] }
        let state = interactionState
        if isOn, onStyle == .quiet {
            return [state == .pressed ? .qAccentWashPressed : state == .hover ? .qAccentWashHover : .qAccentWash]
        }
        switch state {
        case .pressed: return [.qPressed]
        case .hover: return [.qHover]
        case .rest, .focused: return []
        }
    }

    private var glyphColor: NSColor {
        guard isEnabled else { return .qInkDisabled }
        if isOn { return onStyle == .star ? .qStar : .qAccent }
        return interactionState == .rest ? .qInk2 : .qInk
    }

    public override func draw(_ dirtyRect: NSRect) {
        let face = faceRect
        for fill in fills { QuireDraw.fill(face, radius: size.cornerRadius, fill) }
        if !isLoading {
            let name = isOn ? (onSymbolName ?? symbolName) : symbolName
            QuireDraw.symbol(name, size: symbolSize ?? size.defaultSymbolSize, color: glyphColor, centredIn: face)
        }
        if showsFocusRing {
            QuireFocusRing.draw(around: face, cornerRadius: size.cornerRadius, gap: QuireFocusRing.gap)
        }
    }

    public override func layout() {
        super.layout()
        guard let spinner else { return }
        let face = faceRect
        let d = QuireSpinnerView.Size.small.diameter
        spinner.frame = NSRect(x: (face.midX - d / 2).rounded(), y: (face.midY - d / 2).rounded(), width: d, height: d)
    }

    private func loadingDidChange() {
        if isLoading {
            let spinner = QuireSpinnerView(size: .small, color: .qInk3)
            addSubview(spinner)
            self.spinner = spinner
            needsLayout = true
            spinner.startAnimation()
        } else {
            spinner?.stopAnimation()
            spinner?.removeFromSuperview()
            spinner = nil
        }
        needsDisplay = true
        pointerRegionsDidChange()
    }

    /// The arrow while loading, as `QuireButton` (§4.17).
    public override var pointerCursor: NSCursor? {
        isLoading ? .arrow : super.pointerCursor
    }

    public override func activate() {
        if togglesOnClick { isOn.toggle() }
        super.activate()
    }

    public override func mouseDown(with event: NSEvent) {
        guard isMenuButton else {
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
        if isMenuButton { return .menuButton }
        return togglesOnClick ? .checkBox : .button
    }
    public override func accessibilitySubrole() -> NSAccessibility.Subrole? { togglesOnClick ? .toggle : nil }
    public override func accessibilityValue() -> Any? { togglesOnClick ? NSNumber(value: isOn) : nil }
}
