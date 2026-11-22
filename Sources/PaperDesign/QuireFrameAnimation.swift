import AppKit
import QuartzCore

/// A value stepped once a frame along a token curve (spec §4.10), for motion a layer cannot carry on its own: a view that
/// draws what moves and redraws at every step (a list row's swipe settling open or closed, §5.7). It ticks on the view's
/// display link, so each step lands on a frame, and a fallback timer ends it when its time is up if no frame comes (a
/// window off screen, hidden or occluded). It is registered with `Quire.Motion` while it runs, so a keystroke's
/// `finishAll()` jumps it to its end like every other animation.
@MainActor
public final class QuireFrameAnimation: NSObject, QuireAnimator {
    public let from: CGFloat
    public let to: CGFloat
    public let duration: TimeInterval
    public let curve: Quire.Motion.Curve
    public private(set) var isDone = false

    private var step: ((CGFloat) -> Void)?
    private var completion: (@MainActor () -> Void)?
    private var start: CFTimeInterval = 0
    private var link: CADisplayLink?
    private var deadline: Timer?

    private init(from: CGFloat, to: CGFloat, duration: TimeInterval, curve: Quire.Motion.Curve, step: @escaping (CGFloat) -> Void,
                 completion: (@MainActor () -> Void)?) {
        self.from = from
        self.to = to
        self.duration = duration
        self.curve = curve
        self.step = step
        self.completion = completion
    }

    /// Steps `step` from `from` to `to` over `duration` along `curve`, starting on the next frame of `view`'s display.
    /// Under Reduce Motion the plan collapses as `reduced` says (`Quire.Motion.plan`). With nothing to animate (a zero
    /// plan, no distance, or `view` in no window) it steps to `to` and completes before returning nil.
    @discardableResult
    public static func run(from: CGFloat, to: CGFloat, _ duration: TimeInterval, _ curve: Quire.Motion.Curve,
                           reduced: Quire.Motion.ReducedMotion, in view: NSView, step: @escaping (CGFloat) -> Void,
                           completion: (@MainActor () -> Void)? = nil) -> QuireFrameAnimation? {
        let plan = Quire.Motion.plan(duration, curve, reduced: reduced)
        guard plan.animates, from != to, view.window != nil else {
            step(to)
            completion?()
            return nil
        }
        let animation = QuireFrameAnimation(from: from, to: to, duration: plan.duration, curve: plan.curve, step: step,
                                            completion: completion)
        animation.begin(in: view)
        return animation
    }

    private func begin(in view: NSView) {
        start = CACurrentMediaTime()
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        // A frame or two of slack: the display link normally lands the last step itself.
        let timer = Timer(timeInterval: duration + 0.05, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishAnimation() }
        }
        RunLoop.main.add(timer, forMode: .common)
        deadline = timer
        Quire.Motion.register(self)
    }

    /// The value where the curve is `elapsed` seconds in.
    public func value(after elapsed: TimeInterval) -> CGFloat {
        guard duration > 0 else { return to }
        return from + (to - from) * CGFloat(curve.progress(at: elapsed / duration))
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard !isDone else { return }
        // The time the frame being drawn will be shown, so the steps keep the curve's pace on screen.
        let elapsed = max(link.targetTimestamp, CACurrentMediaTime()) - start
        guard elapsed < duration else { return finishAnimation() }
        step?(value(after: elapsed))
    }

    /// Jumps to the end: the last step, then the completion.
    public func finishAnimation() {
        guard !isDone else { return }
        step?(to)
        end(runCompletion: true)
    }

    /// Stops where it is, without the last step or the completion: something else now moves the value (the fingers
    /// took the row again).
    public func cancel() {
        guard !isDone else { return }
        end(runCompletion: false)
    }

    private func end(runCompletion: Bool) {
        isDone = true
        link?.invalidate()
        link = nil
        deadline?.invalidate()
        deadline = nil
        Quire.Motion.unregister(self)
        step = nil
        let c = completion
        completion = nil
        if runCompletion { c?() }
    }
}
