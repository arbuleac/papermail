import AppKit
import SSCore
import SSDesign

/// The seven day cells under the column's header (spec §5.54, “Day cells”): the shown day's week, each cell a small
/// track of its busy time in account inks on one scale for the week, so a full day shows without opening the week. A
/// click shows that day; a row dropped on a cell sets aside that day's first free half hour.
@MainActor
final class CalendarDayCellsView: NSView, QuirePointerTarget {
    typealias Pane = Quire.Layout.CalendarPane

    let state: CalendarState
    weak var delegate: CalendarViewDelegate?

    private(set) var days: [Date] = []
    private(set) var cells: [CalendarFit.DayCell] = []
    private var contentVersion = -1
    private var hovered: Int?
    private var pressed: Int?
    private var pressStart: Int?
    private(set) var dropIndex: Int?
    private var trackingArea: NSTrackingArea?
    private var elements: [CalendarDayCellAccessibilityElement] = []

    init(state: CalendarState) {
        self.state = state
        super.init(frame: .zero)
        // Each part fills what it is asked to draw; without the clip that reaches past its bounds onto its neighbours.
        clipsToBounds = true
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        registerForDraggedTypes([MessageListViewController.conversationPasteboardType])
        setAccessibilityElement(true)
        setAccessibilityRole(.tabGroup)
        setAccessibilityLabel("Days")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The week of the shown day, from the state's content for it (its pencil included, for the outline).
    func update() {
        let week = state.shownDayWeek
        let content = state.content(for: week)
        guard week != days || content.version != contentVersion else {
            needsDisplay = true
            return
        }
        days = week
        contentVersion = content.version
        cells = CalendarFit.dayCells(days: week, events: content.events, marks: content.fitMarks, calendar: state.calendar,
                                     metrics: CalendarMetrics.fit)
        needsDisplay = true
        updateToolTips()
        pointerRegionsDidChange()
    }

    // MARK: Geometry

    var cellWidth: CGFloat { max(0, (bounds.width - 2 * Pane.dayCellsInsetX) / 7) }

    func cellRect(_ index: Int) -> NSRect {
        NSRect(x: Pane.dayCellsInsetX + CGFloat(index) * cellWidth, y: Pane.dayCellTop, width: cellWidth, height: Pane.dayCellHeight)
    }

    func index(at point: NSPoint) -> Int? {
        guard !days.isEmpty else { return nil }
        return days.indices.first { cellRect($0).contains(point) }
    }

    private var shownIndex: Int? { days.firstIndex { state.calendar.isDate($0, inSameDayAs: state.shownDay) } }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        dirtyRect.fill()
        let hairline = QuireHairline.width(for: self)
        NSColor.qRule.setFill()
        NSRect(x: 0, y: bounds.height - hairline, width: bounds.width, height: hairline).fill()
        let shown = shownIndex
        let today = state.today
        let isIC = QuireMode(effectiveAppearance).isIncreasedContrast
        for (index, day) in days.enumerated() {
            let rect = cellRect(index)
            guard rect.intersects(dirtyRect) else { continue }
            let isShown = index == shown
            if isShown {
                drawRaised(rect, isIC: isIC)
            } else if pressed == index {
                QuireDraw.fill(rect, radius: Pane.dayCellRadius, .qPressed)
            } else if hovered == index {
                QuireDraw.fill(rect, radius: Pane.dayCellRadius, .qHover)
            }
            let lit = isShown || hovered == index || pressed == index
            drawWords(day, in: rect, lit: lit, isToday: state.calendar.isDate(day, inSameDayAs: today))
            if cells.indices.contains(index) { drawTrack(cells[index], in: rect) }
            if dropIndex == index {
                let ring = rect.insetBy(dx: Pane.dropRing / 2, dy: Pane.dropRing / 2)
                let path = QuireDraw.roundedRect(ring, radius: Pane.dayCellRadius - Pane.dropRing / 2)
                path.lineWidth = Pane.dropRing
                NSColor.qFocus.setStroke()
                path.stroke()
            }
            if isShown, showsFocusRing {
                QuireFocusRing.draw(around: rect, cornerRadius: Pane.dayCellRadius, gap: QuireFocusRing.gap)
            }
        }
    }

