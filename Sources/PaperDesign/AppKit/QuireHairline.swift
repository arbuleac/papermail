import AppKit

/// A hairline (spec §4.7): one device pixel (`1 / backingScaleFactor`, 0.5 pt on Retina) in `rule`, or 1 pt
/// in Increase Contrast (`border.hairline.widthHC`). Row separators, pane dividers, header bottoms and sheet
/// edges use it.
///
/// The view is 1 pt thick and draws the line flush with one edge of its bounds (the bottom or trailing edge
/// by default, so a header's bottom hairline lands on the horizon). Views that draw their own separators in
/// `draw(_:)` use the static `width(…)` and `fill(…)`.
@MainActor
public final class QuireHairline: NSView {
    public var orientation: Orientation {
        didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
    }

    public var color: NSColor = .qRule {
        didSet { needsDisplay = true }
    }

    /// Draw flush with the bottom (horizontal) or right (vertical) edge; false draws at the top or left.
    public var alignsToMaxEdge = true {
        didSet { needsDisplay = true }
    }

    public init(_ orientation: Orientation = .horizontal, color: NSColor = .qRule) {
        self.orientation = orientation
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: orientation == .horizontal ? 100 : 1, height: orientation == .horizontal ? 1 : 100))
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("QuireHairline is built in code") }

    public override var isFlipped: Bool { true }

    public override var intrinsicContentSize: NSSize {
        orientation == .horizontal
            ? NSSize(width: NSView.noIntrinsicMetric, height: 1)
            : NSSize(width: 1, height: NSView.noIntrinsicMetric)
    }

    /// The hairline width for a backing scale: one device pixel, or 1 pt in Increase Contrast.
    public static func width(backingScale: CGFloat, increasedContrast: Bool) -> CGFloat {
        increasedContrast ? Quire.Border.Hairline.widthHC : 1 / max(1, backingScale)
    }

    /// The hairline width for `view`'s window (2× when it has none yet) under the current drawing mode.
    public static func width(for view: NSView) -> CGFloat {
        width(backingScale: view.window?.backingScaleFactor ?? 2, increasedContrast: QuireDraw.isIncreasedContrast)
    }

    /// Fills a hairline along one edge of `rect` in the current context: the bottom edge for horizontal lines,
    /// the trailing edge for vertical ones (top or leading with `atMaxEdge` false).
    public static func fill(along rect: NSRect, orientation: Orientation, width: CGFloat, color: NSColor = .qRule,
                            atMaxEdge: Bool = true, flipped: Bool = true) {
        color.setFill()
        switch orientation {
        case .horizontal:
            // "Max edge" means the bottom edge, which is maxY in a flipped view and minY otherwise.
            let y = atMaxEdge == flipped ? rect.maxY - width : rect.minY
            NSRect(x: rect.minX, y: y, width: rect.width, height: width).fill()
        case .vertical:
            let x = atMaxEdge ? rect.maxX - width : rect.minX
            NSRect(x: x, y: rect.minY, width: width, height: rect.height).fill()
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        QuireHairline.fill(along: bounds, orientation: orientation, width: QuireHairline.width(for: self),
                           color: color, atMaxEdge: alignsToMaxEdge, flipped: isFlipped)
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    @objc private func environmentDidChange(_ note: Notification) {
        needsDisplay = true
    }

    public override func isAccessibilityElement() -> Bool { false }
}
