import AppKit
import QuartzCore

/// The contrail (spec §2, §5.37): the one drawn element that means time is moving. A 2 pt line in `accent`
/// (`onSlip` on slips) whose last 32 pt behind the head fade to transparent, with a 4 pt head dot at the
/// moving end.
///
/// Determinate, the length is the progress (sync line download, attachment transfers). Indeterminate, a
/// segment 0.36 of the width sweeps across every `dur.contrailSweep`; under Reduce Motion it is a static
/// segment 0.4 of the width. As a countdown (undo send, a toast's life) it drains linearly over the time left,
/// stepping once per second under Reduce Motion, and freezes while `isPaused`.
///
/// The view is 4 pt tall (the head); the line runs through its middle 2 pt. Place it so that line sits on the
/// edge it runs along. Its animations loop or track time, so `Quire.Motion.finishAll()` never ends them.
///
/// The line is a gradient (transparent to the colour over the tail, then solid) inside a clip whose width is
/// the length, rather than a stroked path under a gradient mask: layer masks are skipped by `render(in:)`,
/// so `cacheDisplay` snapshots (the app's own `--snapshot-*`) drew a masked line as nothing at all.
@MainActor
public final class QuireContrailView: NSView {
    public var mode: QuireProgressMode = .determinate(0) {
        didSet { modeDidChange() }
    }

    /// `accent` by default; `onSlip` on a slip.
    public var color: NSColor = .qAccent {
        didSet { bindColors() }
    }

    /// Freezes a countdown where it is (a toast's contrail while the pointer rests on it, §5.30).
    public var isPaused = false {
        didSet { if oldValue != isPaused { pauseDidChange() } }
    }

    private let clip = CALayer()
    /// The visible length: its width is the fraction of the view's width, and it clips the line.
    private let lineClip = CALayer()
    /// The whole-width line with its tail fade, fixed in place while `lineClip` grows and drains over it.
    private let line = CAGradientLayer()
    private let head = CALayer()
    private let sweep = CALayer()
    private let sweepLine = CAGradientLayer()
    private let sweepHead = CALayer()
    private var colors: QuireLayerColors!
    private var clock: QuireCountdownClock?
    private static let animationKey = "quire.contrail"

    private static var lineWidth: CGFloat { Quire.Layout.Progress.contrail }
    private static var headSize: CGFloat { Quire.Layout.Progress.contrailHead }
    private static var tail: CGFloat { Quire.Layout.Progress.contrailTail }