    /// The shown day's cell: `raised`, a hairline edge (`ruleStrong` in Increase Contrast) and `e1`.
    private func drawRaised(_ rect: NSRect, isIC: Bool) {
        NSGraphicsContext.saveGraphicsState()
        if let key = Quire.Elevation.e1.key(for: QuireMode(effectiveAppearance)) {
            let shadow = NSShadow()
            shadow.shadowColor = key.color
            shadow.shadowBlurRadius = key.blur
            shadow.shadowOffset = NSSize(width: key.x, height: -key.y)
            shadow.set()
        }
        QuireDraw.fill(rect, radius: Pane.dayCellRadius, .qRaised)
        NSGraphicsContext.restoreGraphicsState()
        QuireDraw.strokeInside(rect, radius: Pane.dayCellRadius,
                               width: isIC ? Quire.Border.IcOutline.width : QuireHairline.width(for: self),
                               isIC ? .qRuleStrong : .qRule)
    }

    /// The weekday over the date, centred; today's date strong and ruled under in `ink`.
    private func drawWords(_ day: Date, in rect: NSRect, lit: Bool, isToday: Bool) {
        let color: NSColor = lit ? .qInk : .qInk3
        let weekday = QuireFont.attributedString(state.text.weekday(day), role: .runningHead, color: color)
        let headHeight = QuireFont.Role.runningHead.lineHeight
        let top = rect.minY + Pane.dayCellTextTop
        let weekdayWidth = CalendarType.width(of: weekday)
        weekday.draw(with: NSRect(x: rect.midX - weekdayWidth / 2, y: top, width: weekdayWidth + 1, height: headHeight),
                     options: QuireFont.drawingOptions, context: nil)
        let dateRole: QuireFont.Role = isToday ? .metaStrong : .meta
        let date = QuireFont.attributedString(state.text.dayNumber(day), role: dateRole, color: isToday ? .qInk : color)
        let dateWidth = CalendarType.width(of: date)
        let dateTop = top + headHeight
        date.draw(with: NSRect(x: rect.midX - dateWidth / 2, y: dateTop, width: dateWidth + 1, height: dateRole.lineHeight),
                  options: QuireFont.drawingOptions, context: nil)
        if isToday {
            // A 2 pt rule under today's date, under its baseline and clear of the track.
            NSColor.qInk.setFill()
            let ruleTop = dateTop + dateRole.lineHeight - Pane.dayCellAllDayLine / 2
            NSRect(x: rect.midX - dateWidth / 2, y: ruleTop, width: dateWidth, height: Pane.dayCellAllDayLine).fill()
        }
    }

    /// The day's busy time on a hairline across the week's open hours, and its first all-day event as a line on top.
    private func drawTrack(_ cell: CalendarFit.DayCell, in rect: NSRect) {
        let track = NSRect(x: rect.minX + Pane.dayCellTrackInsetX, y: rect.maxY - Pane.dayCellTrackBottom - Pane.dayCellTrack,
                           width: rect.width - 2 * Pane.dayCellTrackInsetX, height: Pane.dayCellTrack)
        let hairline = QuireHairline.width(for: self)
        NSColor.qRule.setFill()
        NSRect(x: track.minX, y: (track.midY - hairline / 2).rounded(), width: track.width, height: hairline).fill()
        for segment in cell.segments {
            let bar = NSRect(x: track.minX + CGFloat(segment.start) * track.width, y: track.minY,
                             width: max(Pane.dayCellTrack, CGFloat(segment.width) * track.width), height: track.height)
                .intersection(track)
            if segment.isHollow {
                NSColor.qPaper.setFill()
                QuireDraw.roundedRect(bar, radius: bar.height / 2).fill()
                QuireDraw.strokeInside(bar, radius: bar.height / 2, width: 1, .qRuleStrong)
            } else {
                QuireDraw.fill(bar, radius: bar.height / 2, state.ink(for: segment.accountID))
            }
        }
        if let allDay = cell.allDay {
            state.ink(for: allDay.accountID).setFill()
            NSRect(x: rect.minX + Pane.dayCellRadius, y: rect.minY, width: rect.width - 2 * Pane.dayCellRadius,
                   height: Pane.dayCellAllDayLine).fill()
        }
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) { setHovered(index(at: convert(event.locationInWindow, from: nil))) }
    override func mouseEntered(with event: NSEvent) { setHovered(index(at: convert(event.locationInWindow, from: nil))) }
    override func mouseExited(with event: NSEvent) { setHovered(nil) }

    private func setHovered(_ index: Int?) {
        // Never on the selected cell.
        let index = index == shownIndex ? nil : index
        guard index != hovered else { return }
        redraw(hovered)
        hovered = index
        redraw(index)
    }

    override func mouseDown(with event: NSEvent) {
        pressStart = index(at: convert(event.locationInWindow, from: nil))
        setPressed(pressStart)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressStart else { return }
        setPressed(index(at: convert(event.locationInWindow, from: nil)) == pressStart ? pressStart : nil)
    }

