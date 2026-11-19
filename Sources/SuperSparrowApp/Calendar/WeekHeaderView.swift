import AppKit
import SSCore
import SSDesign

/// The week's 92 pt header, on the horizon (spec §5.54, “The week”): the kicker (“This week · All accounts”, or the
/// scope's account after its ink dot), the days as the headline (“16 - 22 November”), and at the trailing side
/// Previous Week, Today, Next Week, a 14 pt gap, then the Day and Week buttons, which the hidden reader header cannot
/// show while the week takes its place.
@MainActor
final class WeekHeaderView: NSView {
    typealias Pane = Quire.Layout.CalendarPane
    typealias Header = Quire.Layout.ReaderHeader

    let state: CalendarState
    weak var delegate: CalendarViewDelegate?

    let previous = QuireIconButton(symbolName: Quire.Icon.previousDay, size: .large, accessibilityLabel: "Previous Week")
    let today = QuireButton(title: "Today", variant: .secondary, size: .small)
    let next = QuireIconButton(symbolName: Quire.Icon.nextDay, size: .large, accessibilityLabel: "Next Week")
    let day = QuireIconButton(symbolName: Quire.Icon.dayColumn, size: .large, accessibilityLabel: "Day")
    let week = QuireIconButton(symbolName: Quire.Icon.week, size: .large, accessibilityLabel: "Week")

    private(set) var kicker = ""
    private(set) var headline = ""
    private var scopeAccount: AccountID?

    init(state: CalendarState) {
        self.state = state
        super.init(frame: .zero)
        // Each part fills what it is asked to draw; without the clip that reaches past its bounds onto its neighbours.
        clipsToBounds = true
        previous.toolTip = "Previous Week  ["
        today.toolTip = "This Week  T"
        next.toolTip = "Next Week  ]"
        day.toolTip = "Show Day  D"
        week.toolTip = "Hide Week  W"
        // Quiet toggles that act on the window (§5.12): the week shows, so Week is on and Day is off.
        for toggle in [day, week] {
            toggle.onStyle = .quiet
            toggle.togglesOnClick = false
        }
        week.isOn = true
        day.isOn = false
        previous.target = self
        previous.action = #selector(previousClicked(_:))
        today.target = self
        today.action = #selector(todayClicked(_:))
        next.target = self
        next.action = #selector(nextClicked(_:))
        day.target = self
        day.action = #selector(dayClicked(_:))
        week.target = self
        week.action = #selector(weekClicked(_:))
        for button in [previous, today, next, day, week] as [NSView] { addSubview(button) }
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

    func update() {
        let days = state.shownWeekDays
        let first = days.first ?? state.shownWeek
        let words = state.text.weekKicker(for: first, now: state.now)
        switch state.scope {
        case .all:
            kicker = words + " · All accounts"
            scopeAccount = nil
        case .account(let id):
            kicker = words + " · "
            scopeAccount = id
        }
        headline = state.text.weekHeadline(days, now: state.now)
        today.isEnabled = !days.contains { state.calendar.isDate($0, inSameDayAs: state.now) }
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let icon = Header.actionSize
        let small = Quire.Layout.Button.Small.height
        let centre = Header.actionsTop + icon / 2
        var x = bounds.width - Header.actionsTrailing
        for button in [week, day] {
            x -= icon
            button.frame = button.frame(forVisualRect: NSRect(x: x, y: Header.actionsTop, width: icon, height: icon))
            x -= Header.actionGap
        }
        x -= Header.actionGroupGap - Header.actionGap
        x -= icon
        next.frame = next.frame(forVisualRect: NSRect(x: x, y: Header.actionsTop, width: icon, height: icon))
        let todayWidth = today.intrinsicContentSize.width
        x -= Pane.navGap + todayWidth
        today.frame = today.frame(forVisualRect: NSRect(x: x, y: centre - small / 2, width: todayWidth, height: small))
        x -= Pane.navGap + icon
        previous.frame = previous.frame(forVisualRect: NSRect(x: x, y: Header.actionsTop, width: icon, height: icon))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        dirtyRect.intersection(bounds).fill()
        let hairline = QuireHairline.width(for: self)
        NSColor.qRule.setFill()
        NSRect(x: 0, y: bounds.height - hairline, width: bounds.width, height: hairline).fill()
        let role = QuireFont.Role.runningHead
        let end = previous.alignmentRect(forFrame: previous.frame).minX - Pane.kickerNavGap
        let y = Header.kickerCenterY - role.lineHeight / 2
        let words = QuireFont.attributedString(kicker, role: role, color: .qInk3)
        words.draw(with: NSRect(x: Pane.weekHeaderPadX, y: y, width: max(0, end - Pane.weekHeaderPadX), height: role.lineHeight),
                   options: QuireFont.drawingOptions, context: nil)
        if let scopeAccount {
            // The scope's account after its ink dot, as the reader's kicker names it.
            var x = Pane.weekHeaderPadX + CalendarType.width(of: words)
            let dot = Header.kickerDot
            QuireDraw.fillCircle(NSRect(x: x, y: Header.kickerCenterY - dot / 2, width: dot, height: dot), state.ink(for: scopeAccount))
            x += dot + Header.kickerDotGap / 2
            QuireFont.attributedString(state.accountName(scopeAccount), role: role, color: .qInk3)
                .draw(with: NSRect(x: x, y: y, width: max(0, end - x), height: role.lineHeight), options: QuireFont.drawingOptions,
                      context: nil)
        }
        let headlineRole = QuireFont.Role.headline
        QuireFont.attributedString(headline, role: headlineRole, color: .qInk)
            .draw(with: NSRect(x: Pane.weekHeaderPadX, y: Header.headlineTop, width: max(0, bounds.width - 2 * Pane.weekHeaderPadX),
                               height: headlineRole.lineHeight), options: QuireFont.drawingOptions, context: nil)
    }

    @objc private func previousClicked(_ sender: Any?) { delegate?.turnDay(by: -7) }
    @objc private func todayClicked(_ sender: Any?) { delegate?.goToToday() }
    @objc private func nextClicked(_ sender: Any?) { delegate?.turnDay(by: 7) }
    @objc private func dayClicked(_ sender: Any?) { delegate?.toggleDayColumn() }
    @objc private func weekClicked(_ sender: Any?) { delegate?.toggleWeek() }

    override func isAccessibilityElement() -> Bool { false }

    var keyViews: [NSView] { [previous, today, next, day, week].filter { ($0 as NSControl).isEnabled } }
}
