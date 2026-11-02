import CoreGraphics

/// Where undo-send panels sit (spec §5.31), in screen coordinates (y grows upward). The panel's visual frame
/// (the 280 × 52 slip) is inset `inset` from the anchor's bottom-trailing corner, lifted above the quick reply
/// when one shows, and every older live panel pushes it up by its height plus `stackGap`. The window is the
/// visual frame grown by the shadow margins, so the `e3` shadow is never clipped.
public enum UndoSendPanelGeometry {
    public struct Margins: Equatable, Sendable {
        public var top: CGFloat
        public var side: CGFloat
        public var bottom: CGFloat

        public init(top: CGFloat, side: CGFloat, bottom: CGFloat) {
            self.top = top
            self.side = side
            self.bottom = bottom
        }
    }

    /// The slip's frame for the panel at `slot` (0 = the lowest).
    public static func visualFrame(anchor: CGRect, bottomClearance: CGFloat, slot: Int, size: CGSize, inset: CGFloat,
                                   stackGap: CGFloat) -> CGRect {
        CGRect(x: anchor.maxX - inset - size.width,
               y: anchor.minY + inset + max(0, bottomClearance) + CGFloat(max(0, slot)) * (size.height + stackGap),
               width: size.width, height: size.height)
    }

    /// The transparent window around a slip.
    public static func windowFrame(visual: CGRect, margins: Margins) -> CGRect {
        CGRect(x: visual.minX - margins.side, y: visual.minY - margins.bottom,
               width: visual.width + 2 * margins.side, height: visual.height + margins.top + margins.bottom)
    }
}
