extension Quire.Motion {
    /// What an animation becomes under Reduce Motion: the last column of the §4.10 table.
    public enum ReducedMotion: Sendable {
        /// "same": the animation is already a fade, and fades are kept.
        case keep
        /// Movement, rises and height changes that simply happen.
        case instant
        /// "fade dur.reducedFade" / "cross-fade": the movement is dropped and the change fades linearly over
        /// `reducedFade`. The caller animates opacity only when `Plan.isReduced` is set.
        case fade
    }
}
