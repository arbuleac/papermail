import AppKit

/// A plain container with a top-left origin, so content laid out from Quire metrics (y from the top) needs no
/// conversion.
@MainActor
final class QuireFlippedView: NSView {
    override var isFlipped: Bool { true }
}
