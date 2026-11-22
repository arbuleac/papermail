import AppKit
import PaperDesign

/// The reading column the reader header, the sheets and the quick-reply field share (spec §5.12): x =
/// max(margin, (reader width − 680) / 2), the margin 32 pt, or 16 pt when the reader is narrower than 560 pt.
/// The shell's CSS computes the same column for the sheets, so the three line up.
enum ReaderColumn {
    static func margin(readerWidth: CGFloat) -> CGFloat {
        readerWidth < Quire.Layout.Window.readerNarrow ? Quire.Layout.Reader.narrowColumnMargin : Quire.Layout.Reader.columnMinMargin
    }

    /// The column's leading x and width inside a reader `readerWidth` wide.
    static func frame(readerWidth: CGFloat) -> (x: CGFloat, width: CGFloat) {
        let margin = margin(readerWidth: readerWidth)
        let x = max(margin, ((readerWidth - Quire.Layout.Reader.columnMax) / 2).rounded(.down))
        return (x, max(0, min(Quire.Layout.Reader.columnMax, readerWidth - 2 * margin)))
    }

    /// The reader's keycaps (the quick reply's R and ⌘↩, the strip's ⌘Z, the target's R · A · F) hide below
    /// 616 pt (spec §5.36).
    static func showsKeycaps(readerWidth: CGFloat) -> Bool {
        readerWidth >= Quire.Layout.Window.readerKeycapsMin
    }
}
