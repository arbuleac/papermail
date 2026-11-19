import AppKit
import SSCore
import SSDesign

/// The week's day headings (spec §5.54, “Day headings”): a 34 pt band, per day “Thu 19” (today's in `ink`, ruled
/// under), a folded day in two centred lines. A click goes back to the reader and the column on that day.
@MainActor
final class WeekHeadingsView: NSView, QuirePointerTarget {
    typealias Pane = Quire.Layout.CalendarPane

    let state: CalendarState
    weak var delegate: CalendarViewDelegate?

    /// The fit's days (their x from the first day's leading edge, width, folded), and the gutter before them.
    var days: [CalendarFit.Day] = [] {
        didSet {
            guard oldValue != days else { return }
            needsDisplay = true
            updateToolTips()
            pointerRegionsDidChange()
        }
    }
    var gutter: CGFloat = Quire.Layout.CalendarPane.hourGutterWeek

    private var hovered: Int?
    private var pressed: Int?
    private var trackingArea: NSTrackingArea?

    init(state: CalendarState) {
        self.state = state
        super.init(frame: .zero)
        // Each part fills what it is asked to draw; without the clip that reaches past its bounds onto its neighbours.
        clipsToBounds = true
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    func rect(_ index: Int) -> NSRect {
        guard days.indices.contains(index) else { return .zero }
        let hairline = QuireHairline.width(for: self)
        return NSRect(x: gutter + CGFloat(days[index].x), y: 0, width: CGFloat(days[index].width), height: bounds.height - hairline)
    }

    func index(at point: NSPoint) -> Int? {
        days.indices.first { rect($0).contains(point) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        dirtyRect.intersection(bounds).fill()
        let hairline = QuireHairline.width(for: self)
        let today = state.today
        for (index, day) in days.enumerated() {
            let rect = self.rect(index)
            if day.isFolded {
                NSColor.qCanvas.setFill()
                rect.fill()
            } else if pressed == index {
                NSColor.qPressed.setFill()
                rect.fill()
            } else if hovered == index {
                NSColor.qHover.setFill()
                rect.fill()
            }
            if index > 0 {
                NSColor.qRule.setFill()
                NSRect(x: rect.minX, y: 0, width: hairline, height: bounds.height).fill()
            }
            let isToday = state.calendar.isDate(day.start, inSameDayAs: today)
            let lit = isToday || hovered == index || pressed == index
            let role = QuireFont.Role.runningHead
            if day.isFolded {
                // Two centred lines: “Sa”, “21”.
                for (line, text) in [state.text.narrowWeekday(day.start), state.text.dayNumber(day.start)].enumerated() {
                    let words = QuireFont.attributedString(text, role: role, color: isToday ? .qInk : .qInk3)
                    let width = CalendarType.width(of: words)
                    words.draw(with: NSRect(x: rect.midX - width / 2, y: Pane.weekHeadTextTop / 2 + CGFloat(line) * role.lineHeight,
                                            width: width + 1, height: role.lineHeight), options: QuireFont.drawingOptions, context: nil)
                }
                continue
            }
            let words = QuireFont.attributedString(state.text.weekHeading(day.start), role: role, color: lit ? .qInk : .qInk3)
            let x = rect.minX + Pane.weekHeadPadX
            words.draw(with: NSRect(x: x, y: Pane.weekHeadTextTop, width: max(0, rect.maxX - x - Pane.weekHeadPadX / 2),
                                    height: role.lineHeight), options: QuireFont.drawingOptions, context: nil)
            if isToday {
                // Today's heading ruled under: 2 pt of `ink`, 4 pt below its line.
                NSColor.qInk.setFill()
                let width = min(CalendarType.width(of: words), rect.maxX - x)
                NSRect(x: x, y: Pane.weekHeadTextTop + role.lineHeight + Pane.todayUnderlineGap - Pane.dayCellAllDayLine,
                       width: width, height: Pane.dayCellAllDayLine).fill()
            }
        }
        NSColor.qRule.setFill()
        NSRect(x: 0, y: bounds.height - hairline, width: bounds.width, height: hairline).fill()
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
        guard index != hovered else { return }
        redraw(hovered)
        hovered = index
        redraw(index)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = index(at: convert(event.locationInWindow, from: nil))
        redraw(pressed)
    }

    override func mouseUp(with event: NSEvent) {
        let start = pressed
        pressed = nil
        redraw(start)
        guard let start, index(at: convert(event.locationInWindow, from: nil)) == start else { return }
        open(start)
    }

    func open(_ index: Int) {
        guard days.indices.contains(index) else { return }
        delegate?.openWeekHeading(day: days[index].start)
    }

    private func redraw(_ index: Int?) {
        guard let index else { return }
        setNeedsDisplay(rect(index))
    }

    // MARK: Pointer and tooltips

    var pointerRegions: [QuirePointerRegion] { days.indices.map { QuirePointerRegion.control(rect($0), acts: true) } }

    override func resetCursorRects() { addPointerRects() }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { updateToolTips(); pointerRegionsDidChange() }
    }

    private func updateToolTips() {
        removeAllToolTips()
        for index in days.indices { addToolTip(rect(index), owner: self, userData: nil) }
    }

    /// “Show Thu 19 Nov in the Day Column”.
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint,
                    userData data: UnsafeMutableRawPointer?) -> String {
        guard let index = index(at: point) else { return "" }
        return "Show " + state.text.shortDay(days[index].start, now: state.now) + " in the Day Column"
    }
}
