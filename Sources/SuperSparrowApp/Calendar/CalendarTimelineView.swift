import AppKit
import SSCore
import SSDesign

/// The fitted hours of one day (the column) or seven (the week), with the all-day band above them (spec §5.54): the
/// hour gutter, the open hours and the folds, the events in their accounts' inks, the marks, the now line and a drop's
/// ghost. Everything is placed by `CalendarFit` and drawn in `draw(_:)`; a change redraws only what it touched (a
/// hover the two faces, a minute the now line's band), and only new content or a new size refits.
///
/// Coordinates are flipped: the all-day band starts at the top, the hours under it, and the bottom pad (10 pt) is
/// left empty.
@MainActor
final class CalendarTimelineView: NSView, QuirePointerTarget {
    typealias Pane = Quire.Layout.CalendarPane

    /// An event as drawn: a timed part from the fit, or an all-day chip.
    struct Placed {
        var event: CalendarEvent
        var face: NSRect
        var dayIndex: Int
        /// The fit's item, for a timed part.
        var item: CalendarFit.Item?
        /// Hidden all-day events behind “+N” on this chip.
        var overflow: Int

        var isAllDay: Bool { item == nil }
    }

    /// A mark as drawn: its line across the day and its chip.
    struct PlacedMark {
        var mark: CalendarMark
        var dayIndex: Int
        var lineY: CGFloat
        var lineX: ClosedRange<CGFloat>
        var chip: NSRect
    }

    /// What a point is over, topmost first.
    enum Target: Equatable {
        case event(String)
        case mark(String)
    }

    let style: CalendarTimelineStyle
    let state: CalendarState
    weak var delegate: CalendarViewDelegate?
    /// Shows an event's (or a mark's) details beside it.
    var details: CalendarDetailsPresenter?
    /// Asked before a click acts; true takes the click (the week brings back its invitation card).
    var willActivate: ((Target) -> Bool)?

    private(set) var content = CalendarContent.empty
    private(set) var fit: CalendarFit?
    /// What the fit was made from: a new version, other days (a turn within the observed range keeps the version) or a
    /// new size refits.
    private var fitSize: NSSize = .zero
    private var fitVersion = -1
    private var fitDays: [Date] = []
    private(set) var placed: [Placed] = []
    private(set) var placedMarks: [PlacedMark] = []
    /// The now line's y, nil when today is not shown.
    private(set) var nowY: CGFloat?
    private var nowDayIndex: Int?

    private var hovered: Target?
    private var pressed: Target?
    private var pressStart: Target?
    /// The event whose details are open: it keeps its hover look.
    var detailsEventID: String? {
        didSet { if oldValue != detailsEventID { invalidate(events: [oldValue, detailsEventID]); updateJoin() } }
    }
    /// The event the keyboard is on, by its index in `focusOrder`.
    private var focusIndex: Int?
    private var ghost: (face: NSRect, label: String)?
    private var dropConversation: ConversationID?
    private let join = QuireButton(title: "Join", variant: .primary, size: .small, symbolName: Quire.Icon.joinCall)
    private var joinEventID: String?
    private var trackingArea: NSTrackingArea?
    private var accessibilityElements: [NSAccessibilityElement] = []
    private var accessibilityVersion = -1

