import AppKit
import PaperCore
import PaperDesign

/// Opens an event's details (spec §5.54, “Event details”) beside it, or a Later or Send Later mark's card. One card at a
/// time, laid on the desk above the panes and below the toasts. The details show at once from the event in memory, then
/// follow the store (`observeEventCard`: the row, its details, the outbox), the mail it came from (read off the main
/// thread) and the account's statuses, re-applied in place. They close on Esc, a click outside, a turn of the day or week,
/// the selected conversation changing to another, the view hiding, the event leaving the store, Show the mail and
/// Remove; never on an answer, a re-read, new details or a resize. Focus goes back to the event when the keyboard opened
/// them, or to the next event when it is gone.
@MainActor
final class CalendarDetailsPresenter {
    typealias Pane = Quire.Layout.CalendarPane

    /// Where the card opens: in the column, to its leading side over the reader; in the week, beside the event.
    enum Placement {
        case leadingOfColumn
        case besideEvent
    }

    let state: CalendarState
    let placement: Placement
    weak var delegate: CalendarViewDelegate?
    /// Where the card is laid: the window's content view unless the shell names another (above the panes, below the
    /// toasts).
    weak var hostView: NSView?
    /// The pasteboard copies go to; tests give one of their own.
    var pasteboard: NSPasteboard = .general
    /// How long a copy button shows its Copied mark.
    var copiedDuration: TimeInterval = Quire.Motion.copiedConfirm

    private(set) var card: EventDetailsCardView?
    private(set) var markCard: CalendarCardView?
    private weak var timeline: CalendarTimelineView?
    private var anchor: NSRect = .zero
    private(set) var event: CalendarEvent?
    /// The pencil's selection, when the card is the selected mail's invitation drawn from the mail.
    private var pencil: CalendarSelection?
    private var cardState: EventCardState?
    private var related: RelatedInvitation?
    private var relatedKey: String?
    private var setAsideMessage: MessageMetadata??
    private var observation: StoreObservation?
    private var openedFromKeyboard = false
    /// Opened by the week for the selected conversation's invitation, not by the user.
    private(set) var openedBySelection = false
    private var selectedConversationAtOpen: ConversationID?
    private var guestsExpanded = false
    private var notesExpanded = false
    private var monitor: Any?
    private var copiedTimer: Timer?
    private weak var copiedButton: QuireIconButton?
    private var copiedItem: EventDetailsModel.CopyItem?

    init(state: CalendarState, placement: Placement) {
        self.state = state
        self.placement = placement
    }

    var isShowing: Bool { card != nil || markCard != nil }
    var eventID: String? { event?.id }

    // MARK: Opening

    /// The details of `event` beside `anchor` (the face clicked or focused). `bySelection`: the week opens the selected
    /// conversation's invitation by itself, without taking the keyboard or sending analytics.
    func show(_ event: CalendarEvent, anchor: NSRect, in timeline: CalendarTimelineView, fromKeyboard: Bool,
              bySelection: Bool = false) {
        dismiss(returningFocus: false)
        guard let window = timeline.window, let host = hostView ?? window.contentView else { return }
        self.timeline = timeline
        self.anchor = anchor
        self.event = event
        openedFromKeyboard = fromKeyboard
        openedBySelection = bySelection
        selectedConversationAtOpen = state.selectedConversation
        let isPencil = CalendarFit.isPencil(event)
        pencil = isPencil ? state.selection : nil
        cardState = isPencil ? nil : EventCardState(event: event)
        if isPencil, let selection = state.selection, let invitation = selection.invitation, let message = selection.invitationMessage,
           let metadata = try? state.store.message(message) {
            related = RelatedInvitation(message: metadata, invitation: invitation)
        }
        let card = EventDetailsCardView()
        wire(card)
        host.addSubview(card, positioned: .above, relativeTo: nil)
        self.card = card
        apply()
        timeline.detailsEventID = event.id
        if fromKeyboard { window.makeFirstResponder(card.initialKeyView) }
        startMonitor(for: card)
        NSAccessibility.post(element: card, notification: .created)
        if !bySelection {
            let trigger: AnalyticsSignal.Trigger = fromKeyboard ? .key : .toolbar
            Analytics.send(.detailsOpened(EventDetailsModel.kind(of: event, isPencil: isPencil), trigger))
        }
        guard !isPencil else { return }
        observation = state.observeEventCard(id: event.id) { [weak self] cardState in
            MainActor.assumeIsolated { self?.cardStateArrived(cardState) }
        }
        if event.isSetAside, let message = event.sourceMessage {
            state.message(message) { [weak self] found in
                guard let self, self.event?.id == event.id else { return }
                self.setAsideMessage = .some(found)
                self.apply()
            }
        } else {
            lookUpRelatedMail(for: event)
        }
        delegate?.readEventDetails(eventID: event.id)
    }

