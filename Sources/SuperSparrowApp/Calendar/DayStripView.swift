import AppKit
import SSCore
import SSDesign

/// The day column folded to 28 pt while the window is too narrow for it beside a 400 pt reader (spec §5.54, “The
/// strip and the column over the reader”): `canvas`, its leading hairline kept, `calendar` on the horizon line and, on
/// the column's own fit of the same day, the day's busy events as 8 pt bars in their inks, the selected conversation's
/// outlined, the now line and the selected mail's time. A click (or D) opens the whole column over the reader's edge.
@MainActor
final class DayStripView: NSView, CalendarStateObserver, QuirePointerTarget {
    typealias Pane = Quire.Layout.CalendarPane

    struct Bar: Equatable {
        var rect: NSRect
        var accountID: AccountID
        var isHollow: Bool
        var isSelected: Bool
    }

    let state: CalendarState
    weak var delegate: CalendarViewDelegate?

    /// The column is open over the reader: the strip stays `canvas + pressed`.
    var isOpen = false {
        didSet {
            guard oldValue != isOpen else { return }
            toolTip = isOpen ? "Hide Day  D" : "Show Day  D"
            needsDisplay = true
        }
    }

    private(set) var bars: [Bar] = []
    private(set) var nowY: CGFloat?
    private(set) var mailTimeYs: [CGFloat] = []
    private var fit: CalendarFit?
    private var fitKey: (version: Int, days: [Date], size: NSSize)?
    private var content = CalendarContent.empty
    private var isHovered = false
    private var isPressed = false
    private var trackingArea: NSTrackingArea?