    public init(mode: QuireProgressMode = .determinate(0), color: NSColor = .qAccent) {
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: QuireContrailView.headSize))
        wantsLayer = true
        colors = QuireLayerColors(view: self)
        clip.masksToBounds = true
        lineClip.masksToBounds = true
        lineClip.anchorPoint = CGPoint(x: 0, y: 0.5)
        line.startPoint = CGPoint(x: 0, y: 0.5)
        line.endPoint = CGPoint(x: 1, y: 0.5)
        lineClip.addSublayer(line)
        head.cornerRadius = QuireContrailView.headSize / 2
        sweepLine.startPoint = CGPoint(x: 0, y: 0.5)
        sweepLine.endPoint = CGPoint(x: 1, y: 0.5)
        sweepHead.cornerRadius = QuireContrailView.headSize / 2
        sweep.anchorPoint = .zero
        sweep.addSublayer(sweepLine)
        sweep.addSublayer(sweepHead)
        clip.addSublayer(lineClip)
        clip.addSublayer(head)
        clip.addSublayer(sweep)
        layer?.addSublayer(clip)
        bindColors()
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
        self.mode = mode
        modeDidChange()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireContrailView is built in code") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: QuireContrailView.headSize)
    }

    private func bindColors() {
        colors.bind("line", color) { [weak self] cg in
            self?.line.colors = [cg.copy(alpha: 0) ?? cg, cg, cg]
        }
        colors.set(color, for: \CALayer.backgroundColor, of: head)
        colors.set(color, for: \CALayer.backgroundColor, of: sweepHead)
        colors.bind("sweepLine", color) { [weak self] cg in
            self?.sweepLine.colors = [cg.copy(alpha: 0) ?? cg, cg]
        }
    }

    /// The share of the width the line covers now (the presentation value while it drains).
    public var displayedFraction: CGFloat {
        guard bounds.width > 0 else { return 0 }
        return (lineClip.presentation() ?? lineClip).bounds.width / bounds.width
    }

    /// Seconds left on a countdown.
    public var countdownRemaining: TimeInterval? { clock?.remaining }

    // MARK: Modes

    private func modeDidChange() {
        clock?.invalidate()
        clock = nil
        if case .countdown(let duration, let remaining) = mode {
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

    private func headX(forLength length: CGFloat) -> CGFloat {
        // The head's centre sits 1 pt inside the line's end, as the reader's CSS head overhangs it by 1 pt.
        length - 1
    }

    private func render() {
        let width = bounds.width
        let lineY = bounds.midY
        let head = QuireContrailView.headSize
        // Movement (the sweep, the drain) collapses under Reduce Motion: a static segment, a stepped drain.
        let reduceMotion = !Quire.Motion.plan(Quire.Motion.contrailSweep, .linear, reduced: .instant).animatesMovement
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        for layer in [lineClip, self.head, sweep] { layer.removeAnimation(forKey: QuireContrailView.animationKey) }
        clock?.stopTicking()

        let lineWidth = QuireContrailView.lineWidth
        lineClip.position = CGPoint(x: 0, y: lineY)
        lineClip.bounds = CGRect(x: 0, y: 0, width: lineClip.bounds.width, height: lineWidth)
        line.frame = CGRect(x: 0, y: 0, width: width, height: lineWidth)
        let tailEnd = NSNumber(value: Double(width > 0 ? min(1, QuireContrailView.tail / width) : 1))
        line.locations = [0, tailEnd, 1]
        self.head.bounds = CGRect(x: 0, y: 0, width: head, height: head)

        func setLength(_ fraction: CGFloat) {
            lineClip.bounds = CGRect(x: 0, y: 0, width: width * fraction, height: lineWidth)
        }

        func showLine(_ fraction: CGFloat) {
            lineClip.isHidden = false
            sweep.isHidden = true
            setLength(fraction)
            self.head.position = CGPoint(x: headX(forLength: width * fraction), y: lineY)
            self.head.opacity = fraction > 0 ? 1 : 0
        }

        switch mode {
        case .determinate(let value):
            showLine(CGFloat(min(1, max(0, value.isFinite ? value : 0))))
        case .indeterminate:
            lineClip.isHidden = true
            self.head.opacity = 0
            sweep.isHidden = false
            let share = reduceMotion ? Quire.Layout.Progress.reducedSegment : Quire.Layout.Progress.indeterminateSegment
            let segment = width * share
            sweep.bounds = CGRect(x: 0, y: 0, width: segment, height: head)
            sweepLine.frame = CGRect(x: 0, y: (head - QuireContrailView.lineWidth) / 2, width: segment, height: QuireContrailView.lineWidth)
            sweepLine.locations = [0, NSNumber(value: Double(segment > 0 ? min(1, QuireContrailView.tail / segment) : 1))]
            sweepHead.frame = CGRect(x: headX(forLength: segment) - head / 2, y: 0, width: head, height: head)
            let top = lineY - head / 2
            if reduceMotion {
                sweep.position = CGPoint(x: (width - segment) / 2, y: top)
            } else {
                sweep.position = CGPoint(x: -segment, y: top)
                let move = CABasicAnimation(keyPath: "position.x")
                move.fromValue = -segment
                move.toValue = width
                move.duration = Quire.Motion.contrailSweep
                move.timingFunction = Quire.Motion.Curve.linear.timingFunction
                move.repeatCount = .infinity
                sweep.add(move, forKey: QuireContrailView.animationKey)
            }
        case .countdown:
            guard let clock else { break }
            if reduceMotion || !clock.isRunning {
                showLine(reduceMotion ? clock.steppedFraction : clock.fraction)
                if reduceMotion, clock.isRunning { clock.startTicking() }
            } else {
                let from = clock.fraction
                showLine(from)
                // The model ends empty; the animation drains to it, so removing it shows the end state.
                setLength(0)
                self.head.position = CGPoint(x: -head, y: lineY)
                let timing = Quire.Motion.Curve.linear.timingFunction
                let drain = CABasicAnimation(keyPath: "bounds.size.width")
                drain.fromValue = width * from
                drain.toValue = 0
                drain.duration = clock.remaining
                drain.timingFunction = timing
                lineClip.add(drain, forKey: QuireContrailView.animationKey)
                let travel = CABasicAnimation(keyPath: "position.x")
                travel.fromValue = headX(forLength: width * from)
                travel.toValue = -head
                travel.duration = clock.remaining
                travel.timingFunction = timing
                self.head.add(travel, forKey: QuireContrailView.animationKey)
            }
        }
        CATransaction.commit()
    }

    // MARK: Accessibility

    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .progressIndicator }

    public override func accessibilityValue() -> Any? {
        switch mode {
        case .determinate(let value): return NSNumber(value: value)
        case .indeterminate: return nil
        case .countdown: return NSNumber(value: Double(clock?.fraction ?? 0))
        }
    }
}