    func show(_ mark: CalendarMark, anchor: NSRect, in timeline: CalendarTimelineView, fromKeyboard: Bool) {
        dismiss(returningFocus: false)
        guard let window = timeline.window, let host = hostView ?? window.contentView else { return }
        let card = CalendarCardView(model: model(for: mark))
        let frame = Self.frame(for: card.preferredHeight, anchor: anchor, in: timeline, host: host, placement: placement)
        card.frame = host.convert(frame, from: timeline)
        host.addSubview(card, positioned: .above, relativeTo: nil)
        card.layoutSubtreeIfNeeded()
        markCard = card
        self.timeline = timeline
        self.anchor = anchor
        openedFromKeyboard = fromKeyboard
        if fromKeyboard, let first = card.buttons.first { window.makeFirstResponder(first) }
        startMonitor(for: card)
        NSAccessibility.post(element: card, notification: .created)
        let kind: AnalyticsSignal.EventKind
        switch mark.kind {
        case .later: kind = .later
        case .sendLater: kind = .sendLater
        case .mailTime: return
        }
        Analytics.send(.detailsOpened(kind, fromKeyboard ? .key : .toolbar))
    }

    private func startMonitor(for card: NSView) {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let shown = self.card ?? self.markCard, event.window === shown.window else { return }
                // A click inside a menu the card opened is not outside it.
                let point = shown.convert(event.locationInWindow, from: nil)
                if !shown.bounds.contains(point) {
                    self.openedFromKeyboard = false
                    self.dismiss()
                }
            }
            return event
        }
    }

    // MARK: Closing

    /// Closes the card (Esc's row 4, §6.1). Returns whether one was open.
    @discardableResult
    func dismiss(returningFocus: Bool = true) -> Bool {
        guard card != nil || markCard != nil else { return false }
        card?.removeFromSuperview()
        markCard?.removeFromSuperview()
        card = nil
        markCard = nil
        observation?.cancel()
        observation = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        copiedTimer?.invalidate()
        copiedTimer = nil
        timeline?.detailsEventID = nil
        if returningFocus, openedFromKeyboard, let id = event?.id, let timeline {
            if timeline.placed(withID: id) != nil {
                timeline.focus(eventID: id)
            } else if let next = timeline.nextEvent(after: event?.start ?? .distantPast) {
                timeline.focus(eventID: next)
            } else {
                timeline.window?.makeFirstResponder(timeline)
            }
        }
        event = nil
        pencil = nil
        cardState = nil
        related = nil
        relatedKey = nil
        setAsideMessage = nil
        guestsExpanded = false
        notesExpanded = false
        openedBySelection = false
        return true
    }

    /// The calendar state changed: a turn of the day or week closes the card; a change of the selected conversation to
    /// another closes it, a re-read of the same one re-applies; anything else re-applies it in place and places it again.
    func stateDidChange(_ change: CalendarChange) {
        guard isShowing else { return }
        if change.contains(.shown) {
            dismiss()
            return
        }
        if change.contains(.selection), state.selectedConversation != selectedConversationAtOpen {
            dismiss()
            return
        }
        if card != nil, change.contains(.selection) || change.contains(.statuses) || change.contains(.content) {
            if pencil != nil { pencil = state.selection }
            apply()
        }
    }

    /// The timeline refitted (a resize, new content): the card follows its face.
    func timelineDidLayout() {
        guard card != nil || markCard != nil else { return }
        place()
    }

    // MARK: Following the store

    private func cardStateArrived(_ arrived: EventCardState?) {
        guard card != nil else { return }
        guard let arrived, arrived.event.sync != .deleting else {
            // Gone from the store (a sweep after an Outlook decline, a removal elsewhere): the card goes with it.
            dismiss()
            return
        }
        let previous = cardState?.event
        cardState = arrived
        event = arrived.event
        if let previous, previous.invitationUID != arrived.event.invitationUID || previous.seriesID != arrived.event.seriesID
            || previous.title != arrived.event.title {
            lookUpRelatedMail(for: arrived.event)
        }
        if case .failed? = arrived.answer, card?.model?.answerLine != .failed {
            if let card { QuireAccessibility.announce("Couldn't answer the invitation.", from: card) }
        }
        apply()
    }

    private func lookUpRelatedMail(for event: CalendarEvent) {
        let key = [event.id, event.invitationUID ?? "", event.seriesID ?? "", event.title].joined(separator: "|")
        guard key != relatedKey else { return }
        relatedKey = key
        state.relatedMail(for: event) { [weak self] found in
            guard let self, self.relatedKey == key else { return }
            self.related = found
            self.apply()
        }
    }

    // MARK: Building

    private func inputs() -> EventDetailsModel.Inputs? {
        guard let event = cardState?.event ?? event else { return nil }
        let overlap = overlapWords(for: event)
        return EventDetailsModel.Inputs(
            event: event, details: cardState?.details?.details, answer: cardState?.answer, pencil: pencil, related: related,
            setAsideMessage: setAsideMessage, accountName: state.accountName(event.accountID), dot: state.ink(for: event.accountID),
            kind: state.providerKind(event.accountID),
            permissionNeeded: state.permissionsNeeded[event.accountID]?.contains(.calendar) == true,
            overlap: overlap, selectedConversation: state.selectedConversation, inColumn: placement == .leadingOfColumn,
            guestsExpanded: guestsExpanded, notesExpanded: notesExpanded, text: state.text, now: state.now)
    }

    /// “Overlaps Roadmap sync with Elena, 19:30 - 20:00”: what the event meets in any account other than itself, as the
    /// reader's card counts it (§5.14).
    private func overlapWords(for event: CalendarEvent) -> String? {
        // No UID matches nothing: the event itself (as the pencil) is then what the others are measured against.
        let uid = event.invitationUID ?? "\u{1}" + event.id
        var shown = event
        if shown.response == .declined { return nil }
        shown.response = shown.response == .organizer ? .organizer : .accepted
        // The event itself is its own copy (nearest its start): every other busy event it meets is an overlap.
        let others = state.events.filter { $0.id != event.id }
        let overlap = CalendarFit.invitationOverlap(uid: uid, near: event.start, in: [shown] + others, pencil: shown,
                                                    accountID: event.accountID)
        guard let overlap, !overlap.overlaps.isEmpty else { return nil }
        return WeekOverlapWords.line(overlap, startingOn: event.start, state: state)
    }

    private func apply() {
        guard let card, let inputs = inputs() else { return }
        card.notesExpanded = notesExpanded
        card.apply(EventDetailsModel(inputs))
        place()
    }

    /// Places the card beside its face (the part clicked; read again, as the fit may have moved it), at most as tall as
    /// the room from the timeline's top to 8 pt above the window's bottom.
    private func place() {
        guard let timeline, let host = hostView ?? timeline.window?.contentView else { return }
        if let id = event?.id, let face = timeline.faces(withID: id).min(by: { distance($0, anchor) < distance($1, anchor) }) {
            anchor = face
        }
        if let card {
            let window = timeline.convert(host.bounds, from: host)
            let room = max(window.minY, window.maxY) - Pane.detailsGap - max(timeline.bounds.minY, window.minY)
            card.maxHeight = min(Pane.detailsMaxHeight, room)
            card.setFrameSize(NSSize(width: Pane.detailsWidth, height: card.preferredHeight))
            let frame = Self.frame(for: card.preferredHeight, anchor: anchor, in: timeline, host: host, placement: placement)
            card.frame = host.convert(frame, from: timeline)
            card.layoutSubtreeIfNeeded()
        } else if let markCard {
            let frame = Self.frame(for: markCard.preferredHeight, anchor: anchor, in: timeline, host: host, placement: placement)
            markCard.frame = host.convert(frame, from: timeline)
        }
    }

    private func distance(_ a: NSRect, _ b: NSRect) -> CGFloat {
        abs(a.midX - b.midX) + abs(a.midY - b.midY)
    }

    /// The card's frame in the timeline's coordinates: beside the event as `placement` says, moved up to stay 8 pt above
    /// the window's bottom, never above the timeline's top.
    static func frame(for height: CGFloat, anchor: NSRect, in timeline: NSView, host: NSView, placement: Placement) -> NSRect {
        let gap = Pane.detailsGap
        let width = Pane.detailsWidth
        let window = timeline.convert(host.bounds, from: host)
        var x: CGFloat
        var y = anchor.minY
        switch placement {
        case .leadingOfColumn:
            // Over the reader, but never past the host's leading edge: a narrow reader beside a wide list would leave
            // the card's first buttons over the list, where no click reaches them. It may cover the column's edge then.
            x = max(window.minX + gap, timeline.bounds.minX - gap - width)
        case .besideEvent:
            x = anchor.maxX + gap
            if x + width > timeline.bounds.maxX {
                x = anchor.minX - gap - width
                if x < timeline.bounds.minX {
                    x = min(max(timeline.bounds.minX, anchor.minX), timeline.bounds.maxX - width)
                    y = anchor.maxY + gap
                }
            }
        }
        let bottom = max(window.minY, window.maxY) - gap
        if y + height > bottom { y = bottom - height }
        y = max(timeline.bounds.minY, y)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    // MARK: What the card does

    private func wire(_ card: EventDetailsCardView) {
        card.onClose = { [weak self] in self?.dismiss() }
        card.onAnswer = { [weak self] response, button in self?.answer(response, from: button) }
        card.onLink = { [weak self] url, action in self?.open(url, action: action) }
        card.onCopy = { [weak self] item, value, button in self?.copy(item, value: value, from: button) }
        card.onShowMail = { [weak self] message in
            guard let self else { return }
            let trigger = self.trigger
            self.dismiss(returningFocus: false)
            self.delegate?.showMail(message, fromWeek: self.placement == .besideEvent)
            Analytics.send(.eventAction(.showMail, .details, trigger))
        }
        card.onAction = { [weak self] kind in self?.perform(kind) }
        card.onControl = { [weak self] control in
            guard let self else { return }
            switch control {
            case "guests.toggle":
                self.guestsExpanded.toggle()
                if self.guestsExpanded { Analytics.send(.eventAction(.showAllGuests, .details, self.trigger)) }
            case "notes.toggle":
                self.notesExpanded.toggle()
                if self.notesExpanded { Analytics.send(.eventAction(.showMoreNotes, .details, self.trigger)) }
            default:
                return
            }
            self.apply()
            if self.notesExpanded, control == "notes.toggle", let notes = self.card?.notesView { self.card?.reveal(notes) }
        }
        card.onReconnect = { [weak self] account in self?.delegate?.connect(accountIDs: [account]) }
    }

    /// A key when one is being handled, else a click.
    private var trigger: AnalyticsSignal.Trigger {
        NSApp.currentEvent?.type == .keyDown ? .key : .toolbar
    }

    private func perform(_ kind: EventDetailsModel.ActionKind) {
        switch kind {
        case .join(let url):
            open(url, action: .join)
        case .openIn(let url):
            open(url, action: .openIn)
        case .remove:
            guard let event else { return }
            let trigger = self.trigger
            openedFromKeyboard = false
            dismiss()
            delegate?.removeEvent(event)
            Analytics.send(.eventAction(.remove, .details, trigger))
        }
    }

    private func open(_ url: URL, action: AnalyticsSignal.EventAction) {
        let trigger = self.trigger
        guard delegate?.openEventLink(url) == true else { return }
        Analytics.send(.eventAction(action, .details, trigger))
    }

    /// Writes the value to the pasteboard as written; the copy button's glyph turns to a check for a moment.
    func copy(_ item: EventDetailsModel.CopyItem, value: String, from button: QuireIconButton) {
        let board = pasteboard
        board.clearContents()
        guard board.setString(value, forType: .string) else {
            CalendarSignposts.log.error("copying an event detail failed")
            NSSound.beep()
            return
        }
        CalendarSignposts.log.debug("copied an event detail")
        if let previous = copiedButton, let previousItem = copiedItem, previous !== button {
            previous.isOn = false
            previous.toolTip = previousItem.tooltip
        }
        button.isOn = true
        button.toolTip = "Copied"
        copiedButton = button
        copiedItem = item
        copiedTimer?.invalidate()
        copiedTimer = Timer.scheduledTimer(withTimeInterval: copiedDuration, repeats: false) { [weak self, weak button] _ in
            MainActor.assumeIsolated {
                button?.isOn = false
                button?.toolTip = item.tooltip
                if self?.copiedButton === button {
                    self?.copiedButton = nil
                    self?.copiedItem = nil
                }
            }
        }
        QuireAccessibility.announce(item.announcement, from: button)
        Analytics.send(.eventAction(item.action, .details, trigger))
    }

    /// An answer: the pencil through its mail; an event of the calendar through the engine, which picks the route, after
    /// This Event or All Events on a repeating one. A click on the chosen answer does nothing (the button ignores it).
    private func answer(_ response: InvitationResponse, from button: QuireButton) {
        guard let event, let model = card?.model, let answers = model.answers, answers.chosen != response || answers.waiting == false else {
            return
        }
        if answers.chosen == response { return }
        if let selection = pencil, let message = selection.invitationMessage {
            delegate?.answerInvitation(response, for: message, surface: .details)
            return
        }
        guard answers.asksSpan else {
            send(response, span: .single, event: event)
            return
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let this = menu.addItem(withTitle: "This Event", action: #selector(SpanTarget.chose(_:)), keyEquivalent: "")
        let all = menu.addItem(withTitle: "All Events", action: #selector(SpanTarget.chose(_:)), keyEquivalent: "")
        let target = SpanTarget { [weak self] span in self?.send(response, span: span, event: event) }
        this.target = target
        this.representedObject = AnswerSpan.occurrence.rawValue
        all.target = target
        all.representedObject = AnswerSpan.series.rawValue
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 2), in: button)
        _ = target
    }

    private func send(_ response: InvitationResponse, span: AnswerSpan, event: CalendarEvent) {
        let message = related.flatMap { $0.invitation.method == .request ? $0.message.id : nil }
        delegate?.answerCalendarEvent(response, eventID: event.id, span: span, invitationMessage: message)
    }

    // MARK: Marks

    func model(for mark: CalendarMark) -> CalendarCardModel {
        let text = state.text
        let title = mark.title.isEmpty ? "No subject" : mark.title
        let when = text.shortDay(mark.start, now: state.now) + ", " + text.time(mark.start)
        switch mark.kind {
        case .later(let conversation):
            return CalendarCardModel(
                kickerGlyph: (Quire.Icon.later, .qInk3), kicker: "Later", title: title, when: "Back in the Inbox " + when,
                lines: [.init(glyph: nil, text: "Snoozed. G L lists it.", role: .snippet, color: .qInk2)],
                actions: [.init(title: "Show the mail", variant: .secondary, symbol: nil) { [weak self] in
                    let trigger = self?.trigger ?? .toolbar
                    self?.dismiss()
                    self?.delegate?.selectConversation(conversation)
                    Analytics.send(.eventAction(.showMail, .details, trigger))
                }], accessibilityName: title)
        case .sendLater(let id, _):
            return CalendarCardModel(
                kickerGlyph: (Quire.Icon.send, .qInk3), kicker: "Send Later", title: title, when: "Sends " + when,
                lines: [.init(glyph: nil, text: "Sends while Paper is open. It waits in the Outbox until then.",
                              role: .snippet, color: .qInk2)],
                actions: [.init(title: "Show the mail", variant: .secondary, symbol: nil) { [weak self] in
                    let trigger = self?.trigger ?? .toolbar
                    self?.dismiss()
                    self?.delegate?.showPendingSend(id: id)
                    Analytics.send(.eventAction(.showMail, .details, trigger))
                }], accessibilityName: title)
        case .mailTime(let conversation, _):
            return CalendarCardModel(
                kickerGlyph: (Quire.Icon.fromThisMail, .qInk3), kicker: "From this mail", title: title, when: when,
                actions: [.init(title: "Block 30 minutes", variant: .primary, symbol: Quire.Icon.blockTime) { [weak self] in
                    self?.dismiss()
                    self?.delegate?.blockTime(for: conversation, at: mark.start)
                }], accessibilityName: title)
        }
    }
}

/// The span menu's target: which item was chosen.
@MainActor
private final class SpanTarget: NSObject {
    private let chosen: (AnswerSpan) -> Void
    /// Kept alive while the menu is open (a menu item holds its target weakly).
    private static var live: SpanTarget?

    init(_ chosen: @escaping (AnswerSpan) -> Void) {
        self.chosen = chosen
        super.init()
        Self.live = self
    }

    @objc func chose(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let span = AnswerSpan(rawValue: raw) else { return }
        chosen(span)
        Self.live = nil
    }
}

/// The overlap line's words, as the reader's card writes them (spec §5.14).
@MainActor
enum WeekOverlapWords {
    static func line(_ overlap: CalendarFit.InvitationOverlap?, startingOn start: Date, state: CalendarState) -> String? {
        guard let overlap, overlap.event.isShown else { return nil }
        let calendar = state.calendar
        let builder = RenderPayloadBuilder(calendar: calendar, locale: calendar.locale ?? .autoupdatingCurrent, timeZone: calendar.timeZone)
        return builder.overlapLine(overlap, startingOn: start, now: state.now)
    }
}
