import AppKit
import SSDesign

/// The main window's three panes (spec §5.1). Pane dividers are hairlines (`rule`, one device pixel, 1 pt in
/// Increase Contrast) with a 6 pt hit area, so the list's edge is easy to grab without a visible bar.
@MainActor
final class MainSplitViewController: NSSplitViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
        // Before the view loads, so the autosave name and the items land on this split view.
        splitView = HairlineSplitView()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect,
                            ofDividerAt dividerIndex: Int) -> NSRect {
        let rect = super.splitView(splitView, effectiveRect: proposedEffectiveRect, forDrawnRect: drawnRect, ofDividerAt: dividerIndex)
        let grow = max(0, (Quire.Layout.Window.dividerHit - drawnRect.width) / 2)
        return rect.insetBy(dx: -grow, dy: 0)
    }
}

/// A vertical split view whose dividers are Quire hairlines.
@MainActor
final class HairlineSplitView: NSSplitView {
    /// Tests stand in for a display of another scale; nil reads the window's (or, before there is one, the
    /// main screen's).
    var backingScaleOverride: CGFloat? {
        didSet { thicknessMayHaveChanged() }
    }

    /// The thickness NSSplitViewController last built its divider constraints for; nil until it is known.
    private var builtThickness: CGFloat?

    /// Called after the divider thickness changed; the rail's hairline is part of its width, so the window
    /// sizes the rail's item again.
    var onThicknessChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isVertical = true
        dividerStyle = .thin
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    /// One device pixel. The split controller's items are added before the view is in a window, so the main
    /// screen's scale is the best guess then; guessing 2 on a 1× display laid out a half-point divider that
    /// pixel rounding then dropped, and the list ran straight into the reader.
    override var dividerThickness: CGFloat {
        let scale = backingScaleOverride ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        return QuireHairline.width(backingScale: scale, increasedContrast: QuireEnvironment.increaseContrast)
    }

    override var dividerColor: NSColor { .qRule }

    override func drawDivider(in rect: NSRect) {
        NSColor.qRule.setFill()
        rect.fill()
    }

    /// NSSplitViewController builds its divider constraints from `dividerThickness` once, when its items are
    /// set, and `adjustSubviews` does not rebuild them; changing the divider style does. So whenever the
    /// thickness may differ (a window of another scale, Increase Contrast), the style is set again.
    private func thicknessMayHaveChanged() {
        let thickness = dividerThickness
        if thickness != builtThickness {
            builtThickness = thickness
            let style = dividerStyle
            dividerStyle = style == .thin ? .thick : .thin
            dividerStyle = style
            onThicknessChange?()
            adjustSubviews()
        }
        needsDisplay = true
    }

    @objc private func environmentDidChange(_ note: Notification) {
        thicknessMayHaveChanged()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { thicknessMayHaveChanged() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        thicknessMayHaveChanged()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
