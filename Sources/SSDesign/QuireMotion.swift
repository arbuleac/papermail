import AppKit
import QuartzCore

// The motion runtime (spec §4.10, §8.2): token durations and curves, the Reduce Motion fallbacks, and
// `finishAll()`, which every key press calls first so held keys never queue animation.
extension Quire.Motion {
    private final class WeakAnimator {
        weak var animator: QuireAnimator?
        init(_ animator: QuireAnimator) { self.animator = animator }
    }

    @MainActor private static var registry: [ObjectIdentifier: WeakAnimator] = [:]

    // MARK: Plans

    /// The plan for an animation of `duration` and `curve` with the given Reduce Motion fallback.
    public static func plan(_ duration: TimeInterval, _ curve: Curve, reduced: ReducedMotion,
                            reduceMotion: Bool = QuireEnvironment.reduceMotion) -> Plan {
        guard reduceMotion else { return Plan(duration: duration, curve: curve, isReduced: false) }
        switch reduced {
        case .keep: return Plan(duration: duration, curve: curve, isReduced: true)
        case .instant: return Plan(duration: 0, curve: curve, isReduced: true)
        case .fade: return Plan(duration: reducedFade, curve: .linear, isReduced: true)
        }
    }

    // MARK: Registry

    @MainActor public static func register(_ animator: QuireAnimator) {
        registry[ObjectIdentifier(animator)] = WeakAnimator(animator)
    }

    @MainActor public static func unregister(_ animator: QuireAnimator) {
        registry[ObjectIdentifier(animator)] = nil
    }

    /// Animators still running.
    @MainActor public static var runningCount: Int {
        registry = registry.filter { $0.value.animator != nil }
        return registry.count
    }

    /// Jumps every running animation to its end state, then returns: the caller applies the new action on
    /// top of settled state. Animators are snapshotted first because finishing one may register another.
    @MainActor public static func finishAll() {
        let running = registry.values.compactMap(\.animator)
        registry.removeAll()
        guard !running.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for animator in running { animator.finishAnimation() }
        CATransaction.commit()
    }

    // MARK: Running

    /// Runs `animations` in an `NSAnimationContext` group with the token duration and curve, interruptible
    /// (implicit animations start from the presentation value) and finishable. `participants` are the views
    /// whose layers the group animates; `finishAll()` removes their running animations, which leaves the
    /// model values the group already set. Under Reduce Motion the plan collapses as `reduced` says; with a
    /// zero duration the changes apply in this frame and `completion` runs before this returns.
    @MainActor @discardableResult
    public static func run(_ duration: TimeInterval, _ curve: Curve, reduced: ReducedMotion, participants: [NSView] = [],
                           animations: (Plan) -> Void, completion: (@MainActor () -> Void)? = nil) -> QuireAnimator? {
        let plan = plan(duration, curve, reduced: reduced)
        guard plan.animates else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                CATransaction.setDisableActions(true)
                animations(plan)
            }
            completion?()
            return nil
        }
        let group = GroupAnimation(participants: participants, completion: completion)
        register(group)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = plan.duration
            context.timingFunction = plan.curve.timingFunction
            context.allowsImplicitAnimation = true
            animations(plan)
        }, completionHandler: {
            MainActor.assumeIsolated { group.groupDidEnd() }
        })
        return group
    }

    /// Animates one layer property from its presentation value to `value`. The model value is set first, so
    /// removing the animation (`finishAll()`) shows the end state. Under Reduce Motion a `.fade` fallback
    /// fades only `opacity`; any other key path snaps, because a single property cannot cross-fade.
    ///
    /// `completion` runs when the animation ends or `finishAll()` finishes it, never when a newer `animate`
    /// call on the same layer and key path replaces it: the newer call owns the end state then, so a
    /// fade-out-then-remove cannot remove a view that a fade-in has brought back.
    @MainActor @discardableResult
    public static func animate(_ layer: CALayer, keyPath: String, to value: Any?, duration: TimeInterval, curve: Curve,
                               reduced: ReducedMotion, completion: (@MainActor () -> Void)? = nil) -> QuireAnimator? {
        var plan = plan(duration, curve, reduced: reduced)
        if plan.isReduced, reduced == .fade, keyPath != "opacity" {
            plan = Plan(duration: 0, curve: curve, isReduced: true)
        }
        let from = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
        let key = "quire." + keyPath
        LayerAnimation.running(on: layer, key: key)?.supersede()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.removeAnimation(forKey: key)
        layer.setValue(value, forKeyPath: keyPath)
        CATransaction.commit()
        guard plan.animates else {
            completion?()
            return nil
        }
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = value
        animation.duration = plan.duration
        animation.timingFunction = plan.curve.timingFunction
        let runner = LayerAnimation(layer: layer, key: key, completion: completion)
        register(runner)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { runner.animationDidEnd() }
        }
        layer.add(animation, forKey: key)
        CATransaction.commit()
        return runner
    }
}