    init(state: CalendarState) {
        self.state = state
        super.init(frame: NSRect(x: 0, y: 0, width: Pane.stripWidth, height: 600))
        // Each part fills what it is asked to draw; without the clip that reaches past its bounds onto its neighbours.
        clipsToBounds = true
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        toolTip = "Show Day  D"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        state.addObserver(self)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func calendarState(_ state: CalendarState, didChange change: CalendarChange) {
        guard isShowing else { needsReload = true; return }
        if change.contains(.content) || change.contains(.shown) || change.contains(.day) || change.contains(.statuses) {
            reload()
        } else if change.contains(.now) {
            placeNow()
        } else if change.contains(.windowKey) {
            needsDisplay = true
        }
    }

    private var needsReload = false

    /// In a window and not hidden: a strip no one sees reads nothing.
    var isShowing: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    func reload() {
        guard isShowing else { needsReload = true; return }
        needsReload = false
        content = state.content(for: [state.shownDay])
        refit()
        let count = content.events.filter { !$0.isAllDay }.count + content.events.filter(\.isAllDay).count
        setAccessibilityLabel("Day, " + state.text.longDay(state.shownDay) + ", " + (count == 1 ? "1 event" : "\(count) events"))
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { refit() }
    }

    /// The column's own fit for the day, at the height its timeline would have, so a bar sits where the event would.
    private func refit() {
        let footHeight = CalendarFootView.preferredHeight(for: state, width: Pane.columnWidth)
        let height = bounds.height - CalendarMetrics.columnTimelineTop - footHeight - Pane.bottomPad
        let size = NSSize(width: CalendarMetrics.columnFitWidth, height: max(0, height))
        if let fitKey, fitKey.version == content.version, fitKey.days == content.days, fitKey.size == size { placeNow(); return }
        fitKey = (content.version, content.days, size)
        guard size.height > 0, !content.days.isEmpty else {
            fit = nil
            bars = []
            needsDisplay = true
            return
        }
        let fit = CalendarFit(days: content.days, events: content.events, marks: content.fitMarks, height: Double(size.height),
                              width: Double(size.width), calendar: state.calendar, metrics: CalendarMetrics.fit)
        self.fit = fit
        let top = CalendarMetrics.columnTimelineTop + CGFloat(fit.allDayHeight)
        let x = (bounds.width - Pane.stripBarWidth) / 2
        bars = fit.items.filter { $0.event.isBusy || CalendarFit.isPencil($0.event) }.map { item in
            let face = CalendarMetrics.face(x: x, width: Pane.stripBarWidth, top: top + CGFloat(item.top), height: CGFloat(item.height))
            return Bar(rect: face, accountID: item.event.accountID,
                       isHollow: item.event.response == .needsAction || CalendarFit.isPencil(item.event),
                       isSelected: content.selectedEventIDs.contains(item.event.id))
        }
        mailTimeYs = fit.marks.compactMap { placed in
            content.mark(withID: placed.id)?.isMailTime == true ? (top + CGFloat(placed.y)).rounded() : nil
        }
        placeNow()
        needsDisplay = true
    }

    private func placeNow() {
        let previous = nowY
        if let fit, let located = fit.locate(state.now) {
            nowY = (CalendarMetrics.columnTimelineTop + CGFloat(fit.allDayHeight) + CGFloat(fit.y(forMinute: located.minute))).rounded()
        } else {
            nowY = nil
        }
        guard previous != nowY else { return }
        for y in [previous, nowY].compactMap({ $0 }) {
            setNeedsDisplay(NSRect(x: 0, y: y - 4, width: bounds.width, height: 8))
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qCanvas.setFill()
        dirtyRect.fill()
        if isOpen || isPressed {
            NSColor.qPressed.setFill()
            dirtyRect.fill(using: .sourceOver)
        } else if isHovered {
            NSColor.qHover.setFill()
            dirtyRect.fill(using: .sourceOver)
        }
        NSColor.qRule.setFill()
        NSRect(x: 0, y: 0, width: QuireHairline.width(for: self), height: bounds.height).fill()
        let glyph = Quire.Layout.ReaderHeader.kickerCenterY
        QuireSymbol.draw(Quire.Icon.dayColumn, size: .custom(Pane.stripGlyph), color: isHovered || isOpen ? .qInk : .qInk2,
                         centredIn: NSRect(x: 0, y: glyph - Pane.stripGlyph / 2, width: bounds.width, height: Pane.stripGlyph))
        let isKey = state.isWindowKey ?? window?.isKeyWindow ?? false
        for bar in bars where bar.rect.insetBy(dx: -2, dy: -2).intersects(dirtyRect) {
            let radius = Quire.Radius.xs
            if bar.isHollow {
                QuireDraw.fill(bar.rect, radius: radius, .qCanvas)
                QuireDraw.strokeInside(bar.rect, radius: radius, width: 1, .qRuleStrong)
            } else {
                QuireDraw.fill(bar.rect, radius: radius, state.ink(for: bar.accountID))
            }
            if bar.isSelected {
                let outline = bar.rect.insetBy(dx: -1.5, dy: -1.5)
                let path = QuireDraw.roundedRect(outline, radius: radius + 1.5)
                path.lineWidth = 1
                (isKey ? NSColor.qSelRule : .qSelRuleIdle).setStroke()
                path.stroke()
            }
        }
        let inset = Pane.stripLineInset
        for y in mailTimeYs {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: inset, y: y))
            path.line(to: NSPoint(x: bounds.width - inset, y: y))
            path.lineWidth = Pane.mentionLine
            path.setLineDash(Pane.markDash, count: Pane.markDash.count, phase: 0)
            NSColor.qAccent.setStroke()
            path.stroke()
        }
        if let nowY {
            NSColor.qInk.setFill()
            NSRect(x: inset, y: nowY - Pane.nowLineWidth / 2, width: bounds.width - 2 * inset, height: Pane.nowLineWidth).fill()
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; needsDisplay = true }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        if inside != isPressed { isPressed = inside; needsDisplay = true }
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        needsDisplay = true
        if inside { delegate?.openStrip() }
    }

    override func accessibilityPerformPress() -> Bool {
        delegate?.openStrip()
        return true
    }

    // MARK: Pointer and visibility

    var pointerRegions: [QuirePointerRegion] { [.control(bounds, acts: true)] }

    override func resetCursorRects() { addPointerRects() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { state.clock.unregister(self) } else { state.clock.register(self) }
        if window != nil, needsReload { reload() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        state.clock.visibilityMayHaveChanged()
        pointerRegionsDidChange()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        state.clock.visibilityMayHaveChanged()
        pointerRegionsDidChange()
        reload()
    }
}
