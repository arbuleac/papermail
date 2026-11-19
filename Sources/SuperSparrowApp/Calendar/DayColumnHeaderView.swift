import AppKit
import SSCore
import SSDesign

/// The column's 92 pt header, its bottom on the horizon the reader's shares (spec §5.54): the kicker (“Today”,
/// “Tomorrow”, “In 3 weeks”) on the lights' line, ‹ Today › at the trailing side, and the day as the headline.
@MainActor
final class DayColumnHeaderView: NSView {
    typealias Pane = Quire.Layout.CalendarPane

    let state: CalendarState
    weak var delegate: CalendarViewDelegate?

    let previous = QuireIconButton(symbolName: Quire.Icon.previousDay, size: .large, accessibilityLabel: "Previous Day")
    let today = QuireButton(title: "Today", variant: .secondary, size: .small)
    let next = QuireIconButton(symbolName: Quire.Icon.nextDay, size: .large, accessibilityLabel: "Next Day")

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
        previous.target = self
        previous.action = #selector(previousClicked(_:))
        today.target = self
        today.action = #selector(todayClicked(_:))
        next.target = self
        next.action = #selector(nextClicked(_:))
        for button in [previous, today, next] as [NSView] { addSubview(button) }
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
        next.frame = next.frame(forVisualRect: NSRect(x: x, y: lineCentre - icon / 2, width: icon, height: icon))
        let todayWidth = today.intrinsicContentSize.width
        x -= Pane.navGap + todayWidth
        today.frame = today.frame(forVisualRect: NSRect(x: x, y: lineCentre - small / 2, width: todayWidth, height: small))
        x -= Pane.navGap + icon
        previous.frame = previous.frame(forVisualRect: NSRect(x: x, y: lineCentre - icon / 2, width: icon, height: icon))
    }

    /// Where the kicker must end: 8 pt before ‹.
    private var kickerEnd: CGFloat {
        previous.alignmentRect(forFrame: previous.frame).minX - Pane.kickerNavGap
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        dirtyRect.fill()
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
            .draw(with: NSRect(x: Pane.headerPadX, y: Pane.headlineTop, width: max(0, bounds.width - 2 * Pane.headerPadX),
                               height: headlineRole.lineHeight), options: QuireFont.drawingOptions, context: nil)
    }

    @objc private func previousClicked(_ sender: Any?) { delegate?.turnDay(by: -1) }
    @objc private func todayClicked(_ sender: Any?) { delegate?.goToToday() }
    @objc private func nextClicked(_ sender: Any?) { delegate?.turnDay(by: 1) }

    override func isAccessibilityElement() -> Bool { false }

    var keyViews: [NSView] { [previous, today, next] }
}
