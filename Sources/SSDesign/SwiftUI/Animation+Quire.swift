import SwiftUI

extension Animation {
    /// A token duration on a token curve, as a SwiftUI timing curve (spec §4.10).
    public static func quire(_ duration: TimeInterval, _ curve: Quire.Motion.Curve) -> Animation {
        let p = curve.controlPoints
        return .timingCurve(Double(p.0), Double(p.1), Double(p.2), Double(p.3), duration: duration)
    }

    /// The animation a motion plan asks for, or nil when it runs instantly (Reduce Motion `.instant`, or a
    /// zero duration). Pass it to `.animation(_:value:)` or `withAnimation(_:)`; nil applies the change at once.
    public static func quire(_ plan: Quire.Motion.Plan) -> Animation? {
        plan.animates ? .quire(plan.duration, plan.curve) : nil
    }
}
