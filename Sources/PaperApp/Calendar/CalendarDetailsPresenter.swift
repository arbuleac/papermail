import AppKit
import PaperCore
import PaperDesign

/// Opens an event's details (or a Later or Send Later mark's) in a card beside it (spec §5.54, “Event details”). One
/// card at a time, laid on the window's content above everything but toasts; it closes on Esc (`dismiss()`), a click
/// outside it, a turn of the day or week and a change of selection, giving focus back to the event when the keyboard
/// opened it.
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

    private(set) var card: CalendarCardView?
    private weak var timeline: CalendarTimelineView?
    private var eventID: String?
    private var openedFromKeyboard = false
    private var monitor: Any?

    init(state: CalendarState, placement: Placement) {
        self.state = state
        self.placement = placement
    }

    var isShowing: Bool { card != nil }

    func show(_ event: CalendarEvent, anchor: NSRect, in timeline: CalendarTimelineView, fromKeyboard: Bool) {
        present(model: model(for: event), anchor: anchor, in: timeline, eventID: event.id, fromKeyboard: fromKeyboard)
    }

    func show(_ mark: CalendarMark, anchor: NSRect, in timeline: CalendarTimelineView, fromKeyboard: Bool) {
        present(model: model(for: mark), anchor: anchor, in: timeline, eventID: nil, fromKeyboard: fromKeyboard)
    }

    /// Closes the card (Esc's row 4, §6.1). Returns whether one was open.
    @discardableResult
    func dismiss() -> Bool {
        guard let card else { return false }
        card.removeFromSuperview()
        self.card = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        timeline?.detailsEventID = nil
        if openedFromKeyboard, let eventID { timeline?.focus(eventID: eventID) }
        eventID = nil
        return true
    }

    private func present(model: CalendarCardModel, anchor: NSRect, in timeline: CalendarTimelineView, eventID: String?,
                         fromKeyboard: Bool) {
        dismiss()
        guard let window = timeline.window, let host = hostView ?? window.contentView else { return }
        let card = CalendarCardView(model: model)
        let frame = Self.frame(for: card.preferredHeight, anchor: anchor, in: timeline, host: host, placement: placement)
        card.frame = host.convert(frame, from: timeline)
        host.addSubview(card, positioned: .above, relativeTo: nil)
        card.layoutSubtreeIfNeeded()
        self.card = card
        self.timeline = timeline
        self.eventID = eventID
        openedFromKeyboard = fromKeyboard
        timeline.detailsEventID = eventID
        if fromKeyboard, let first = card.buttons.first { window.makeFirstResponder(first) }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let card = self.card, event.window === card.window else { return }
                let point = card.convert(event.locationInWindow, from: nil)
                if !card.bounds.contains(point) {
                    self.openedFromKeyboard = false
                    self.dismiss()
                }
            }
            return event
        }
        NSAccessibility.post(element: card, notification: .created)
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

    // MARK: Models

    func model(for event: CalendarEvent) -> CalendarCardModel {
        let text = state.text
        let kind = state.providerKind(event.accountID)
        var kicker = state.accountName(event.accountID)
        if event.response == .tentative { kicker += " · Tentative" }
        if event.response == .needsAction { kicker += " · Not answered" }
        if event.isSetAside { kicker += " · Set aside for a mail" }
        var lines: [CalendarCardModel.Line] = []
        if let location = event.location, !location.isEmpty {
            lines.append(.init(glyph: nil, text: location, role: .snippet, color: .qInk2))
        }
        if let join = event.joinURL, CalendarText.link(join) != nil {
            lines.append(.init(glyph: nil, text: CalendarText.serviceName(of: join, stated: event.callService), role: .snippet, color: .qInk2))
        }
        if event.sync == .failed {
            lines.append(.init(glyph: (Quire.Icon.failed, .qDanger),
                               text: "Couldn't add this to " + CalendarText.providerCalendarName(kind) + ".",
                               role: .snippet, color: .qDanger))
        }
        var actions: [CalendarCardModel.Action] = []
        if let url = CalendarText.link(event.joinURL) {
            actions.append(.init(title: "Join", variant: .primary, symbol: Quire.Icon.joinCall) { [weak self] in
                self?.delegate?.openURL(url)
            })
        }
        if let message = event.sourceMessage {
            actions.append(.init(title: "Show the mail", variant: .secondary, symbol: nil) { [weak self] in
                self?.dismiss()
                self?.delegate?.showMail(message)
            })
        }
        if event.isSetAside {
            actions.append(.init(title: "Remove", variant: .secondary, symbol: nil) { [weak self] in
                self?.openedFromKeyboard = false
                self?.dismiss()
                self?.delegate?.removeEvent(event)
            })
        }
        if let url = CalendarText.link(event.webURL) {
            actions.append(.init(title: "Open in " + CalendarText.providerCalendarName(kind), variant: .link, symbol: nil) { [weak self] in
                self?.delegate?.openURL(url)
            })
        }
        let title = event.title.isEmpty ? CalendarText.noTitle : event.title
        return CalendarCardModel(dot: state.ink(for: event.accountID), kicker: kicker, title: title,
                                 titleIsPlaceholder: event.title.isEmpty, when: text.when(event, now: state.now), lines: lines,
                                 actions: actions, accessibilityName: title)
    }

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
                    self?.dismiss()
                    self?.delegate?.selectConversation(conversation)
                }], accessibilityName: title)
        case .sendLater(let id, _):
            return CalendarCardModel(
                kickerGlyph: (Quire.Icon.send, .qInk3), kicker: "Send Later", title: title, when: "Sends " + when,
                lines: [.init(glyph: nil, text: "Sends while Paper is open. It waits in the Outbox until then.",
                              role: .snippet, color: .qInk2)],
                actions: [.init(title: "Show the mail", variant: .secondary, symbol: nil) { [weak self] in
                    self?.dismiss()
                    self?.delegate?.showPendingSend(id: id)
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
