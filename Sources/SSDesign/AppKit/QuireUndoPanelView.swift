import AppKit

/// The undo-send panel's slip (spec §5.31): 280 × 52, radius 12, `slip` with its 1 pt `slipEdge` and `e3`.
/// Padding left 16 · the 15 pt glyph in `onSlip2` · 12 pt · the text block (the title 10 pt from the top in
/// `bodyMedium`, tabular, `onSlip`; the summary under it in `meta` `onSlip2`, tail-truncated) · 12 pt · the
/// action · padding right 12, and a 2 pt `onSlip` contrail draining along the bottom edge over the undo window.
///
/// The action has the toast action's metrics plus a resting 1 pt `onSlipEdge` outline (the panel has no
/// divider, so the outline says “button”); its “⌘Z” keycap hides when a newer toast owns ⌘Z (`ownsUndoKey`).
///
/// This is the view only. The shell puts it in a transparent, non-activating `NSPanel` grown by
/// `shadowMargins` so the `e3` shadow is never clipped, stacks panels, and decides what each state leads to.
@MainActor
public final class QuireUndoPanelView: NSView {
    public var state: State {
        didSet { if oldValue != state { stateDidChange() } }
    }

    /// The message summary on the second line: “Re: Contoso rollout · to Ben Carter”.
    public var summary: String {
        didSet { content.needsDisplay = true }
    }

    /// False when a newer toast took ⌘Z (§6.1): the Undo keeps working by click but hides its keycap.
    public var ownsUndoKey = true {
        didSet { if oldValue != ownsUndoKey { updateAction() } }
    }

    /// The Undo (counting) or Open draft (failed) action. Set its target and action, or use `onAction`.
    public private(set) var actionButton: QuireSlipActionButton?

    /// Called when the action is clicked or pressed, with the state it was clicked in.
    public var onAction: (@MainActor (State) -> Void)?

    /// Called once when a countdown started with `startCountdown` reaches zero.
    public var onCountdownEnd: (@MainActor () -> Void)?

    private let surface = QuireSurfaceView(frame: .zero)
    private let content = PanelContentView(frame: .zero)
    private let contrail = QuireContrailView(color: .qOnSlip)
    private let spinner = QuireSpinnerView(size: .medium, color: .qOnSlip2)
    private var clock: QuireCountdownClock?

    /// How far the panel window extends past the slip on each side so the `e3` shadow is never clipped:
    /// 32 pt above, 48 pt at each side, 68 pt below (`layout.undoPanel.shadowMargin*`).
    public static var shadowMargins: NSEdgeInsets {
        let u = Quire.Layout.UndoPanel.self
        return NSEdgeInsets(top: u.shadowMarginTop, left: u.shadowMarginSide, bottom: u.shadowMarginBottom, right: u.shadowMarginSide)
    }

    public static var size: NSSize { NSSize(width: Quire.Layout.UndoPanel.width, height: Quire.Layout.UndoPanel.height) }

