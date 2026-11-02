import AppKit
import SSDesign

/// The list's root view: opaque `paper` up to its edges (spec §5.1), and the one place the list hears about
/// appearance changes, which view controllers are not told about.
final class ListPaneBackgroundView: NSView {
    var onAppearanceChange: (() -> Void)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        // Views no longer clip drawing to their bounds by default, and a snapshot's dirty rect can be the
        // whole window: fill only what is ours.
        NSColor.qPaper.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        onAppearanceChange?()
    }
}