    init(style: CalendarTimelineStyle, state: CalendarState) {
        self.style = style
        self.state = state
        super.init(frame: .zero)
        // Each part fills what it is asked to draw; without the clip that reaches past its bounds onto its neighbours.
        clipsToBounds = true
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        join.isHidden = true
        join.target = self
        join.action = #selector(joinClicked(_:))
        addSubview(join)
        registerForDraggedTypes([MessageListViewController.conversationPasteboardType])
        setAccessibilityElement(true)
        setAccessibilityRole(style == .column ? .list : .group)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    // MARK: Content

    /// The fit's days: the column's one or the week's seven.
    var days: [Date] { content.days }

    /// New content from the state: refits when it moved.
    func setContent(_ content: CalendarContent) {
        guard content.version != self.content.version || content.days != self.content.days else { return }
        self.content = content
        refit()
    }

    /// The minute moved: the now line's old and new bands, and the next call's Join.
    func nowDidChange() {
        // The hour holding now stays open on today (§5.54, Fit), so a new hour may unfold: fit again, once an hour.
        if nowHourStart() != fittedNowHour {
            fitVersion = -1
            refit()
            return
        }
        let previous = nowY
        placeNow()
        if previous != nowY {
            invalidateNow(at: previous)
            invalidateNow(at: nowY)
        }
        updateJoin()
    }

    /// Today changed, or the window's key state: redraw what follows it.
    func redrawSelection() {
        invalidate(events: Array(content.selectedEventIDs))
        updateJoin()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { refit() }
    }

    /// The height the fit lays the all-day band and the hours in: the bounds less the bottom pad.
    var fitHeight: CGFloat { max(0, bounds.height - Pane.bottomPad) }

    var fitWidth: CGFloat { max(0, bounds.width - style.gutter - style.trailingPad) }

    /// The top of the hours, under the all-day band.
    var hoursTop: CGFloat { CGFloat(fit?.allDayHeight ?? 0) }

    /// The start of now's hour when today is among the days shown; nil otherwise.
    private func nowHourStart() -> Date? {
        let calendar = state.calendar
        guard content.days.contains(where: { calendar.isDate($0, inSameDayAs: state.now) }) else { return nil }
        return calendar.dateInterval(of: .hour, for: state.now)?.start
    }

    private var fittedNowHour: Date?

    private func refit() {
        let size = NSSize(width: fitWidth, height: fitHeight)
        guard !content.days.isEmpty, size.width > 0, size.height > 0 else {
            fit = nil
            placed = []
            focusOrder = []
            placedMarks = []
            nowY = nil
            needsDisplay = true
            return
        }
        guard fitVersion != content.version || fitSize != size || fitDays != content.days else { return }
        fitVersion = content.version
        fitSize = size
        fitDays = content.days
        // Now opens its hour on today, as a mark would: at 19:57 the evening never folds the now line away.
        fittedNowHour = nowHourStart()
        var marks = content.fitMarks
        if let hour = fittedNowHour { marks.append(CalendarFit.Mark(id: "now", start: hour, span: 3600)) }
        let signpost = CalendarSignposts.signposter.beginInterval("calendar.fit")
        fit = CalendarFit(days: content.days, events: content.events, marks: marks, height: Double(size.height),
                          width: Double(size.width), calendar: state.calendar, metrics: CalendarMetrics.fit)
        CalendarSignposts.signposter.endInterval("calendar.fit", signpost)
        place()
        needsDisplay = true
        pointerRegionsDidChange()
        updateToolTips()
        if let focusIndex, focusIndex >= focusOrder.count { self.focusIndex = focusOrder.isEmpty ? nil : focusOrder.count - 1 }
        NSAccessibility.post(element: self, notification: .layoutChanged)
    }

    /// The x of day `index`'s leading edge.
    func dayX(_ index: Int) -> CGFloat {
        guard let fit, fit.days.indices.contains(index) else { return style.gutter }
        return style.gutter + CGFloat(fit.days[index].x)
    }

    func dayWidth(_ index: Int) -> CGFloat {
        guard let fit, fit.days.indices.contains(index) else { return 0 }
        return CGFloat(fit.days[index].width)
    }

    /// Lays out the faces, the chips and the marks from the fit.
    private func place() {
        guard let fit else { return }
        var placed: [Placed] = []
        placed.reserveCapacity(fit.items.count + 4)
        for item in fit.items where !item.isHidden {
            let slot = CalendarMetrics.slot(column: item.column, of: item.columnCount, dayX: dayX(item.dayIndex),
                                            dayWidth: dayWidth(item.dayIndex))
            let face = CalendarMetrics.face(x: slot.x, width: slot.width, top: hoursTop + CGFloat(item.top),
                                            height: CGFloat(item.height))
            placed.append(Placed(event: item.event, face: face, dayIndex: item.dayIndex, item: item, overflow: 0))
        }
        for (index, allDay) in fit.allDay.enumerated() where !allDay.isEmpty && !fit.days[index].isFolded {
            let slot = CalendarMetrics.slot(column: 0, of: 1, dayX: dayX(index), dayWidth: dayWidth(index))
            for (row, event) in allDay.shown.enumerated() {
                let top = Pane.allDayPadTop + CGFloat(row) * (Pane.allDayRowHeight + Pane.allDayRowGap)
                let face = NSRect(x: slot.x, y: top, width: slot.width, height: Pane.allDayRowHeight)
                let isLast = row == allDay.shown.count - 1
                placed.append(Placed(event: event, face: face, dayIndex: index, item: nil, overflow: isLast ? allDay.overflow : 0))
            }
        }
        // The selected conversation's are drawn above their neighbours.
        let selected = content.selectedEventIDs
        self.placed = placed.filter { !selected.contains($0.event.id) } + placed.filter { selected.contains($0.event.id) }
        focusOrder = Self.timeOrder(placed)
        times.removeAll(keepingCapacity: true)

        placedMarks = fit.marks.compactMap { placedMark in
            guard let mark = content.mark(withID: placedMark.id), !fit.days[placedMark.dayIndex].isFolded else { return nil }
            let x = dayX(placedMark.dayIndex)
            let width = dayWidth(placedMark.dayIndex)
            let y = (hoursTop + CGFloat(placedMark.y)).rounded()
            let chipWidth = min(width - Pane.markChipInset, CalendarMarkPainter.chipWidth(for: mark, text: state.text))
            let chip = NSRect(x: x + Pane.markChipInset, y: chipTop(centredOn: y), width: max(0, chipWidth),
                              height: Pane.markChipHeight)
            return PlacedMark(mark: mark, dayIndex: placedMark.dayIndex, lineY: y, lineX: x...(x + width), chip: chip)
        }
        placeNow()
        updateJoin()
    }

    /// A mark chip's top: centred on its line, but never over a fold, whose range it would hide (a 09:00 mark sits on the
    /// edge of the night's fold), nor above the hours or below the fit. It moves to the open side of the fold.
    private func chipTop(centredOn y: CGFloat) -> CGFloat {
        var top = y - Pane.markChipHeight / 2
        for fold in fit?.folds ?? [] {
            let band = foldRect(fold)
            guard top < band.maxY, top + Pane.markChipHeight > band.minY else { continue }
            top = y >= band.midY ? band.maxY : band.minY - Pane.markChipHeight
        }
        return min(max(top, hoursTop), max(hoursTop, fitHeight - Pane.markChipHeight))
    }

    private func placeNow() {
        guard let fit, let located = fit.locate(state.now), !fit.days[located.dayIndex].isFolded else {
            nowY = nil
            nowDayIndex = nil
            return
        }
        nowDayIndex = located.dayIndex
        nowY = (hoursTop + CGFloat(fit.y(forMinute: located.minute))).rounded()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        dirtyRect.intersection(bounds).fill()
        guard let fit else { return }
        let hairline = QuireHairline.width(for: self)
        drawDays(fit, dirtyRect: dirtyRect, hairline: hairline)
        drawHours(fit, dirtyRect: dirtyRect, hairline: hairline)
        let isKey = isWindowKey
        for placed in placed where placed.face.insetBy(dx: -4, dy: -4).intersects(dirtyRect) {
            CalendarEventPainter.draw(look(for: placed, isKey: isKey))
        }
        for mark in placedMarks where markBounds(mark).intersects(dirtyRect) {
            CalendarMarkPainter.draw(mark, text: state.text, hovered: hovered == .mark(mark.mark.id),
                                     pressed: pressed == .mark(mark.mark.id))
        }
        if let nowY, let nowDayIndex {
            CalendarMarkPainter.drawNow(y: nowY, dayX: dayX(nowDayIndex), dayWidth: dayWidth(nowDayIndex),
                                        gutter: style.gutter, label: state.text.time(state.now))
        }
        if let ghost { CalendarMarkPainter.drawGhost(ghost.face, label: ghost.label) }
        if let focused = focusedPlaced, showsFocusRing {
            QuireFocusRing.draw(around: focused.face, cornerRadius: Pane.eventRadius, gap: QuireFocusRing.gap)
        }
    }

    /// Folded days, the separators between days, the all-day band's rule and the gutter's.
    private func drawDays(_ fit: CalendarFit, dirtyRect: NSRect, hairline: CGFloat) {
        for (index, day) in fit.days.enumerated() {
            let x = dayX(index)
            if day.isFolded {
                NSColor.qCanvas.setFill()
                NSRect(x: x, y: 0, width: CGFloat(day.width), height: bounds.height).fill()
            }
            if index > 0 {
                NSColor.qRule.setFill()
                NSRect(x: x, y: 0, width: hairline, height: bounds.height).fill()
            }
        }
        if fit.allDayHeight > 0 {
            NSColor.qRule.setFill()
            NSRect(x: style.gutter, y: CGFloat(fit.allDayHeight) - hairline, width: bounds.width - style.gutter, height: hairline).fill()
            if style == .week {
                let label = QuireFont.attributedString("All day", role: .meta, color: .qInk3)
                let width = CalendarType.width(of: label)
                let lineHeight = QuireFont.Role.meta.lineHeight
                label.draw(with: NSRect(x: style.gutter - Pane.hourLabelGap - width, y: Pane.allDayPadTop + 2, width: width + 1,
                                        height: lineHeight), options: QuireFont.drawingOptions, context: nil)
            }
        }
        NSColor.qRule.setFill()
        NSRect(x: style.gutter - hairline, y: 0, width: hairline, height: fitHeight).fill()
    }

    /// The hour lines and labels, and the folds with their ranges.
    private func drawHours(_ fit: CalendarFit, dirtyRect: NSRect, hairline: CGFloat) {
        let day = fit.days.first?.start ?? state.today
        let right = bounds.width - style.trailingPad
        let lineHeight = QuireFont.Role.meta.lineHeight
        for hour in 0..<24 where fit.openHours[hour] {
            let y = (hoursTop + CGFloat(fit.y(forMinute: Double(hour * 60)))).rounded()
            guard y - lineHeight <= dirtyRect.maxY, y + lineHeight >= dirtyRect.minY else { continue }
            NSColor.qRule.setFill()
            for (index, placedDay) in fit.days.enumerated() where !placedDay.isFolded {
                let x = dayX(index)
                let end = index == fit.days.count - 1 ? right : x + CGFloat(placedDay.width)
                NSRect(x: x, y: y, width: max(0, end - x), height: hairline).fill()
            }
            let top = Self.hourLabelTop(lineY: y, lineHeight: lineHeight, fitHeight: fitHeight)
            if let nowY, Self.hourLabelGivesWay(labelTop: top, lineHeight: lineHeight, nowY: nowY) { continue }
            let label = QuireFont.attributedString(state.text.hourLabel(hour, on: day), role: .meta, color: .qInk3)
            let width = CalendarType.width(of: label)
            label.draw(with: NSRect(x: style.gutter - Pane.hourLabelGap - width, y: top, width: width + 1, height: lineHeight),
                       options: QuireFont.drawingOptions, context: nil)
        }
        for fold in fit.folds {
            let rect = foldRect(fold)
            guard rect.intersects(dirtyRect) else { continue }
            CalendarMarkPainter.drawFold(rect, label: state.text.foldLabel(from: fold.from, to: fold.to, on: day),
                                         labelX: style.gutter + Pane.hourLabelGap)
        }
    }

    /// An hour label's top: centred on its hour's line, held inside the timeline at its top and bottom.
    static func hourLabelTop(lineY: CGFloat, lineHeight: CGFloat, fitHeight: CGFloat) -> CGFloat {
        min(max(0, lineY - lineHeight / 2), fitHeight - lineHeight)
    }

    /// The now label takes the gutter near it: an hour label within 14 pt of it gives way, measured where the label
    /// lands, so 00:00 held inside the top never sits under 00:19.
    static func hourLabelGivesWay(labelTop: CGFloat, lineHeight: CGFloat, nowY: CGFloat) -> Bool {
        abs(nowY - (labelTop + lineHeight / 2)) < Pane.hourLabelClearance
    }

    func foldRect(_ fold: CalendarFit.Fold) -> NSRect {
        NSRect(x: style.gutter, y: hoursTop + CGFloat(fold.y), width: max(0, bounds.width - style.trailingPad - style.gutter),
               height: Pane.foldHeight)
    }

    private var isWindowKey: Bool { state.isWindowKey ?? window?.isKeyWindow ?? false }

    func look(for placed: Placed, isKey: Bool) -> CalendarEventLook {
        let event = placed.event
        let id = event.id
        let interaction: CalendarEventLook.Interaction
        if pressed == .event(id) { interaction = .pressed }
        else if hovered == .event(id) || detailsEventID == id { interaction = .hover }
        else { interaction = .rest }
        var hatches: [(y: CGFloat, height: CGFloat)] = []
        if let item = placed.item, let fit, let intervals = content.hatches[id] {
            for interval in intervals {
                if let span = fit.span(of: interval, onDay: item.dayIndex) {
                    hatches.append((hoursTop + CGFloat(span.top), CGFloat(span.height)))
                }
            }
        }
        var place: (glyph: String, text: String)?
        if let join = event.joinURL, CalendarText.link(join) != nil {
            place = (Quire.Icon.joinCall, CalendarText.service(of: join))
        } else if let location = event.location, !location.isEmpty {
            place = (Quire.Icon.eventPlace, location)
        }
        let slotHeight = placed.item.map { CGFloat($0.height) } ?? Pane.allDayRowHeight
        return CalendarEventLook(
            event: event, face: placed.face, slotHeight: placed.isAllDay ? 0 : slotHeight,
            isPencilled: isPencilled(event), isSelected: content.selectedEventIDs.contains(id), isWindowKey: isKey,
            interaction: interaction, hatches: hatches, ink: state.ink(for: event.accountID),
            isAlone: (placed.item?.columnCount ?? 1) == 1, moreCount: placed.item?.moreCount ?? placed.overflow,
            joinWidth: joinEventID == id && !join.isHidden ? join.alignmentRect(forFrame: join.frame).width : 0,
            style: placed.isAllDay ? .week : style, timeText: times(of: event).range, startText: times(of: event).start,
            place: place)
    }

    /// The events' times as words, made once per fit: a formatter call is dear enough to count in a week of 300.
    private var times: [String: (range: String, start: String)] = [:]

    private func times(of event: CalendarEvent) -> (range: String, start: String) {
        if let cached = times[event.id] { return cached }
        let words = (state.text.range(event.start, event.end), state.text.time(event.start))
        times[event.id] = words
        return words
    }

    /// Not answered: drawn pencilled in.
    func isPencilled(_ event: CalendarEvent) -> Bool {
        CalendarFit.isPencil(event) || event.response == .needsAction
    }

    private func markBounds(_ mark: PlacedMark) -> NSRect {
        let line = NSRect(x: mark.lineX.lowerBound, y: mark.lineY - 2, width: mark.lineX.upperBound - mark.lineX.lowerBound,
                          height: 4)
        return line.union(mark.chip).insetBy(dx: -1, dy: -1)
    }

    private func invalidate(events ids: [String?]) {
        for id in ids.compactMap({ $0 }) {
            for placed in placed where placed.event.id == id {
                setNeedsDisplay(placed.face.insetBy(dx: -QuireFocusRing.margin, dy: -QuireFocusRing.margin))
            }
        }
    }

    private func invalidate(_ target: Target?) {
        switch target {
        case .event(let id)?: invalidate(events: [id])
        case .mark(let id)?:
            for mark in placedMarks where mark.mark.id == id { setNeedsDisplay(markBounds(mark)) }
        case nil: break
        }
    }

    /// The now line's band: the line, its dot and the time in the gutter, and the hour labels that gave way to it.
    private func invalidateNow(at y: CGFloat?) {
        guard let y else { return }
        let reach = Pane.hourLabelClearance + QuireFont.Role.meta.lineHeight
        setNeedsDisplay(NSRect(x: 0, y: y - reach, width: bounds.width, height: 2 * reach))
    }

    // MARK: Join

    /// Join on the next video call of today, when its face has the room (spec §5.54, “Join”): one at a time.
    private func updateJoin() {
        let candidate = nextCall()
        guard let candidate, candidate.face.width >= Pane.joinMinWidth, candidate.face.height >= Pane.joinMinHeight else {
            if !join.isHidden { join.isHidden = true; invalidate(events: [joinEventID]) }
            joinEventID = nil
            return
        }
        let previous = joinEventID
        joinEventID = candidate.event.id
        let showsLabel = candidate.face.width >= Pane.joinLabelMinWidth
        join.title = showsLabel ? "Join" : ""
        join.toolTip = showsLabel ? nil : "Join"
        join.setAccessibilityLabel("Join the call, " + (candidate.event.title.isEmpty ? CalendarText.noTitle : candidate.event.title))
        // The card's Join is the one primary in sight while the details are open.
        join.variant = detailsEventID == candidate.event.id ? .secondary : .primary
        let size = join.intrinsicContentSize
        join.frame = join.frame(forVisualRect: NSRect(x: candidate.face.maxX - size.width, y: candidate.face.minY,
                                                      width: size.width, height: size.height))
        if join.isHidden { join.isHidden = false }
        if previous != joinEventID { invalidate(events: [previous, joinEventID]) }
        pointerRegionsDidChange()
    }

    /// The first timed event of today, not yet ended and not pencilled, with a join address.
    private func nextCall() -> Placed? {
        guard let fit, let today = fit.locate(state.now)?.dayIndex else { return nil }
        let now = state.now
        return placed
            .filter { $0.dayIndex == today && !$0.isAllDay && CalendarText.link($0.event.joinURL) != nil && $0.event.end > now
                && !isPencilled($0.event) }
            .min { $0.event.start != $1.event.start ? $0.event.start < $1.event.start : $0.event.id < $1.event.id }
    }

    @objc private func joinClicked(_ sender: Any?) {
        guard let id = joinEventID, let event = placed.first(where: { $0.event.id == id })?.event,
              let url = CalendarText.link(event.joinURL) else { return }
        delegate?.openURL(url)
    }

    // MARK: Hit testing

    /// What `point` is over: a mark's chip first (marks are drawn above events), then the selected conversation's
    /// events, then the rest.
    func target(at point: NSPoint) -> Target? {
        for mark in placedMarks.reversed() where mark.chip.contains(point) { return .mark(mark.mark.id) }
        for placed in placed.reversed() where placed.face.contains(point) { return .event(placed.event.id) }
        return nil
    }

    func placed(withID id: String) -> Placed? { placed.first { $0.event.id == id } }

    /// A click (or ↩ and Space on a focused event): details beside it, its conversation for the mail's pencil, 30
    /// minutes set aside for the mail's time.
    func activate(_ target: Target, fromKeyboard: Bool = false) {
        if willActivate?(target) == true { return }
        switch target {
        case .event(let id):
            guard let placed = placed(withID: id) else { return }
            if CalendarFit.isPencil(placed.event) {
                if let conversation = state.selection?.conversationID { delegate?.selectConversation(conversation) }
                return
            }
            details?.show(placed.event, anchor: placed.face, in: self, fromKeyboard: fromKeyboard)
        case .mark(let id):
            guard let mark = placedMarks.first(where: { $0.mark.id == id }) else { return }
            switch mark.mark.kind {
            case .mailTime(let conversation, _):
                delegate?.blockTime(for: conversation, at: mark.mark.start)
            case .later, .sendLater:
                details?.show(mark.mark, anchor: mark.chip, in: self, fromKeyboard: fromKeyboard)
            }
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

    override func mouseMoved(with event: NSEvent) {
        setHovered(target(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseEntered(with event: NSEvent) {
        setHovered(target(at: convert(event.locationInWindow, from: nil)))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(nil)
    }

    private func setHovered(_ target: Target?) {
        guard target != hovered else { return }
        let previous = hovered
        hovered = target
        invalidate(previous)
        invalidate(target)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        pressStart = target(at: point)
        setPressed(pressStart)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressStart else { return }
        let over = target(at: convert(event.locationInWindow, from: nil)) == pressStart
        setPressed(over ? pressStart : nil)
    }

    override func mouseUp(with event: NSEvent) {
        let start = pressStart
        pressStart = nil
        setPressed(nil)
        guard let start, target(at: convert(event.locationInWindow, from: nil)) == start else { return }
        activate(start)
    }

    private func setPressed(_ target: Target?) {
        guard target != pressed else { return }
        let previous = pressed
        pressed = target
        invalidate(previous)
        invalidate(target)
    }

    // MARK: Pointer

    /// The pointing hand over everything a click acts on: every event and every chip (spec §4.17).
    var pointerRegions: [QuirePointerRegion] {
        var regions: [QuirePointerRegion] = []
        let holes = childPointerAreas()
        for placed in placed {
            regions += QuirePointerRegion.regions(placed.face, cursor: .pointingHand, cutting: holes)
        }
        for mark in placedMarks {
            regions += QuirePointerRegion.regions(mark.chip, cursor: .pointingHand, cutting: holes)
        }
        return regions
    }

    override func resetCursorRects() {
        addPointerRects()
    }

    override func viewDidHide() {
        super.viewDidHide()
        pointerRegionsDidChange()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        pointerRegionsDidChange()
    }

    // MARK: Tooltips

    private func updateToolTips() {
        removeAllToolTips()
        for placed in placed where (placed.item?.moreCount ?? placed.overflow) > 0 {
            let count = placed.item?.moreCount ?? placed.overflow
            addToolTip(CalendarEventPainter.moreTagRect(count, in: placed.face), owner: self, userData: nil)
        }
        for mark in placedMarks { addToolTip(mark.chip, owner: self, userData: nil) }
    }

    /// Tooltips are title case (spec §4.13): “Also at This Time: Hiring Sync”, “Comes Back from Later at 17:00”.
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                    userData data: UnsafeMutableRawPointer?) -> String {
        if let mark = placedMarks.last(where: { $0.chip.contains(point) }) {
            return CalendarMarkPainter.toolTip(for: mark.mark, text: state.text)
        }
        if let placed = placed.last(where: { $0.face.contains(point) }) {
            return "Also at This Time: " + hiddenTitles(behind: placed).map(Self.titleCase).joined(separator: ", ")
        }
        return ""
    }

    /// The events a “+N” stands for: the hidden ones of its group, or the all-day events past the band's rows.
    private func hiddenTitles(behind placed: Placed) -> [String] {
        guard let fit else { return [] }
        if let item = placed.item {
            return fit.items.filter { $0.isHidden && $0.dayIndex == item.dayIndex && $0.startMinute < item.endMinute
                && $0.endMinute > item.startMinute }.map { $0.event.title }
        }
        let allDay = fit.allDay[placed.dayIndex]
        let shown = Set(allDay.shown.map(\.id))
        return content.events.filter { $0.isAllDay && !shown.contains($0.id) && fitDayContains($0, day: placed.dayIndex) }
            .map(\.title)
    }

    private func fitDayContains(_ event: CalendarEvent, day index: Int) -> Bool {
        guard let fit, fit.days.indices.contains(index) else { return false }
        let start = fit.days[index].start
        let end = state.calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return event.overlaps(DateInterval(start: start.addingTimeInterval(-86_400), end: end.addingTimeInterval(86_400)))
    }

    static func titleCase(_ text: String) -> String {
        let small: Set<String> = ["a", "an", "and", "as", "at", "but", "by", "for", "from", "in", "of", "on", "or", "the", "to", "with"]
        return text.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { index, word in
            let lower = word.lowercased()
            if index > 0, small.contains(lower) { return lower }
            return word.prefix(1).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }

    // MARK: Keyboard

    /// Each event in time order (in the week, day by day): what Tab steps through (spec §5.54, “Keyboard”). Sorted
    /// once per fit.
    private(set) var focusOrder: [Placed] = []

    private static func timeOrder(_ placed: [Placed]) -> [Placed] {
        placed.sorted { a, b in
            if a.dayIndex != b.dayIndex { return a.dayIndex < b.dayIndex }
            if a.isAllDay != b.isAllDay { return a.isAllDay }
            if a.event.start != b.event.start { return a.event.start < b.event.start }
            return a.event.id < b.event.id
        }
    }

    private var focusedPlaced: Placed? {
        guard let focusIndex else { return nil }
        let order = focusOrder
        return order.indices.contains(focusIndex) ? order[focusIndex] : nil
    }

    /// From the keyboard only (Tab, VoiceOver, `focus(eventID:)`): a click opens an event's details and the list keeps
    /// the keyboard (§5.54), as a click on a Quire button leaves focus where it was (the window asks during the
    /// mouse-down).
    override var acceptsFirstResponder: Bool {
        !placed.isEmpty && !CalendarMetrics.isMouseDown(NSApp.currentEvent)
    }
    override var canBecomeKeyView: Bool { !placed.isEmpty && !isHiddenOrHasHiddenAncestor }

    private var showsFocusRing: Bool { window?.firstResponder === self && isWindowKey }

    override func becomeFirstResponder() -> Bool {
        // Shift-Tab arrives on the last event, Tab on the first.
        let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true && NSApp.currentEvent?.type == .keyDown
        setFocus(backwards ? focusOrder.count - 1 : 0)
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        let focused = focusedPlaced
        focusIndex = nil
        if let focused { invalidate(events: [focused.event.id]) }
        return super.resignFirstResponder()
    }

    private func setFocus(_ index: Int?) {
        let previous = focusedPlaced
        focusIndex = index.flatMap { focusOrder.isEmpty ? nil : min(max(0, $0), focusOrder.count - 1) }
        invalidate(events: [previous?.event.id, focusedPlaced?.event.id])
        if let focused = focusedPlaced, let element = accessibilityElement(for: focused.event.id) {
            NSAccessibility.post(element: element, notification: .focusedUIElementChanged)
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 48: // Tab
            let backwards = event.modifierFlags.contains(.shift)
            let next = (focusIndex ?? (backwards ? focusOrder.count : -1)) + (backwards ? -1 : 1)
            if focusOrder.indices.contains(next) {
                setFocus(next)
            } else if backwards {
                window?.selectKeyView(preceding: self)
            } else {
                window?.selectKeyView(following: self)
            }
        case 36, 76, 49: // Return, Enter, Space
            if let focused = focusedPlaced { activate(.event(focused.event.id), fromKeyboard: true) }
        default:
            super.keyDown(with: event)
        }
    }

    /// The focused event's face, for the details card to give focus back to.
    var focusedEventID: String? { focusedPlaced?.event.id }

    func focus(eventID: String) {
        guard let index = focusOrder.firstIndex(where: { $0.event.id == eventID }) else { return }
        window?.makeFirstResponder(self)
        setFocus(index)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        if let window {
            center.addObserver(self, selector: #selector(windowKeyDidChange(_:)), name: NSWindow.didBecomeKeyNotification, object: window)
            center.addObserver(self, selector: #selector(windowKeyDidChange(_:)), name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    @objc private func windowKeyDidChange(_ note: Notification) {
        guard state.isWindowKey == nil else { return }
        redrawSelection()
        if let focused = focusedPlaced { invalidate(events: [focused.event.id]) }
    }

    // MARK: Dropping a row

    /// Where a row dropped at `point` sets time aside: the day under it and 30 minutes from its time snapped to the
    /// quarter hour (over a fold, the hour after it). Nil over the gutter, the all-day band, a folded day or the pad.
    func dropStart(at point: NSPoint) -> (dayIndex: Int, start: Date)? {
        guard let fit, point.y >= hoursTop, point.y < hoursTop + CGFloat(fit.hoursHeight),
              let dayIndex = fit.dayIndex(atX: Double(point.x - style.gutter)),
              let minute = fit.snappedMinute(atY: Double(point.y - hoursTop)),
              let start = fit.date(atMinute: Double(minute), onDay: dayIndex) else { return nil }
        return (dayIndex, start)
    }

    /// The ghost of a drop at `start` on day `dayIndex`: an event's slot across the day.
    func ghostFace(dayIndex: Int, start: Date) -> NSRect? {
        guard let fit, let span = fit.span(of: DateInterval(start: start, duration: CalendarState.blockLength), onDay: dayIndex,
                                           minimumHeight: Double(Pane.eventMinHeight)) else { return nil }
        let slot = CalendarMetrics.slot(column: 0, of: 1, dayX: dayX(dayIndex), dayWidth: dayWidth(dayIndex))
        return CalendarMetrics.face(x: slot.x, width: slot.width, top: hoursTop + CGFloat(span.top), height: CGFloat(span.height))
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragMoved(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragMoved(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        setGhost(nil)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        setGhost(nil)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { setGhost(nil) }
        guard let conversation = CalendarDrop.conversation(in: sender),
              let drop = dropStart(at: convert(sender.draggingLocation, from: nil)) else { return false }
        delegate?.blockTime(for: conversation, at: drop.start)
        return true
    }

    private func dragMoved(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = CalendarDrop.operation(for: sender)
        guard !operation.isEmpty, CalendarDrop.conversation(in: sender) != nil,
              let drop = dropStart(at: convert(sender.draggingLocation, from: nil)),
              let face = ghostFace(dayIndex: drop.dayIndex, start: drop.start) else {
            setGhost(nil)
            return []
        }
        let label = state.text.ghost(drop.start, drop.start.addingTimeInterval(CalendarState.blockLength))
        setGhost((face, label))
        return operation
    }

    private func setGhost(_ new: (face: NSRect, label: String)?) {
        if ghost?.face == new?.face, ghost?.label == new?.label { return }
        if let old = ghost { setNeedsDisplay(old.face.insetBy(dx: -2, dy: -2)) }
        ghost = new
        if let new { setNeedsDisplay(new.face.insetBy(dx: -2, dy: -2)) }
    }

    /// The ghost now shown, for tests.
    var ghostShown: NSRect? { ghost?.face }

    // MARK: Accessibility

    /// The events as the list's children, in time order (in the week, grouped by day by `WeekView`), then the marks
    /// and the folds.
    override func accessibilityChildren() -> [Any]? {
        rebuildAccessibilityIfNeeded()
        var children: [Any] = accessibilityElements
        children.append(contentsOf: markAndFoldElements)
        if join.isHidden == false { children.append(join) }
        return children
    }

    /// The marks (“Comes back from Later at 17:00: Lease renewal”, the mail's time as a button) and the folds
    /// (“Nothing from 00:00 to 08:00”).
    private(set) var markAndFoldElements: [NSAccessibilityElement] = []

    private func rebuildAccessibilityIfNeeded() {
        guard accessibilityVersion != content.version || accessibilityElements.count != placed.count
                || markAndFoldElements.count != placedMarks.count + (fit?.folds.count ?? 0) else { return }
        accessibilityVersion = content.version
        accessibilityElements = focusOrder.map { placed in
            CalendarEventAccessibilityElement(timeline: self, eventID: placed.event.id,
                                              label: CalendarAccessibility.label(for: placed.event, content: content, state: state))
        }
        var others: [NSAccessibilityElement] = placedMarks.map { mark in
            CalendarMarkAccessibilityElement(timeline: self, markID: mark.mark.id,
                                             label: CalendarAccessibility.label(for: mark.mark, text: state.text))
        }
        let day = content.days.first ?? state.today
        for fold in fit?.folds ?? [] {
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityParent(self)
            element.setAccessibilityLabel(state.text.spokenFold(from: fold.from, to: fold.to, on: day))
            if let window {
                element.setAccessibilityFrame(window.convertToScreen(convert(foldRect(fold), to: nil)))
            }
            others.append(element)
        }
        markAndFoldElements = others
    }

    /// The mark `id` as drawn, for its accessibility element.
    func placedMark(withID id: String) -> PlacedMark? { placedMarks.first { $0.mark.id == id } }

    /// The week's seven columns for VoiceOver: each named by its day, holding its heading (a button that shows the
    /// day in the column) and its events in time order.
    func weekColumns(headings: WeekHeadingsView, parent: NSView) -> [NSAccessibilityElement] {
        guard let fit else { return [] }
        rebuildAccessibilityIfNeeded()
        let events = accessibilityElements.compactMap { $0 as? CalendarEventAccessibilityElement }
        return fit.days.enumerated().map { index, day in
            let column = CalendarWeekColumnAccessibilityElement(timeline: self, dayIndex: index,
                                                                label: state.text.longDay(day.start))
            column.setAccessibilityParent(parent)
            let heading = CalendarWeekHeadingAccessibilityElement(headings: headings, index: index,
                                                                  label: state.text.longDay(day.start))
            heading.setAccessibilityParent(column)
            let mine = events.filter { element in placed(withID: element.eventID)?.dayIndex == index }
            for element in mine { element.setAccessibilityParent(column) }
            column.setAccessibilityChildren([heading] + mine)
            return column
        }
    }

    private func accessibilityElement(for eventID: String) -> NSAccessibilityElement? {
        rebuildAccessibilityIfNeeded()
        return accessibilityElements.first { ($0 as? CalendarEventAccessibilityElement)?.eventID == eventID }
    }

    override func accessibilityLabel() -> String? {
        guard let first = content.days.first else { return nil }
        return style == .column ? "Events, " + state.text.longDay(first) : "Week"
    }
}
