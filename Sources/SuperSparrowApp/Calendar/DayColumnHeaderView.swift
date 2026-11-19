import AppKit
import SSCore
import SSDesign

/// The column's 92 pt header, its bottom on the horizon the reader's shares (spec §5.54): the kicker (“Today”,
/// “Tomorrow”, “In 3 weeks”) on the lights' line, ‹ Today › at the trailing side, then the calendar toggle once some
/// account has granted the calendar permission, and the day as the headline with the week button.
@MainActor
final class DayColumnHeaderView: NSView {
    typealias Pane = Quire.Layout.CalendarPane

    let state: CalendarState
    weak var delegate: CalendarViewDelegate?

    let previous = QuireIconButton(symbolName: Quire.Icon.previousDay, size: .large, accessibilityLabel: "Previous Day")
    let today = QuireButton(title: "Today", variant: .secondary, size: .small)
    let next = QuireIconButton(symbolName: Quire.Icon.nextDay, size: .large, accessibilityLabel: "Next Day")
    /// The week, opened from inside the calendar (§5.54).
    let weekButton = QuireIconButton(symbolName: Quire.Icon.week, size: .large, accessibilityLabel: "Week")
    /// The calendar's toggle, on: it hides the column, which folds to its strip at the window's trailing edge, where the
    /// strip's glyph is the same toggle off (§5.54). Only once some account has granted the calendar permission.
    let dayToggle = QuireIconButton(symbolName: Quire.Icon.dayColumn, size: .large, accessibilityLabel: "Day")

    /// Whether the header ends its kicker line with the calendar toggle; the container sets it.
    var showsDayToggle = false {
        didSet {
            guard oldValue != showsDayToggle else { return }
            dayToggle.isHidden = !showsDayToggle
            needsLayout = true
            needsDisplay = true
        }
    }

    private(set) var kicker = ""
    private(set) var headline = ""

    init(state: CalendarState) {
        self.state = state
        super.init(frame: .zero)
        // Each part fills what it is asked to draw; without the clip that reaches past its bounds onto its neighbours.
        clipsToBounds = true
        previous.toolTip = "Previous Day  ["
        today.toolTip = "Today  T"
        next.toolTip = "Next Day  ]"
        weekButton.toolTip = "Show Week  W"
        weekButton.target = self
        weekButton.action = #selector(weekClicked(_:))
        // On while it shows, as the week's calendar button is: a click hides the column, and this button with it.
        dayToggle.onStyle = .quiet
        dayToggle.togglesOnClick = false
        dayToggle.isOn = true
        dayToggle.toolTip = "Hide Day  D"
        dayToggle.target = self
        dayToggle.action = #selector(dayToggleClicked(_:))
        dayToggle.isHidden = true
        previous.target = self
        previous.action = #selector(previousClicked(_:))
        today.target = self
        today.action = #selector(todayClicked(_:))
        next.target = self
        next.action = #selector(nextClicked(_:))
        for button in [previous, today, next, weekButton, dayToggle] as [NSView] { addSubview(button) }
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        if !CalendarTitleBarZone.handle(event, in: self) { super.mouseDown(with: event) }
    }

    /// The shown day's words, and Today disabled while it is today.
    func update() {
        let day = state.shownDay
        kicker = state.text.kicker(for: day, now: state.now)
        headline = state.text.headline(day, now: state.now)
        today.isEnabled = !state.calendar.isDate(day, inSameDayAs: state.now)
        needsDisplay = true
    }

    /// The kicker's line: centred on the traffic lights (y = 26).
    private var lineCentre: CGFloat { Quire.Layout.ReaderHeader.kickerCenterY }

    override func layout() {
        super.layout()
        let icon = QuireIconButton.Size.large.side
        let small = Quire.Layout.Button.Small.height
        var x = bounds.width - Pane.navTrailing - icon
        if showsDayToggle {
            dayToggle.frame = dayToggle.frame(forVisualRect: NSRect(x: x, y: lineCentre - icon / 2, width: icon, height: icon))
            x -= Pane.dayToggleGap + icon
        }
        next.frame = next.frame(forVisualRect: NSRect(x: x, y: lineCentre - icon / 2, width: icon, height: icon))
        let todayWidth = today.intrinsicContentSize.width
        x -= Pane.navGap + todayWidth
        today.frame = today.frame(forVisualRect: NSRect(x: x, y: lineCentre - small / 2, width: todayWidth, height: small))
        x -= Pane.navGap + icon
        previous.frame = previous.frame(forVisualRect: NSRect(x: x, y: lineCentre - icon / 2, width: icon, height: icon))
        // The week button on the headline's line, at the trailing side.
        let headlineCentre = Pane.headlineTop + QuireFont.Role.masthead.lineHeight / 2
        weekButton.frame = weekButton.frame(forVisualRect: NSRect(x: bounds.width - Pane.navTrailing - icon,
                                                                  y: headlineCentre - icon / 2, width: icon, height: icon))
    }

    /// Where the headline must end: 4 pt before the week button.
    private var headlineEnd: CGFloat {
        weekButton.alignmentRect(forFrame: weekButton.frame).minX - Pane.kickerNavGap / 2
    }

    /// Where the kicker must end: 8 pt before ‹.
    private var kickerEnd: CGFloat {
        previous.alignmentRect(forFrame: previous.frame).minX - Pane.kickerNavGap
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        dirtyRect.intersection(bounds).fill()
        let hairline = QuireHairline.width(for: self)
        NSColor.qRule.setFill()
        NSRect(x: 0, y: bounds.height - hairline, width: bounds.width, height: hairline).fill()
        let kickerRole = QuireFont.Role.runningHead
        QuireFont.attributedString(kicker, role: kickerRole, color: .qInk3)
            .draw(with: NSRect(x: Pane.headerPadX, y: lineCentre - kickerRole.lineHeight / 2,
                               width: max(0, kickerEnd - Pane.headerPadX), height: kickerRole.lineHeight),
                  options: QuireFont.drawingOptions, context: nil)
        let headlineRole = QuireFont.Role.masthead
        QuireFont.attributedString(headline, role: headlineRole, color: .qInk)
            .draw(with: NSRect(x: Pane.headerPadX, y: Pane.headlineTop, width: max(0, headlineEnd - Pane.headerPadX),
                               height: headlineRole.lineHeight), options: QuireFont.drawingOptions, context: nil)
    }

    @objc private func previousClicked(_ sender: Any?) { delegate?.turnDay(by: -1) }
    @objc private func todayClicked(_ sender: Any?) { delegate?.goToToday() }
    @objc private func nextClicked(_ sender: Any?) { delegate?.turnDay(by: 1) }
    @objc private func weekClicked(_ sender: Any?) { delegate?.toggleWeek() }
    @objc private func dayToggleClicked(_ sender: Any?) { delegate?.toggleDayColumn() }

    override func isAccessibilityElement() -> Bool { false }

    var keyViews: [NSView] { [previous, today, next] + (showsDayToggle ? [dayToggle] : []) + [weekButton] }
}