    public init(state: State = .counting(secondsLeft: 5), summary: String) {
        self.state = state
        self.summary = summary
        super.init(frame: NSRect(origin: .zero, size: QuireUndoPanelView.size))
        clipsToBounds = false
        let u = Quire.Layout.UndoPanel.self
        surface.fillColor = .qSlip
        surface.cornerRadius = u.radius
        surface.elevation = Quire.Elevation.e3
        surface.edge = { _ in .solid(.qSlipEdge, width: 1) }
        content.wantsLayer = true
        content.layer?.cornerRadius = u.radius
        content.layer?.masksToBounds = true
        content.owner = self
        contrail.isHidden = true
        addSubview(surface)
        addSubview(content)
        content.addSubview(spinner)
        content.addSubview(contrail)
        stateDidChange()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireUndoPanelView is built in code") }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { QuireUndoPanelView.size }

    // MARK: Countdown

    /// Starts counting down `duration` (the undo window, 5000 ms by default; Settings offers 10000 and 20000):
    /// the title counts whole seconds and the contrail drains, linearly or once per second under Reduce
    /// Motion. `remaining` starts part-way through (a gallery, a panel restored after a window change).
    public func startCountdown(_ duration: TimeInterval, remaining: TimeInterval? = nil) {
        let left = min(duration, max(0, remaining ?? duration))
        clock?.invalidate()
        let clock = QuireCountdownClock(duration: duration, remaining: left)
        clock.onTick = { [weak self] in self?.countdownDidTick() }
        self.clock = clock
        state = .counting(secondsLeft: QuireUndoPanelView.wholeSeconds(left))
        contrail.mode = .countdown(duration: duration, remaining: left)
        contrail.isPaused = false
        contrail.isHidden = false
        clock.start()
        clock.startTicking()
    }

    /// Freezes the countdown where it is. Panels never pause in use (hover does not pause, §5.31); galleries
    /// and specimens freeze one to show it.
    public var isCountdownPaused = false {
        didSet {
            guard oldValue != isCountdownPaused, let clock else { return }
            contrail.isPaused = isCountdownPaused
            if isCountdownPaused { clock.pause() } else { clock.start(); clock.startTicking() }
        }
    }

    /// The slip's radius and elevation, for tests.
    var surfaceRadius: CGFloat { surface.cornerRadius }
    var surfaceElevation: QuireElevationLevel { surface.elevation }

    /// Seconds left on the countdown, nil when none runs.
    public var countdownRemaining: TimeInterval? { clock?.remaining }

    /// The contrail, for tests and for owners that read its state.
    public var countdownContrail: QuireContrailView { contrail }

    /// “Sending in 4 s” counts whole seconds up: 4.2 s left reads 5 until the boundary passes.
    static func wholeSeconds(_ remaining: TimeInterval) -> Int {
        Int(max(0, (remaining - 0.000_1).rounded(.up)))
    }

    private func countdownDidTick() {
        guard let clock, case .counting = state else { return }
        let left = clock.remaining
        state = .counting(secondsLeft: QuireUndoPanelView.wholeSeconds(left))
        if left <= 0 {
            stopCountdown()
            onCountdownEnd?()
        }
    }

    private func stopCountdown() {
        clock?.invalidate()
        clock = nil
        contrail.mode = .determinate(0)
        contrail.isHidden = true
    }

    // MARK: State

    private func stateDidChange() {
        if case .counting = state {} else { stopCountdown() }
        if state == .sending {
            spinner.delay = 0
            spinner.startAnimation()
        } else {
            spinner.stopAnimation()
        }
        spinner.isHidden = state != .sending
        updateAction()
        setAccessibilityLabel(nil)
        needsLayout = true
        content.needsDisplay = true
    }

    private func updateAction() {
        guard let title = state.actionTitle else {
            actionButton?.removeFromSuperview()
            actionButton = nil
            needsLayout = true
            return
        }
        let button = actionButton ?? {
            let button = QuireSlipActionButton(title: title, target: self, action: #selector(actionClicked(_:)))
            button.showsRestingOutline = true
            // The panel never becomes key, where cursor rects apply (§5.31).
            button.tracksPointerOutsideKeyWindow = true
            content.addSubview(button, positioned: .below, relativeTo: contrail)
            actionButton = button
            return button
        }()
        button.title = title
        if case .counting = state, ownsUndoKey {
            button.keycap = "⌘Z"
        } else {
            button.keycap = nil
        }
        button.sizeToFit()
        needsLayout = true
    }

    @objc private func actionClicked(_ sender: Any?) {
        onAction?(state)
    }

    // MARK: Geometry

    fileprivate struct Geometry {
        var glyph: NSRect
        var title: NSRect
        var subtitle: NSRect
        var action: NSRect?
    }

    fileprivate func geometry() -> Geometry {
        let u = Quire.Layout.UndoPanel.self
        let height = bounds.height
        let glyph = NSRect(x: u.padLeft, y: ((height - u.glyph) / 2).rounded(), width: u.glyph, height: u.glyph)
        var trailing = bounds.width - u.padRight
        var action: NSRect?
        if let actionButton {
            let size = actionButton.intrinsicContentSize
            let rect = NSRect(x: trailing - size.width, y: ((height - size.height) / 2).rounded(), width: size.width, height: size.height)
            action = rect
            trailing = rect.minX - u.actionGap
        }
        let x = glyph.maxX + u.glyphGap
        let width = max(0, trailing - x)
        let titleHeight = QuireFont.Role.bodyMedium.lineHeight
        let title = NSRect(x: x, y: u.titleTop, width: width, height: titleHeight)
        let subtitle = NSRect(x: x, y: title.maxY + u.lineGap, width: width, height: QuireFont.Role.meta.lineHeight)
        return Geometry(glyph: glyph, title: title, subtitle: subtitle, action: action)
    }

    public override func layout() {
        super.layout()
        surface.frame = bounds
        content.frame = bounds
        let g = geometry()
        if let actionButton, let rect = g.action {
            actionButton.frame = actionButton.frame(forVisualRect: rect)
        }
        let d = spinner.size.diameter
        spinner.frame = NSRect(x: g.glyph.midX - d / 2, y: g.glyph.midY - d / 2, width: d, height: d)
        let line = Quire.Layout.Progress.contrail
        let head = Quire.Layout.Progress.contrailHead
        // The contrail's line lies on the slip's bottom edge, inside the corner clip.
        contrail.frame = NSRect(x: 0, y: bounds.height - line - (head - line) / 2, width: bounds.width, height: head)
    }

    // MARK: Text

    fileprivate var subtitle: String { state.fixedSubtitle ?? summary }

    private static let titleFont: NSFont = {
        let base = QuireFont.font(.bodyMedium)
        // Tabular digits, so “Sending in 4 s” never jitters as it counts.
        let descriptor = base.fontDescriptor.addingAttributes([.featureSettings: [[
            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
            NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
        ]]])
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }()

    fileprivate var titleString: NSAttributedString {
        let string = NSMutableAttributedString(attributedString: QuireDraw.line(state.title, .bodyMedium, .qOnSlip))
        string.addAttribute(.font, value: QuireUndoPanelView.titleFont, range: NSRange(location: 0, length: string.length))
        return string
    }

    fileprivate var subtitleString: NSAttributedString { QuireDraw.line(subtitle, .meta, .qOnSlip2) }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilityLabel() -> String? {
        super.accessibilityLabel() ?? "\(QuireAccessibility.sentence(state.title)) \(QuireAccessibility.sentence(subtitle))"
    }

    // MARK: Content

    /// Draws the glyph and the two lines; the action, the spinner and the contrail are its subviews.
    fileprivate final class PanelContentView: NSView {
        weak var owner: QuireUndoPanelView?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                                   name: QuireEnvironment.didChangeNotification, object: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("built in code") }

        @objc private func environmentDidChange(_ note: Notification) {
            needsDisplay = true
        }

        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            guard let owner else { return }
            let g = owner.geometry()
            if let symbol = owner.state.symbolName {
                QuireDraw.symbol(symbol, size: .custom(Quire.Layout.UndoPanel.glyph), color: .qOnSlip2, centredIn: g.glyph)
            }
            QuireDraw.draw(owner.titleString, x: g.title.minX, top: g.title.minY, maxWidth: g.title.width, lineHeight: g.title.height)
            QuireDraw.draw(owner.subtitleString, x: g.subtitle.minX, top: g.subtitle.minY, maxWidth: g.subtitle.width,
                           lineHeight: g.subtitle.height)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func isAccessibilityElement() -> Bool { false }
    }
}
