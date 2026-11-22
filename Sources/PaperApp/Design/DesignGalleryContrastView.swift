#if DEBUG
import AppKit
import PaperDesign

/// Shows a card in the increased-contrast variant of the appearance it sits in (Light becomes Light IC, Dark
/// becomes Dark IC) without turning on Increase Contrast for the whole app.
///
/// An appearance cannot carry the contrast (`NSAppearance(named: .accessibilityHighContrastAqua)` resolves as
/// plain Aqua), so the card is built fresh and rendered off screen by `QuireOffscreenRenderer` with Increase
/// Contrast forced. This view shows that image and renders it again when its own appearance flips between
/// light and dark.
@MainActor
final class DesignGalleryContrastView: NSView {
    private let makeCard: @MainActor () -> NSView
    private var image: NSBitmapImageRep?
    private var renderedMode: QuireMode?

    init(size: NSSize, makeCard: @escaping @MainActor () -> NSView) {
        self.makeCard = makeCard
        super.init(frame: NSRect(origin: .zero, size: size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// The mode the card is rendered in for this view's appearance.
    var mode: QuireMode {
        effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .darkHC : .lightHC
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refresh()
    }

    /// Renders the card again if the appearance it sits in changed since the last render.
    func refresh() {
        guard let window else { return }
        let mode = self.mode
        guard image == nil || renderedMode != mode else { return }
        renderedMode = mode
        image = Self.render(mode: mode, scale: window.backingScaleFactor, makeCard: makeCard)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        image?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    /// A card built and drawn in `mode` with Increase Contrast forced, at `scale`, pinned to the key-window look.
    static func render(mode: QuireMode, scale: CGFloat, makeCard: () -> NSView) -> NSBitmapImageRep? {
        QuireOffscreenRenderer.render(mode: mode, scale: scale) {
            let card = makeCard()
            DesignGallerySamples.pinKeyWindow(in: card)
            return card
        }
    }
}
#endif
