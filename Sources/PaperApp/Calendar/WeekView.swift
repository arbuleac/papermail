import AppKit
import PaperCore
import PaperDesign

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
    /// Esc hid the card until the selection changes or its event is clicked (§6.1 row 12).
    private(set) var isSelectionDetailsHidden = false
    /// The selection when the selection's details were hidden: a re-read of it keeps them hidden.
    private var selectionAtHide: ConversationID?

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
        if change.contains(.selection), state.selectedConversation != selectionAtHide { isSelectionDetailsHidden = false }
        details.stateDidChange(change)
        // Nothing is read or fitted for a week no one sees: it catches up when it shows again.
        guard isShowing else { needsReload = true; return }
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

    private var needsReload = false

    /// In a window and not hidden.
    var isShowing: Bool { window != nil && !isHiddenOrHasHiddenAncestor }

    func reload() {
        guard isShowing else { needsReload = true; return }
        needsReload = false
        let signpost = CalendarSignposts.signposter.beginInterval("calendar.week")
        header.update()
        foot.update()
        timeline.setContent(state.content(for: state.shownWeekDays))
        timeline.nowDidChange()
        headings.days = timeline.fit?.days ?? []
        headings.needsDisplay = true
        updateSelectionDetails()
        let days = state.shownWeekDays
        setAccessibilityLabel("Week, " + state.text.weekHeadline(days, now: state.now))
        needsLayout = true
        CalendarSignposts.signposter.endInterval("calendar.week", signpost)
    }

    /// Closes an open event's details (Esc's row 4): the selection's, opened by the week, stay hidden until the selection
    /// changes or the event is clicked (row 12). Returns whether one was open.
    @discardableResult
    func dismissDetails() -> Bool {
        if details.openedBySelection { hideSelectionDetailsUntilChanged() }
        return details.dismiss()
    }

    /// Hides the selection's details until the selection changes or the event is clicked (Esc's row 12). Returns
    /// whether they showed.
    @discardableResult
    func hideSelectionDetails() -> Bool {
        guard details.openedBySelection else { return false }
        return dismissDetails()
    }

    private func hideSelectionDetailsUntilChanged() {
        isSelectionDetailsHidden = true
        selectionAtHide = state.selectedConversation
    }

    /// The selection's details, while they are open.
    var selectionDetails: EventDetailsCardView? { details.openedBySelection ? details.card : nil }

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
        // The selection's details go beside its event, which has a place only once the timeline has a size.
        if !details.isShowing { updateSelectionDetails() }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    // MARK: The selection's details

    /// While the selected conversation's invitation falls in the shown week, its event's details open beside its slot by
    /// themselves (the calendar's copy in the invitation's account, else the pencil), without taking the keyboard.
    private func updateSelectionDetails() {
        guard isShowing else { return }
        guard !isSelectionDetailsHidden, let selection = state.selection, let invitation = selection.invitation,
              !invitation.isCancelled, let placed = invitationPlaced() else {
            if details.openedBySelection { details.dismiss(returningFocus: false) }
            return
        }
        // A card the user opened stays; the selection's own is opened again only when it shows another event.
        if details.isShowing, !details.openedBySelection { return }
        if details.openedBySelection, details.eventID == placed.event.id { return }
        details.show(placed.event, anchor: placed.face, in: timeline, fromKeyboard: false, bySelection: true)
    }

    /// The invitation's event as the timeline drew it: the calendar's copy, or the pencil from the mail.
    private func invitationPlaced() -> CalendarTimelineView.Placed? {
        guard let id = state.selectionOverlap?.event.id else { return nil }
        return timeline.placed(withID: id)
    }

    /// A click on another event hides the selection's details as Esc does; a click on its own event brings them back.
    private func timelineWillActivate(_ target: CalendarTimelineView.Target) -> Bool {
        guard case .event(let id) = target else { return false }
        if id == state.selectionOverlap?.event.id {
            guard isSelectionDetailsHidden else { return false }
            // Hidden with Esc: a click on its event brings the selection's details back, and does nothing else.
            isSelectionDetailsHidden = false
            updateSelectionDetails()
            return true
        }
        if details.openedBySelection || state.selection?.invitation != nil { hideSelectionDetailsUntilChanged() }
        return false
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

    /// The week's stops for the window's Tab loop: the header's buttons, the events, the foot's button.
    var keyViews: [NSView] { header.keyViews + [timeline] + foot.keyViews }

    // MARK: Accessibility

    /// The week as seven columns, each named by its heading and holding its events (spec §5.54, “VoiceOver”).
    override func accessibilityChildren() -> [Any]? {
        var children: [Any] = [header.previous, header.today, header.next, header.day, header.week]
        children.append(contentsOf: timeline.weekColumns(headings: headings, parent: self))
        children.append(contentsOf: timeline.markAndFoldElements)
        if let card = selectionDetails { children.append(card) }
        children.append(contentsOf: foot.keyViews)
        return children
    }
}
