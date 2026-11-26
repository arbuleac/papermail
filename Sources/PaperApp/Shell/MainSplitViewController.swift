import AppKit
import PaperDesign

/// The main window's three panes (spec §5.1). Pane dividers are hairlines (`rule`, one device pixel, 1 pt in
/// Increase Contrast) with a 6 pt hit area, so the list's edge, and the rail's (§5.2), is easy to grab without a
/// visible bar.
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

/// A vertical split view whose dividers are Quire hairlines. It tracks the first divider, the rail's edge, itself
/// (§5.2): the rail has one width at a time, the tiles' or the names', and AppKit, which drags a divider between a
/// pane's minimum and maximum, has nowhere to take it. The list's edge stays AppKit's.
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

    // MARK: The rail's edge (§5.2)

    /// The rail's two widths and which it has now, asked as a press on its edge begins and for the edge's pointer;
    /// nil while the rail is hidden or the window shows no rail, when the divider is left to AppKit.
    var railEdgeDrag: (() -> RailEdgeDrag?)?

    /// A drag of the rail's edge went past halfway: the rail shows its names, or its tiles alone again. The drag is
    /// still held and may come back.
    var onRailEdgeDrag: ((_ showsNames: Bool) -> Void)?

    /// The drag was let go: the rail keeps the width it has.
    var onRailEdgeDragEnd: (() -> Void)?

    /// The rail's edge as a press takes it, in this view's coordinates: the hairline between the first two panes with
    /// the grab area the list's edge has, the one AppKit takes a divider by (`dividerGrabRect(after:)`), so no press
    /// beside the hairline is left to AppKit's own drag. Nil while the edge is AppKit's.
    var railEdgeGrabRect: NSRect? {
        guard railEdgeDrag?() != nil else { return nil }
        return dividerGrabRect(after: 0)
    }

    /// The pointer over the rail's edge: it can only go one way from either width.
    static func railEdgeCursor(showsNames: Bool, rightToLeft: Bool = false) -> NSCursor {
        let wider: NSHorizontalDirection.Set = rightToLeft ? .left : .right
        let narrower: NSHorizontalDirection.Set = rightToLeft ? .right : .left
        return NSCursor.columnResize(directions: showsNames ? narrower : wider)
    }

    private var isRailLeading: Bool {
        guard arrangedSubviews.count > 1 else { return true }
        return arrangedSubviews[0].frame.minX <= arrangedSubviews[1].frame.minX
    }

    /// AppKit hands the split view a press on a divider's grown rect; the rail's edge is taken here whatever it thinks
    /// of a divider it cannot move.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if let superview, !isHiddenOrHasHiddenAncestor, let grab = railEdgeGrabRect, grab.contains(convert(point, from: superview)) {
            return self
        }
        return super.hitTest(point)
    }

    /// A press on the rail's edge follows the mouse until it is let go, switching the rail between its two widths as
    /// the pointer passes halfway (`RailEdgeDrag`). Anything else, a double click there included, is AppKit's.
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 1, let window, let drag = railEdgeDrag?(), let grab = railEdgeGrabRect,
              grab.contains(convert(event.locationInWindow, from: nil)) else {
            super.mouseDown(with: event)
            return
        }
        let pressed = convert(event.locationInWindow, from: nil).x
        let towardsWider: CGFloat = isRailLeading ? 1 : -1
        var showsNames = drag.showsNames
        window.trackEvents(matching: [.leftMouseDragged, .leftMouseUp], timeout: NSEvent.foreverDuration, mode: .eventTracking) { event, stop in
            guard let event else {
                stop.pointee = true
                return
            }
            let offset = (self.convert(event.locationInWindow, from: nil).x - pressed) * towardsWider
            let wanted = drag.showsNames(atOffset: offset)
            if wanted != showsNames {
                showsNames = wanted
                self.onRailEdgeDrag?(wanted)
            }
            if event.type == .leftMouseUp { stop.pointee = true }
        }
        onRailEdgeDragEnd?()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isVertical = true
        dividerStyle = .thin
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    /// The dividers' resize pointer is AppKit's own and cannot be cut: under the cheat sheet, whose scrim takes the click
    /// there, it is left out (§4.17). Over the rail's edge AppKit's says where it would take the divider itself (towards
    /// nothing, hiding the rail); that one is dropped as it is added, and the edge shows the way its own drag can go.
    override func resetCursorRects() {
        guard !isUnderPointerCover else { return }
        let edge = railEdgeGrabRect
        systemPointerLeftOut = edge
        super.resetCursorRects()
        systemPointerLeftOut = nil
        if let edge, let drag = railEdgeDrag?() {
            addCursorRect(edge, cursor: Self.railEdgeCursor(showsNames: drag.showsNames, rightToLeft: !isRailLeading))
        }
    }

    /// The rail's edge while AppKit adds its dividers' pointers, so its own for that edge can be told and left out.
    private var systemPointerLeftOut: NSRect?

    override func addCursorRect(_ rect: NSRect, cursor: NSCursor) {
        if let edge = systemPointerLeftOut, rect.intersects(edge) { return }
        super.addCursorRect(rect, cursor: cursor)
    }

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
