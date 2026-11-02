import CoreGraphics

extension QuireSkeleton {
    /// What a skeleton view draws (spec §5.10, `layout.skeleton`, `layout.rowCompact.skeleton*`).
    public enum Layout: Equatable, Sendable {
        /// One bar filling the view, radius 3.
        case bar
        /// One circle filling the view (the shorter side).
        case circle
        /// A 68 pt list row: a 30 pt circle and the sender, time, subject and snippet bars. `index` picks the
        /// row's widths from the fixed jitter table.
        case row(index: Int)
        /// A 48 pt compact row: sender, time and line-2 bars, no circle.
        case compactRow(index: Int)
        /// A body not cached yet: three 10 pt bars 14 pt apart at 1 / 0.92 / 0.6 of the width.
        case body
    }
}
