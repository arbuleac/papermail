import CoreGraphics

/// A drag of the rail's trailing edge (spec §5.2). The rail has two widths, its tiles alone and its tiles with their
/// names, and nothing between: the edge jumps to the other width once the pointer has gone past halfway towards it, and
/// back if the pointer comes back, so a release always leaves one of the two. The decision is here, apart from the
/// split view that follows the mouse (`HairlineSplitView`).
struct RailEdgeDrag: Equatable {
    /// Whether the rail showed its names as the press began.
    var showsNames: Bool
    /// The rail's width with its tiles alone, and with their names.
    var compactWidth: CGFloat
    var namesWidth: CGFloat

    /// Whether the rail shows its names with the pointer `offset` points from where it pressed, counted towards the
    /// wider rail (negative towards the narrower one). Exactly halfway is not past it: the rail stays as it began.
    func showsNames(atOffset offset: CGFloat) -> Bool {
        let half = (namesWidth - compactWidth) / 2
        return showsNames ? offset >= -half : offset > half
    }
}
