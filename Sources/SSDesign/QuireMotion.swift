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
    @MainActor @discardableResult
    public static func animate(_ layer: CALayer, keyPath: String, to value: Any?, duration: TimeInterval, curve: Curve,
                               reduced: ReducedMotion, completion: (@MainActor () -> Void)? = nil) -> QuireAnimator? {
        var plan = plan(duration, curve, reduced: reduced)
        if plan.isReduced, reduced == .fade, keyPath != "opacity" {
            plan = Plan(duration: 0, curve: curve, isReduced: true)
        }
        let from = (layer.presentation() ?? layer).value(forKeyPath: keyPath)
        let key = "quire." + keyPath
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
    static func removeAnimations(_ layer: CALayer) {
        layer.removeAllAnimations()
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

    init(layer: CALayer, key: String, completion: (@MainActor () -> Void)?) {
        self.layer = layer
        self.key = key
        self.completion = completion
    }

    func finishAnimation() {
        guard !isDone else { return }
        layer?.removeAnimation(forKey: key)
        end()
    }

    func animationDidEnd() {
        guard !isDone else { return }
        Quire.Motion.unregister(self)
        end()
    }

    private func end() {
        isDone = true
        let c = completion
        completion = nil
        c?()
    }
}
