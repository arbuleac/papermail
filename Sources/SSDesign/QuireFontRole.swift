import AppKit

// Shorthands so call sites read `role.lineHeight` rather than `role.spec.lineHeight`.
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
}
