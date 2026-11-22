import AppKit
import QuartzCore

/// The determinate bar of spec §5.37: 4 pt, radius 2 (a pill), track `fill`, fill `accent` (Settings ›
/// Accounts download status, 96 pt wide). It also runs indeterminate and as a countdown, with the same rules
/// as the contrail: a sweeping 0.36 segment (a static 0.4 segment under Reduce Motion) and a linear drain
/// that steps once per second under Reduce Motion.
///
/// Determinate progress jumps without easing and never goes backwards within one run: a smaller value is
/// ignored until `reset()` or a different mode starts a new run.
@MainActor
public final class QuireProgressBar: NSView {
    public var mode: QuireProgressMode = .determinate(0) {
        didSet { modeDidChange(from: oldValue) }
    }

    /// The fill colour; `accent` by default.
    public var color: NSColor = .qAccent {
        didSet { colors.set(color, for: \CALayer.backgroundColor, of: fill) }
    }

    /// Freezes a countdown where it is (and resumes it when cleared).
    public var isPaused = false {
        didSet { if oldValue != isPaused { pauseDidChange() } }
    }

    private let track = CALayer()
    private let fill = CALayer()
    private var colors: QuireLayerColors!
    private var clock: QuireCountdownClock?
    private var shownFraction: Double = 0
    private static let animationKey = "quire.progress"

    public init(mode: QuireProgressMode = .determinate(0)) {
        super.init(frame: NSRect(x: 0, y: 0, width: Quire.Layout.Settings.statusBarWidth, height: Quire.Layout.Progress.barHeight))
        wantsLayer = true
        colors = QuireLayerColors(view: self)
        let radius = Quire.Layout.Progress.barRadius
        track.cornerRadius = radius
        track.masksToBounds = true
        fill.cornerRadius = radius
        fill.anchorPoint = .zero
        layer?.addSublayer(track)
        track.addSublayer(fill)
        colors.set(.qFill, for: \CALayer.backgroundColor, of: track)
        colors.set(color, for: \CALayer.backgroundColor, of: fill)
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
        self.mode = mode
        modeDidChange(from: .indeterminate)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireProgressBar is built in code") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Quire.Layout.Progress.barHeight)
    }

    /// Starts a new determinate run at `fraction`, which may be lower than before.
    public func reset(to fraction: Double = 0) {
        shownFraction = 0
        mode = .determinate(fraction)
    }

    /// The fraction drawn now (the presentation value while a countdown drains).
    public var displayedFraction: CGFloat {
        let width = bounds.width
        guard width > 0 else { return 0 }
        let current = fill.presentation() ?? fill
        return current.bounds.width / width
    }

    // MARK: Modes

    private func clamp(_ value: Double) -> Double { min(1, max(0, value.isFinite ? value : 0)) }

    private func modeDidChange(from old: QuireProgressMode) {
        clock?.invalidate()
        clock = nil
        switch mode {
        case .determinate(let value):
            if case .determinate = old {
                shownFraction = max(shownFraction, clamp(value))
            } else {
                shownFraction = clamp(value)
            }
        case .indeterminate:
            break
        case .countdown(let duration, let remaining):
            let clock = QuireCountdownClock(duration: duration, remaining: remaining)
            clock.onTick = { [weak self] in self?.render() }
            self.clock = clock
            if !isPaused { clock.start() }
        }
        render()
    }

    private func pauseDidChange() {
        guard let clock else { return }
        if isPaused { clock.pause() } else { clock.start() }
        render()
    }

    @objc private func environmentDidChange(_ note: Notification) {
        render()
    }

    public override func layout() {
        super.layout()
        render()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colors.refresh()
    }

    /// Lays the fill out for the current mode and (re)starts its animation from where it is now.
    private func render() {
        let width = bounds.width
        let height = Quire.Layout.Progress.barHeight
        // Movement (the sweep, the drain) collapses under Reduce Motion: a static segment, a stepped drain.
        let reduceMotion = !Quire.Motion.plan(Quire.Motion.contrailSweep, .linear, reduced: .instant).animatesMovement
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = NSRect(x: 0, y: (bounds.height - height) / 2, width: width, height: height)
        fill.removeAnimation(forKey: QuireProgressBar.animationKey)
        clock?.stopTicking()
        switch mode {
        case .determinate:
            fill.frame = NSRect(x: 0, y: 0, width: width * CGFloat(shownFraction), height: height)
        case .indeterminate:
            if reduceMotion {
                let segment = width * Quire.Layout.Progress.reducedSegment
                fill.frame = NSRect(x: (width - segment) / 2, y: 0, width: segment, height: height)
            } else {
                let segment = width * Quire.Layout.Progress.indeterminateSegment
                fill.frame = NSRect(x: -segment, y: 0, width: segment, height: height)
                let sweep = CABasicAnimation(keyPath: "position.x")
                sweep.fromValue = -segment
                sweep.toValue = width
                sweep.duration = Quire.Motion.contrailSweep
                sweep.timingFunction = Quire.Motion.Curve.linear.timingFunction
                sweep.repeatCount = .infinity
                fill.add(sweep, forKey: QuireProgressBar.animationKey)
            }
        case .countdown:
            guard let clock else { break }
            if reduceMotion || !clock.isRunning {
                let fraction = reduceMotion ? clock.steppedFraction : clock.fraction
                fill.frame = NSRect(x: 0, y: 0, width: width * fraction, height: height)
                if reduceMotion, clock.isRunning { clock.startTicking() }
            } else {
                let from = width * clock.fraction
                fill.frame = NSRect(x: 0, y: 0, width: 0, height: height)
                let drain = CABasicAnimation(keyPath: "bounds.size.width")
                drain.fromValue = from
                drain.toValue = 0
                drain.duration = clock.remaining
                drain.timingFunction = Quire.Motion.Curve.linear.timingFunction
                fill.add(drain, forKey: QuireProgressBar.animationKey)
            }
        }
        CATransaction.commit()
    }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .progressIndicator }

    public override func accessibilityValue() -> Any? {
        switch mode {
        case .determinate: return NSNumber(value: shownFraction)
        case .indeterminate: return nil
        case .countdown: return NSNumber(value: Double(clock?.fraction ?? 0))
        }
    }
}
