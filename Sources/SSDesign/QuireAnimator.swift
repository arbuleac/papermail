/// Anything that runs an animation `Quire.Motion.finishAll()` must be able to end at once (spec §4.10: the
/// keystroke finishes motion). Register while running, unregister when done; the registry holds it weakly.
@MainActor
public protocol QuireAnimator: AnyObject {
    /// Jump to the end state now: model values final, running animations removed, completion run.
    func finishAnimation()
}