extension Quire.Motion.Curve {
    /// How far along the curve is at `time`, a fraction of the duration (0…1, clamped), as Core Animation would place
    /// it: the cubic Bézier's y where its x is `time`. For motion stepped frame by frame (`QuireFrameAnimation`), which
    /// must follow the same curves the layers do.
    public func progress(at time: Double) -> Double {
        let t = min(1, max(0, time))
        let (x1, y1, x2, y2) = controlPoints
        let cx = 3 * Double(x1), bx = 3 * (Double(x2) - Double(x1)) - cx, ax = 1 - cx - bx
        let cy = 3 * Double(y1), by = 3 * (Double(y2) - Double(y1)) - cy, ay = 1 - cy - by
        func x(_ s: Double) -> Double { ((ax * s + bx) * s + cx) * s }
        func dx(_ s: Double) -> Double { (3 * ax * s + 2 * bx) * s + cx }
        func y(_ s: Double) -> Double { ((ay * s + by) * s + cy) * s }
        // Newton's method from s = t, then bisection where the slope is too flat to trust.
        var s = t
        for _ in 0..<8 {
            let error = x(s) - t
            if abs(error) < 1e-7 { return y(s) }
            let slope = dx(s)
            if abs(slope) < 1e-6 { break }
            s -= error / slope
        }
        var low = 0.0, high = 1.0
        s = t
        for _ in 0..<40 {
            let value = x(s)
            if abs(value - t) < 1e-7 { break }
            if value < t { low = s } else { high = s }
            s = (low + high) / 2
        }
        return y(s)
    }
}

/// One `NSAnimationContext` group: finished by removing its participants' running animations.
@MainActor
final class GroupAnimation: QuireAnimator {
    private var participants: [WeakView]
    private var completion: (@MainActor () -> Void)?
    private(set) var isDone = false

    private struct WeakView {
        weak var view: NSView?
    }

    init(participants: [NSView], completion: (@MainActor () -> Void)?) {
        self.participants = participants.map { WeakView(view: $0) }
        self.completion = completion
    }

    func finishAnimation() {
        guard !isDone else { return }
        for p in participants {
            if let layer = p.view?.layer { GroupAnimation.removeAnimations(layer) }
        }
        end()
    }

    func groupDidEnd() {
        guard !isDone else { return }
        Quire.Motion.unregister(self)
        end()
    }

    private func end() {
        isDone = true
        participants = []
        let c = completion
        completion = nil
        c?()
    }

    /// A frame change animates sublayers too (their positions follow the resize), so the whole tree settles.
    /// Only the group's implicit animations go: `quire.*` keys belong to `Quire.Motion.animate` runners, which
    /// `finishAll()` finishes itself, and to spinners and contrails, whose loops and countdowns it never ends.
    static func removeAnimations(_ layer: CALayer) {
        for key in layer.animationKeys() ?? [] where !key.hasPrefix("quire.") {
            layer.removeAnimation(forKey: key)
        }
        for sub in layer.sublayers ?? [] { removeAnimations(sub) }
    }
}

/// One explicit layer animation started by `Quire.Motion.animate`.
@MainActor
final class LayerAnimation: QuireAnimator {
    private weak var layer: CALayer?
    private let key: String
    private var completion: (@MainActor () -> Void)?
    private(set) var isDone = false

    private struct Slot: Hashable {
        let layer: ObjectIdentifier
        let key: String
    }

    private final class WeakRunner {
        weak var runner: LayerAnimation?
        init(_ runner: LayerAnimation) { self.runner = runner }
    }

    /// The runner animating each layer and key now, so a newer `animate` call can supersede it.
    private static var slots: [Slot: WeakRunner] = [:]

    init(layer: CALayer, key: String, completion: (@MainActor () -> Void)?) {
        self.layer = layer
        self.key = key
        self.completion = completion
        LayerAnimation.slots[Slot(layer: ObjectIdentifier(layer), key: key)] = WeakRunner(self)
    }

    /// The live runner for `key` on `layer`, if one is still running.
    static func running(on layer: CALayer, key: String) -> LayerAnimation? {
        guard let runner = slots[Slot(layer: ObjectIdentifier(layer), key: key)]?.runner,
              !runner.isDone, runner.layer === layer else { return nil }
        return runner
    }

    func finishAnimation() {
        guard !isDone else { return }
        layer?.removeAnimation(forKey: key)
        end(runCompletion: true)
    }

    func animationDidEnd() {
        guard !isDone else { return }
        Quire.Motion.unregister(self)
        end(runCompletion: true)
    }

    /// A newer animation of the same layer and key replaced this one: it ends without its completion.
    func supersede() {
        guard !isDone else { return }
        Quire.Motion.unregister(self)
        end(runCompletion: false)
    }

    private func end(runCompletion: Bool) {
        isDone = true
        if let layer {
            let slot = Slot(layer: ObjectIdentifier(layer), key: key)
            if LayerAnimation.slots[slot]?.runner === self { LayerAnimation.slots[slot] = nil }
        }
        let c = completion
        completion = nil
        if runCompletion { c?() }
    }
}
