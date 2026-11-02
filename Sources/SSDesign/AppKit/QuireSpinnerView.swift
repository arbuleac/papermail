import AppKit
import QuartzCore

/// Quire's spinner (spec §5.37, §8.2), the one replacement for every `NSProgressIndicator`: a ¾ ring in a
/// `CAShapeLayer` that turns once per `dur.spinnerTurn`.
///
/// It owns its timing: `startAnimation()` shows nothing for `dur.spinnerDelay` (150 ms) and never shows at all
/// if `stopAnimation()` comes sooner, so fast work never flashes a spinner; then it fades in over `dur.quick`.
/// The rotation runs only while the spinner is revealed, visible and in a window. Spinners keep turning under
/// Reduce Motion (they are essential and small, §4.10) and are never finished by `Quire.Motion.finishAll()`.
@MainActor
public final class QuireSpinnerView: NSView {
    public var size: Size {
        didSet { if oldValue != size { invalidateIntrinsicContentSize(); needsLayout = true } }
    }

    /// `ink3` by default; the label colour inside filled buttons (`onAccent`, `onDanger`), `onSlip2` on slips.
    public var color: NSColor {
        didSet { colors.set(color, for: \CAShapeLayer.strokeColor, of: arc) }
    }

    /// How long `startAnimation()` waits before showing anything.
    public var delay: TimeInterval = Quire.Motion.spinnerDelay

    /// Called once each time the spinner actually appears (after the delay), for owners that swap something
    /// out only when it does (the search field's magnifier, §5.6).
    public var onReveal: (@MainActor () -> Void)?

    /// Work is running: `startAnimation()` was called and `stopAnimation()` has not been.
    public private(set) var isAnimating = false
    /// The spinner is showing (the delay has passed).
    public private(set) var isRevealed = false

    private let arc = CAShapeLayer()
    private var colors: QuireLayerColors!
    private var revealTimer: Timer?
    private static let rotationKey = "quire.spinner.rotation"

    public init(size: Size = .small, color: NSColor = .qInk3) {
        self.size = size
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: size.diameter, height: size.diameter))
        wantsLayer = true
        colors = QuireLayerColors(view: self)
        arc.fillColor = nil
        arc.lineCap = .butt
        arc.strokeStart = 0
        arc.strokeEnd = Quire.Layout.Progress.spinnerArc
        arc.opacity = 0
        arc.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "lineWidth": NSNull()]
        layer?.addSublayer(arc)
        colors.set(color, for: \CAShapeLayer.strokeColor, of: arc)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireSpinnerView is built in code") }

    public override var isFlipped: Bool { true }
    public override var intrinsicContentSize: NSSize { NSSize(width: size.diameter, height: size.diameter) }

    public override func layout() {
        super.layout()
        let d = size.diameter
        let frame = NSRect(x: (bounds.midX - d / 2).rounded(), y: (bounds.midY - d / 2).rounded(), width: d, height: d)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = frame
        arc.lineWidth = size.strokeWidth
        // A circle inset by half the stroke, starting at 45° so the open quarter sits on the right at rest,
        // as the reader's CSS spinner leaves its right border transparent.
        let path = CGMutablePath()
        let radius = (d - size.strokeWidth) / 2
        let start = CGFloat.pi / 4
        path.addArc(center: CGPoint(x: d / 2, y: d / 2), radius: radius, startAngle: start, endAngle: start + 2 * .pi, clockwise: false)
        arc.path = path
        CATransaction.commit()
    }

    // MARK: Running

    /// Work started: reveal after `delay`, unless `stopAnimation()` comes first.
    public func startAnimation() {
        guard !isAnimating else { return }
        isAnimating = true
        guard delay > 0 else { reveal(); return }
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.reveal() }
        }
        RunLoop.main.add(timer, forMode: .common)
        revealTimer = timer
    }

    /// Work ended: hide at once (or never show) and stop turning.
    public func stopAnimation() {
        isAnimating = false
        revealTimer?.invalidate()
        revealTimer = nil
        guard isRevealed else { return }
        isRevealed = false
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.removeAllAnimations()
        arc.opacity = 0
        CATransaction.commit()
        setAccessibilityElement(false)
    }

    private func reveal() {
        revealTimer = nil
        guard isAnimating, !isRevealed else { return }
        isRevealed = true
        updateRotation()
        Quire.Motion.animate(arc, keyPath: "opacity", to: Float(1), duration: Quire.Motion.quick, curve: .settle, reduced: .keep)
        setAccessibilityElement(true)
        onReveal?()
    }

    /// The rotation runs only while it can be seen: revealed, not hidden, in a window.
    private func updateRotation() {
        let shouldTurn = isRevealed && window != nil && !isHiddenOrHasHiddenAncestor
        let turning = arc.animation(forKey: QuireSpinnerView.rotationKey) != nil
        if shouldTurn, !turning {
            let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
            rotation.fromValue = 0
            rotation.toValue = 2 * CGFloat.pi
            rotation.duration = Quire.Motion.spinnerTurn
            rotation.timingFunction = Quire.Motion.Curve.linear.timingFunction
            rotation.repeatCount = .infinity
            rotation.isRemovedOnCompletion = false
            arc.add(rotation, forKey: QuireSpinnerView.rotationKey)
        } else if !shouldTurn, turning {
            arc.removeAnimation(forKey: QuireSpinnerView.rotationKey)
        }
    }

    /// True while the rotation animation is attached (revealed, visible, in a window).
    public var isTurning: Bool { arc.animation(forKey: QuireSpinnerView.rotationKey) != nil }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateRotation()
    }

    public override func viewDidHide() {
        super.viewDidHide()
        updateRotation()
    }

    public override func viewDidUnhide() {
        super.viewDidUnhide()
        updateRotation()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        colors.refresh()
    }

    /// The arc's resolved stroke colour, for tests and snapshots.
    public var resolvedColor: CGColor? { arc.strokeColor }

    // MARK: Accessibility

    public override func accessibilityRole() -> NSAccessibility.Role? { .busyIndicator }
    public override func accessibilityLabel() -> String? { super.accessibilityLabel() ?? "In progress" }
}
