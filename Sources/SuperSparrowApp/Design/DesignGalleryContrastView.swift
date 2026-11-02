import AppKit

/// A container drawn in the increased-contrast variant of whatever appearance it sits in (Light becomes
/// Light IC, Dark becomes Dark IC), so one card can show `lightHC` / `darkHC` beside the normal page without
/// turning on Increase Contrast for the whole app. Quire resolves colours and ring widths from the drawing
/// appearance, which this pins; the few metrics that read `QuireEnvironment` (hairline widths) stay normal.
@MainActor
final class DesignGalleryContrastView: NSView {
    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pinAppearance()
    }

    /// Re-pins after the page's own appearance changes; a pinned view hears nothing from above.
    func pinAppearance() {
        let base = superview?.effectiveAppearance ?? window?.effectiveAppearance ?? NSApp.effectiveAppearance
        let dark = base.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        appearance = NSAppearance(named: dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
    }
}
