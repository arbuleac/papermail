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
private final class HairlineSplitView: NSSplitView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isVertical = true
        dividerStyle = .thin
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var dividerThickness: CGFloat {
        QuireHairline.width(backingScale: window?.backingScaleFactor ?? 2, increasedContrast: QuireEnvironment.increaseContrast)
    }

    override var dividerColor: NSColor { .qRule }

    override func drawDivider(in rect: NSRect) {
        NSColor.qRule.setFill()
        rect.fill()
    }

    @objc private func environmentDidChange(_ note: Notification) {
        adjustSubviews()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        adjustSubviews()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
