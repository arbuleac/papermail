import AppKit
import QuartzCore

/// The layer stack behind a floating surface (sheets, cards, slips, popovers): an elevation level as a key
/// shadow on a container layer plus a contact shadow on one sublayer, each with an explicit `shadowPath`
/// (spec §4.8), then the fill and its edge, and the focus ring when asked. Colours are bound through
/// `QuireLayerColors`; shadows and edge widths are re-applied when the appearance, the backing scale or the
/// environment changes. Shadows and the ring extend past the bounds, so the view does not clip.
@MainActor
final class QuireSurfaceView: NSView {
    enum Edge {
        case none
        /// One device pixel, or 1 pt in Increase Contrast.
        case hairline(NSColor)
        case solid(NSColor, width: CGFloat)
    }

    var fillColor: NSColor = .qSheet { didSet { apply() } }
    var cornerRadius: CGFloat = 8 { didSet { apply() } }
    var cornerCurve: CALayerCornerCurve = .circular { didSet { apply() } }
    var elevation: QuireElevationLevel = Quire.Elevation.e0 { didSet { apply() } }
    /// Decides the edge at apply time, so it can depend on Increase Contrast.
    var edge: (QuireMode) -> Edge = { _ in .none } { didSet { apply() } }
    /// A focus ring outside the surface, in this colour, when set.
    var ringColor: NSColor? { didSet { apply() } }
    var ringGap: CGFloat = QuireFocusRing.gapAroundSheet { didSet { apply() } }

    private let keyShadow = CALayer()
    private let contactShadow = CALayer()
    private let surface = CALayer()
    private let ring = CAShapeLayer()
    private var colors: QuireLayerColors!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        clipsToBounds = false
        colors = QuireLayerColors(view: self)
        ring.fillColor = nil
        keyShadow.addSublayer(contactShadow)
        layer?.addSublayer(keyShadow)
        layer?.addSublayer(surface)
        layer?.addSublayer(ring)
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
        apply()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        apply()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        apply()
    }

    @objc private func environmentDidChange(_ note: Notification) {
        apply()
    }

    /// The mode the surface draws in: its own appearance, Increase Contrast from the environment (or the
    /// thread's forced mode inside `QuireMode.performAsCurrent`).
    var mode: QuireMode { QuireMode(effectiveAppearance) }

    func apply() {
        guard let colors else { return }
        let mode = self.mode
        let rect = bounds
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [keyShadow, contactShadow, surface] {
            layer.frame = rect
        }
        contactShadow.frame = keyShadow.bounds
        keyShadow.shadowPath = path
        contactShadow.shadowPath = path
        let layers = elevation.layers(for: mode)
        for (index, layer) in [keyShadow, contactShadow].enumerated() {
            if index < layers.count {
                layers[index].apply(to: layer, in: self)
            } else {
                layer.shadowOpacity = 0
            }
        }
        surface.cornerRadius = radius
        surface.cornerCurve = cornerCurve
        colors.set(fillColor, for: \CALayer.backgroundColor, of: surface)
        // The shadow layers carry the fill too, hidden under the surface: layer snapshots (cacheDisplay,
        // render(in:)) skip the shadow of a layer with no content, even with a shadow path.
        for layer in [keyShadow, contactShadow] {
            layer.cornerRadius = radius
            layer.cornerCurve = cornerCurve
            colors.set(fillColor, for: \CALayer.backgroundColor, of: layer)
        }
        switch edge(mode) {
        case .none:
            surface.borderWidth = 0
            colors.set(nil, for: \CALayer.borderColor, of: surface)
        case .hairline(let color):
            surface.borderWidth = QuireHairline.width(backingScale: window?.backingScaleFactor ?? 2, increasedContrast: mode.isIncreasedContrast)
            colors.set(color, for: \CALayer.borderColor, of: surface)
        case .solid(let color, let width):
            surface.borderWidth = width
            colors.set(color, for: \CALayer.borderColor, of: surface)
        }
        if let ringColor {
            let width = QuireFocusRing.width(increasedContrast: mode.isIncreasedContrast)
            ring.isHidden = false
            ring.frame = rect
            ring.path = QuireFocusRing.path(around: rect, cornerRadius: radius, gap: ringGap, width: width)
            ring.lineWidth = width
            colors.set(ringColor, for: \CAShapeLayer.strokeColor, of: ring)
        } else {
            ring.isHidden = true
        }
        CATransaction.commit()
    }

    /// Resolved values, for tests and snapshots.
    var resolvedFill: CGColor? { surface.backgroundColor }
    var resolvedEdge: (color: CGColor?, width: CGFloat) { (surface.borderColor, surface.borderWidth) }
    var resolvedShadowOpacity: Float { keyShadow.shadowOpacity }
    var resolvedShadowOffsets: [CGSize] { [keyShadow.shadowOffset, contactShadow.shadowOffset] }
    var isRingShown: Bool { !ring.isHidden }
}
