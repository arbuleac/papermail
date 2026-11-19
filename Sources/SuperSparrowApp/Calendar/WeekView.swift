import AppKit
import SSCore
import SSDesign

/// The week (spec §5.54, “The week”): W shows it in the reader's place and the column's, the whole right side of the
/// window, `paper`. Seven columns after a 48 pt hour gutter (an empty Saturday or Sunday folded to 28 pt), the day
/// headings, the all-day band across them, the timeline fitted over all seven days, the marks, and the selected
/// invitation's card beside its slot. Everything else, the keys, the colours and the fit, is the column's.
@MainActor
final class WeekView: NSView, CalendarStateObserver {
    typealias Pane = Quire.Layout.CalendarPane

    let state: CalendarState
    weak var delegate: CalendarViewDelegate? {
        didSet {
            header.delegate = delegate
            headings.delegate = delegate
            timeline.delegate = delegate
            foot.delegate = delegate
            details.delegate = delegate
        }
    }

    let header: WeekHeaderView
    let headings: WeekHeadingsView
    let timeline: CalendarTimelineView
    let foot: CalendarFootView
    let details: CalendarDetailsPresenter
    /// The selected conversation's invitation, beside its slot while it falls in the week.
    private(set) var invitationCard: CalendarCardView?
    /// Esc hid the card until the selection changes or its event is clicked (§6.1 row 12).
    private(set) var isInvitationCardHidden = false

    init(state: CalendarState) {
        self.state = state
        header = WeekHeaderView(state: state)
        headings = WeekHeadingsView(state: state)
        timeline = CalendarTimelineView(style: .week, state: state)
        foot = CalendarFootView(state: state)
        details = CalendarDetailsPresenter(state: state, placement: .besideEvent)
        super.init(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        foot.padX = Pane.weekHeaderPadX
        timeline.details = details
        timeline.willActivate = { [weak self] target in self?.timelineWillActivate(target) ?? false }
        for view in [header, headings, timeline, foot] as [NSView] { addSubview(view) }
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
        if change.contains(.selection) { isInvitationCardHidden = false }
        if change.contains(.content) || change.contains(.shown) || change.contains(.day) || change.contains(.selection) {
            reload()
            return
        }
        if change.contains(.statuses) {
            foot.update()
            header.update()
            needsLayout = true
        }
        if change.contains(.now) { timeline.nowDidChange() }
        if change.contains(.windowKey) { timeline.redrawSelection() }
    }

    func reload() {
        let signpost = CalendarSignposts.signposter.beginInterval("calendar.week")
        header.update()
        foot.update()
        timeline.setContent(state.content(for: state.shownWeekDays))
        timeline.nowDidChange()
        headings.days = timeline.fit?.days ?? []
        headings.needsDisplay = true
        updateInvitationCard()
        let days = state.shownWeekDays
        setAccessibilityLabel("Week, " + state.text.weekHeadline(days, now: state.now))
        needsLayout = true
        CalendarSignposts.signposter.endInterval("calendar.week", signpost)
    }

    /// Closes an open event's details (Esc's row 4). Returns whether one was open.
    @discardableResult
    func dismissDetails() -> Bool { details.dismiss() }

    /// Hides the invitation card until the selection changes or its event is clicked (Esc's row 12). Returns whether
    /// one showed.
    @discardableResult
    func hideInvitationCard() -> Bool {
        guard let invitationCard, !invitationCard.isHidden else { return false }
        isInvitationCardHidden = true
        updateInvitationCard()
        return true
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        let width = bounds.width
        header.frame = NSRect(x: 0, y: 0, width: width, height: Pane.headerHeight)
        headings.frame = NSRect(x: 0, y: Pane.headerHeight, width: width, height: Pane.weekHeadsHeight)
        let footHeight = foot.preferredHeight(forWidth: width)
        foot.frame = NSRect(x: 0, y: bounds.height - footHeight, width: width, height: footHeight)
        let top = CalendarMetrics.weekTimelineTop
        timeline.frame = NSRect(x: 0, y: top, width: width, height: max(0, bounds.height - footHeight - top))
        headings.gutter = timeline.style.gutter
        headings.days = timeline.fit?.days ?? []
        placeInvitationCard()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        dirtyRect.fill()
    }

    // MARK: The invitation card

    private func updateInvitationCard() {
        guard !isInvitationCardHidden, let selection = state.selection, let placed = invitationPlaced(),
              let model = WeekInvitationCard.model(for: selection, overlap: state.selectionOverlap, event: placed.event, state: state,
                                                   answer: { [weak self] response, message in
                                                       self?.delegate?.answerInvitation(response, for: message)
                                                   }) else {
            invitationCard?.removeFromSuperview()
            invitationCard = nil
            return
        }
        if let invitationCard {
            invitationCard.apply(model)
        } else {
            let card = CalendarCardView(model: model)
            addSubview(card, positioned: .above, relativeTo: nil)
            invitationCard = card
        }
        placeInvitationCard()
    }

    /// The invitation's event as the timeline drew it: the calendar's copy, or the pencil from the mail.
    private func invitationPlaced() -> CalendarTimelineView.Placed? {
        guard let id = state.selectionOverlap?.event.id else { return nil }
        return timeline.placed(withID: id)
    }

    private func placeInvitationCard() {
        guard let card = invitationCard, let placed = invitationPlaced() else { return }
        let frame = CalendarDetailsPresenter.frame(for: card.preferredHeight, anchor: placed.face, in: timeline, host: self,
                                                   placement: .besideEvent)
        card.frame = convert(frame, from: timeline)
    }

    /// A click on the invitation's event brings its hidden card back.
    private func timelineWillActivate(_ target: CalendarTimelineView.Target) -> Bool {
        guard isInvitationCardHidden, case .event(let id) = target, id == state.selectionOverlap?.event.id else { return false }
        isInvitationCardHidden = false
        updateInvitationCard()
        return true
    }

    // MARK: Visibility

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { state.clock.unregister(self) } else { state.clock.register(self) }
        if window == nil { details.dismiss() }
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

    /// The week's stops for the window's Tab loop: the header's buttons, the events, the foot's button.
    var keyViews: [NSView] { header.keyViews + [timeline] + foot.keyViews + (invitationCard?.buttons ?? []) }

    // MARK: Accessibility

    /// The week as seven columns, each named by its heading and holding its events (spec §5.54, “VoiceOver”).
    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = [header.previous, header.today, header.next, header.day, header.week]
        children.append(contentsOf: timeline.weekColumns(headings: headings, parent: self))
        children.append(contentsOf: timeline.markAndFoldElements)
        if let invitationCard { children.append(invitationCard) }
        children.append(contentsOf: foot.keyViews)
        return children
    }
}
