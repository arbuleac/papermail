import AppKit
import PaperDesign

/// The list's focus ring when Full Keyboard Access is on and nothing is selected (spec §4.1): drawn inset by
/// 2 pt over the rows, because the rows themselves are opaque and would cover a ring the table drew. With a
/// selection the selection is the focus and this draws nothing. It never takes a click.
final class ListFocusRingOverlay: NSView {
    var isShowing = false {
        didSet { if oldValue != isShowing { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard isShowing else { return }
        QuireFocusRing.drawInset(in: bounds.insetBy(dx: 2, dy: 2), cornerRadius: 0)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}
