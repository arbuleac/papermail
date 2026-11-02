import Foundation

extension Quire.Motion {
    /// How to run one animation now: a token duration and curve, or what Reduce Motion turns them into.
    public struct Plan: Equatable, Sendable {
        public let duration: TimeInterval
        public let curve: Curve
        /// Reduce Motion is on and changed this animation; a `.fade` caller animates opacity, not movement.
        public let isReduced: Bool

        public init(duration: TimeInterval, curve: Curve, isReduced: Bool) {
            self.duration = duration
            self.curve = curve
            self.isReduced = isReduced
        }

        public var animates: Bool { duration > 0 }

        /// Whether movement (position, size, scale) should animate. False under Reduce Motion for every
        /// fallback, including `.keep`, whose animation is a fade by definition.
        public var animatesMovement: Bool { animates && !isReduced }
    }
}
