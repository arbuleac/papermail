import CoreGraphics

/// A filled circle of a custom glyph (the nib's vent, the elision dots, the queued dot), in grid units.
public struct QuireGlyphCircle: Equatable, Sendable {
    public let cx: CGFloat
    public let cy: CGFloat
    public let r: CGFloat

    public init(cx: CGFloat, cy: CGFloat, r: CGFloat) {
        self.cx = cx
        self.cy = cy
        self.r = r
    }

    public var rect: CGRect { CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r) }
}
