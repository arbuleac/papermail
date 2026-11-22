import AppKit
import PaperCore
import PaperDesign

/// The day column (spec §5.54): 240 pt at the reader's trailing edge, the window's full height, `paper` with a hairline
/// at its leading edge. Top to bottom: the header on the horizon, the seven day cells, then the shown day fitted to the
/// height with nothing ever scrolling, and the foot while an account's calendar needs connecting.
///
/// The shell places it (in full, or opened over the reader's edge from its strip, `isOverlay`), sets the state's inputs
/// and answers the delegate; the column reads only `CalendarState`.
@MainActor
final class DayColumnView: NSView, CalendarStateObserver {
    typealias Pane = Quire.Layout.CalendarPane

    let state: CalendarState
    weak var delegate: CalendarViewDelegate? {
        didSet {
            header.delegate = delegate
            cells.delegate = delegate
            timeline.delegate = delegate
            foot.delegate = delegate
            details.delegate = delegate
        }
    }

    let header: DayColumnHeaderView
    let cells: CalendarDayCellsView
    let timeline: CalendarTimelineView
    let foot: CalendarFootView
    let details: CalendarDetailsPresenter
    private let edge = CalendarEdgeView()

    /// Opened over the reader's trailing edge from the strip: the same column, with `e2` and an edge (spec §5.54, “The
    /// strip and the column over the reader”).
    var isOverlay = false {
        didSet {
            guard oldValue != isOverlay else { return }
            applyElevation()
            needsDisplay = true
        }
    }

    init(state: CalendarState) {
        self.state = state
        header = DayColumnHeaderView(state: state)
        cells = CalendarDayCellsView(state: state)
        timeline = CalendarTimelineView(style: .column, state: state)
        foot = CalendarFootView(state: state)
        details = CalendarDetailsPresenter(state: state, placement: .leadingOfColumn)
        super.init(frame: NSRect(x: 0, y: 0, width: Pane.columnWidth, height: 600))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        timeline.details = details
        for view in [header, cells, timeline, foot, edge] as [NSView] { addSubview(view) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        state.addObserver(self)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: State

    func calendarState(_ state: CalendarState, didChange change: CalendarChange) {
        if change.contains(.shown) || change.contains(.selection) { details.dismiss() }
        // Nothing is read or fitted for a column no one sees: it catches up when it shows again.
        guard isShowing else { needsReload = true; return }
        if change.contains(.shown) || change.contains(.day) {
            reload()
            return
        }
        if change.contains(.content) {
            // The day is the same: its words stay, and only what is on it is read again.
            cells.update()
            timeline.setContent(state.content(for: [state.shownDay]))
        }
        if change.contains(.statuses) {
            foot.update()
            needsLayout = true
        }
        if change.contains(.now) { timeline.nowDidChange() }
        if change.contains(.windowKey) { timeline.redrawSelection() }
    }

    private var needsReload = false

    /// In a window and not hidden.
    var isShowing: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    /// Everything the column shows, from the state: the header's words, the cells' week, the day's content.
    func reload() {
        guard isShowing else { needsReload = true; return }
        needsReload = false
        let signpost = CalendarSignposts.signposter.beginInterval("calendar.column")
        header.update()
        cells.update()
        foot.update()
        timeline.setContent(state.content(for: [state.shownDay]))
        timeline.nowDidChange()
        setAccessibilityLabel("Day, " + state.text.longDay(state.shownDay))
        needsLayout = true
        CalendarSignposts.signposter.endInterval("calendar.column", signpost)
    }

    /// Closes an open event's details (Esc's row 4, §6.1). Returns whether one was open.
    @discardableResult
    func dismissDetails() -> Bool { details.dismiss() }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        header.frame = NSRect(x: 0, y: 0, width: width, height: Pane.headerHeight)
        cells.frame = NSRect(x: 0, y: Pane.headerHeight, width: width, height: Pane.dayCellsHeight)
        let footHeight = foot.preferredHeight(forWidth: width)
        foot.frame = NSRect(x: 0, y: bounds.height - footHeight, width: width, height: footHeight)
        let top = CalendarMetrics.columnTimelineTop
        timeline.frame = NSRect(x: 0, y: top, width: width, height: max(0, bounds.height - footHeight - top))
        edge.frame = NSRect(x: 0, y: 0, width: Quire.Border.IcOutline.width, height: bounds.height)
    }

    /// The leading hairline over the whole height, drawn last over the parts (`ruleStrong` over the reader in Increase
    /// Contrast).
    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        // The layer never masks to its bounds (the e2 shadow of the column opened over the reader falls outside them), and
        // a view's dirty rect may reach past its bounds: unclipped, the fill would cover the reader beside the column.
        dirtyRect.intersection(bounds).fill()
    }

    private func applyElevation() {
        edge.isOverlay = isOverlay
        guard let layer else { return }
        layer.masksToBounds = false
        if isOverlay, let key = Quire.Elevation.e2.key(for: QuireMode(effectiveAppearance)) {
            key.apply(to: layer, in: self)
        } else {
            layer.shadowOpacity = 0
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyElevation()
    }

    // MARK: Visibility

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { state.clock.unregister(self) } else { state.clock.register(self) }
        if window == nil { details.dismiss() } else if needsReload { reload() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        details.dismiss()
        state.clock.visibilityMayHaveChanged()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        state.clock.visibilityMayHaveChanged()
        reload()
    }

    // MARK: Keyboard

    /// The column's stops for the window's Tab loop (spec §5.54, “Keyboard”): ‹, Today, ›, the day cells as one stop,
    /// the events (one stop that steps through them), the foot's button.
    var keyViews: [NSView] {
        header.keyViews.filter { ($0 as? NSControl)?.isEnabled ?? true } + [cells, timeline] + foot.keyViews
    }
}

/// The column's leading hairline, above its parts: `rule`, or the overlay's edge (`ruleStrong` in Increase Contrast).
@MainActor
final class CalendarEdgeView: NSView {
    var isOverlay = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let isIC = QuireMode(effectiveAppearance).isIncreasedContrast
        let width = isIC && isOverlay ? Quire.Border.IcOutline.width : QuireHairline.width(for: self)
        (isIC && isOverlay ? NSColor.qRuleStrong : .qRule).setFill()
        NSRect(x: 0, y: 0, width: width, height: bounds.height).fill()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}
