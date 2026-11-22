import AppKit

// Shorthands so call sites read `role.lineHeight` rather than `role.spec.lineHeight`. The plain ones are the
// role at Default; the `at:` ones apply a Text size (spec §4.15).
extension QuireFont.Role {
    public var family: QuireFont.Family { spec.family }
    public var size: CGFloat { spec.pointSize }
    public var weight: CGFloat { spec.weight }
    public var lineHeight: CGFloat { spec.resolvedLineHeight }
    public var tracking: CGFloat { spec.tracking }
    public var twin: QuireFont.Role? { spec.twin }
    public var italic: Bool { spec.italic }
    public var tabular: Bool { spec.tabular }
    public var uppercase: Bool { spec.uppercase }

    /// How far this role moves at `textSize` (spec §4.15): the size's step, held where it would take the role below
    /// the 11 pt floor (so at Small an 11 pt role stays as it is), and nothing for the diameter-driven monograms.
    /// Size and line height move together, so a role keeps its leading and a twin keeps sharing its line.
    public func step(at textSize: QuireFont.TextSize) -> CGFloat {
        guard spec.size > 0 else { return 0 }
        let delta = CGFloat(textSize.delta)
        return max(delta, min(0, Quire.Platform.minTextSizePoints - spec.size))
    }

    /// The role's point size at `textSize`.
    public func size(at textSize: QuireFont.TextSize) -> CGFloat { size + step(at: textSize) }

    /// The role's exact line height at `textSize`.
    public func lineHeight(at textSize: QuireFont.TextSize) -> CGFloat { lineHeight + step(at: textSize) }
}
