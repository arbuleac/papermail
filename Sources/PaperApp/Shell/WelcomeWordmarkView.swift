import AppKit
import PaperDesign

/// The wordmark under the welcome screen's mark (spec §5.39): the brand's drawn word (`layout.brand.wordmark`, the
/// outlines of docs/brand/source/wordmark.svg), never the name set in a font, in the brand's ink (paper in dark,
/// `WelcomeBrandInk`) with its cap height `welcome.wordmarkCap`. The frame runs from the cap height to the descender (the straight-edged letters have no
/// overshoot), its baseline on a whole point so the caps and the baseline stay crisp, and the word's ink is centred across it.
@MainActor
final class WelcomeWordmarkView: NSView {
    /// Wordmark units, baseline y 0, y down, as the master is drawn. The data is generated and the drift tests hold it to
    /// tokens.json, so a parse failure is a build defect rather than something to draw around.
    private static let outline: CGPath = {
        do {
            return try QuireSVGPath.parse(Quire.Layout.Brand.Wordmark.path)
        } catch {
            assertionFailure("layout.brand.wordmark: \(error)")
            return CGMutablePath()
        }
    }()

    /// Points per wordmark unit.
    static var scale: CGFloat { Quire.Layout.Welcome.wordmarkCap / Quire.Layout.Brand.capHeight }

    /// The baseline below the frame's top: the cap height, rounded up to a whole point.
    static var baseline: CGFloat { ceil(-Quire.Layout.Brand.Wordmark.top * scale) }

    /// The word's ink in wordmark units.
    static var ink: CGRect { outline.boundingBoxOfPath }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Paper")
    }

    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(Self.ink.width * Self.scale), height: Self.baseline + ceil(Quire.Layout.Brand.Wordmark.bottom * Self.scale))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scale = Self.scale, ink = Self.ink
        context.saveGState()
        context.translateBy(x: (bounds.width - ink.width * scale) / 2 - ink.minX * scale, y: Self.baseline)
        context.scaleBy(x: scale, y: scale)
        // Set through NSColor so ink or paper resolves for this view's appearance.
        WelcomeBrandInk.color.setFill()
        context.addPath(Self.outline)
        // Outer contours run one way and counters the other, so nonzero leaves the counters open.
        context.fillPath(using: .winding)
        context.restoreGState()
    }
}