    override func mouseUp(with event: NSEvent) {
        let start = pressStart
        pressStart = nil
        setPressed(nil)
        guard let start, index(at: convert(event.locationInWindow, from: nil)) == start, days.indices.contains(start) else { return }
        delegate?.selectDay(days[start])
    }

    private func setPressed(_ index: Int?) {
        guard index != pressed else { return }
        redraw(pressed)
        pressed = index
        redraw(index)
    }

    private func redraw(_ index: Int?) {
        guard let index, days.indices.contains(index) else { return }
        setNeedsDisplay(cellRect(index).insetBy(dx: -QuireFocusRing.margin - 4, dy: -QuireFocusRing.margin))
    }

    // MARK: Pointer and tooltips

    var pointerRegions: [QuirePointerRegion] {
        days.indices.map { QuirePointerRegion.control(cellRect($0), acts: $0 != shownIndex) }
    }

    override func resetCursorRects() { addPointerRects() }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { updateToolTips(); pointerRegionsDidChange() }
    }

    private func updateToolTips() {
        removeAllToolTips()
        for index in days.indices { addToolTip(cellRect(index), owner: self, userData: nil) }
    }

    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                    userData data: UnsafeMutableRawPointer?) -> String {
        guard let index = index(at: point) else { return "" }
        return "Show " + state.text.shortDay(days[index], now: state.now)
    }

    // MARK: Keyboard

    override var acceptsFirstResponder: Bool { !days.isEmpty }
    override var canBecomeKeyView: Bool { !days.isEmpty && !isHiddenOrHasHiddenAncestor }

    private var showsFocusRing: Bool {
        window?.firstResponder === self && (state.isWindowKey ?? window?.isKeyWindow ?? false)
    }

    override func becomeFirstResponder() -> Bool {
        redraw(shownIndex)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        redraw(shownIndex)
        return super.resignFirstResponder()
    }

    /// ← and → move the shown day, across weeks (spec §5.54, “Keyboard”).
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: delegate?.turnDay(by: -1)
        case 124: delegate?.turnDay(by: 1)
        default: super.keyDown(with: event)
        }
    }

    // MARK: Dropping a row

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { dragMoved(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { dragMoved(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { setDropIndex(nil) }
    override func draggingEnded(_ sender: NSDraggingInfo) { setDropIndex(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setDropIndex(nil) }
        guard let conversation = CalendarDrop.conversation(in: sender),
              let index = index(at: convert(sender.draggingLocation, from: nil)) else { return false }
        delegate?.blockTimeFirstFree(for: conversation, on: days[index])
        return true
    }

    private func dragMoved(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = CalendarDrop.operation(for: sender)
        guard !operation.isEmpty, CalendarDrop.conversation(in: sender) != nil,
              let index = index(at: convert(sender.draggingLocation, from: nil)) else {
            setDropIndex(nil)
            return []
        }
        setDropIndex(index)
        return operation
    }

    private func setDropIndex(_ index: Int?) {
        guard index != dropIndex else { return }
        redraw(dropIndex)
        dropIndex = index
        redraw(index)
    }

    // MARK: Accessibility

    /// The cells as a tab group: “Monday 16 November, 3 events”, the shown one selected.
    override func accessibilityChildren() -> [Any]? {
        let shown = shownIndex
        elements = days.enumerated().map { index, day in
            let count = cells.indices.contains(index) ? cells[index].segments.count + (cells[index].allDay == nil ? 0 : 1) : 0
            let label = state.text.longDay(day) + ", " + (count == 1 ? "1 event" : "\(count) events")
            return CalendarDayCellAccessibilityElement(cells: self, index: index, label: label, isSelected: index == shown)
        }
        return elements
    }

    func select(index: Int) {
        guard days.indices.contains(index) else { return }
        delegate?.selectDay(days[index])
    }
}

/// One day cell for VoiceOver: a tab that shows its day.
@MainActor
final class CalendarDayCellAccessibilityElement: NSAccessibilityElement {
    weak var cells: CalendarDayCellsView?
    let index: Int

    init(cells: CalendarDayCellsView, index: Int, label: String, isSelected: Bool) {
        self.cells = cells
        self.index = index
        super.init()
        setAccessibilityParent(cells)
        setAccessibilityRole(.radioButton)
        setAccessibilitySubrole(.tabButtonSubrole)
        setAccessibilityLabel(label)
        setAccessibilityValue(NSNumber(value: isSelected))
        setAccessibilitySelected(isSelected)
    }

    override func accessibilityFrame() -> NSRect {
        guard let cells, let window = cells.window else { return .zero }
        return window.convertToScreen(cells.convert(cells.cellRect(index), to: nil))
    }

    override func accessibilityPerformPress() -> Bool {
        cells?.select(index: index)
        return true
    }
}
