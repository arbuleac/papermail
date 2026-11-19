import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// What a click, a key and a dropped row do on the column and the week (spec §5.54): details beside an event, the
/// mail's pencil selecting its conversation, the mail's time setting 30 minutes aside, drops snapped to the quarter
/// hour, Join on the next call only, and what VoiceOver and Tab reach.
@MainActor
final class CalendarViewTests: XCTestCase {
    private typealias Support = CalendarTestSupport

    private var pasteboards: [NSPasteboard] = []

    override func tearDown() {
        for pasteboard in pasteboards { pasteboard.releaseGlobally() }
        pasteboards.removeAll()
        Quire.Motion.finishAll()
        super.tearDown()
    }

    private let conversation = ConversationID(accountID: Support.accountA.id, providerID: "thread-1")
    private var message: MessageID { MessageID(accountID: Support.accountA.id, providerID: "msg-1") }

    private func column(events: [CalendarEvent] = Support.sampleWeek(), height: CGFloat = 800,
                        store: InMemoryMailStore? = nil) throws
        -> (column: DayColumnView, state: CalendarState, delegate: RecordingCalendarDelegate, window: NSWindow) {
        let store = try store ?? Support.store()
        try Support.write(events, to: store)
        let state = Support.state(store: store)
        let column = DayColumnView(state: state)
        let delegate = RecordingCalendarDelegate()
        column.delegate = delegate
        // The column at the trailing edge of a wider window, as beside the reader: its details open to its left.
        let window = Support.host(NSView(), size: NSSize(width: 900, height: height))
        let host = try XCTUnwrap(window.contentView)
        column.frame = NSRect(x: 900 - Quire.Layout.CalendarPane.columnWidth, y: 0, width: Quire.Layout.CalendarPane.columnWidth,
                              height: height)
        column.autoresizingMask = [.minXMargin, .height]
        host.addSubview(column)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        return (column, state, delegate, window)
    }

    private func click(_ view: NSView, at point: NSPoint) throws {
        let window = try XCTUnwrap(view.window)
        let location = view.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: 0,
                                                         windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                         clickCount: 1, pressure: 1))
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    private func centre(_ rect: NSRect) -> NSPoint { NSPoint(x: rect.midX, y: rect.midY) }

    // MARK: Clicks

    func testAClickOnAnEventOpensItsDetailsBesideTheColumn() throws {
        let (column, state, _, window) = try column()
        defer { window.close(); state.tearDown() }
        let review = try XCTUnwrap(column.timeline.placed.first { $0.event.title == "Roadmap review" })
        XCTAssertEqual(column.timeline.target(at: centre(review.face)), .event(review.event.id))

        try click(column.timeline, at: centre(review.face))
        let card = try XCTUnwrap(column.details.card, "the details open")
        XCTAssertTrue(card.superview === window.contentView, "laid on the window, over the reader")
        XCTAssertEqual(column.timeline.detailsEventID, review.event.id, "the event keeps its hover look while they are open")
        let cardFrame = card.convert(card.bounds, to: nil)
        let columnFrame = column.convert(column.bounds, to: nil)
        XCTAssertEqual(cardFrame.maxX, columnFrame.minX - Quire.Layout.CalendarPane.detailsGap, accuracy: 0.5,
                       "to the column's leading side, 8 pt from it")
        XCTAssertEqual(card.frame.width, Quire.Layout.CalendarPane.detailsWidth)
        XCTAssertEqual(card.model.title, "Roadmap review")
        XCTAssertEqual(card.model.kicker, "Contoso")
        XCTAssertEqual(card.model.when, "Thu 19 Nov · 13:00 - 14:00")
        XCTAssertEqual(card.buttons.map(\.title), ["Open in Google Calendar"], "no Join, no Remove: not set aside here")

        XCTAssertTrue(column.dismissDetails(), "Esc closes them")
        XCTAssertNil(column.details.card)
        XCTAssertNil(column.timeline.detailsEventID)
        XCTAssertFalse(column.dismissDetails(), "nothing more to close")
    }

    func testTurningTheDayWithinTheRangeShowsThatDay() throws {
        let (column, state, _, window) = try column()
        defer { window.close(); state.tearDown() }
        let strip = DayStripView(state: state)
        let stripWindow = Support.host(strip, size: NSSize(width: 28, height: 800))
        defer { stripWindow.close() }
        let range = state.observedRange
        XCTAssertTrue(column.timeline.placed.contains { $0.event.title == "Roadmap review" })
        let stripBars = strip.bars.count
        state.shownDay = Support.day(20)
        XCTAssertEqual(state.observedRange, range, "no read: the day is in the range")
        XCTAssertEqual(column.header.headline, "Friday 20 Nov")
        XCTAssertEqual(column.header.kicker, "Tomorrow")
        XCTAssertTrue(column.header.today.isEnabled)
        XCTAssertEqual(Set(column.timeline.placed.map(\.event.title)), ["Standup", "Birthday dinner"], "Friday's events")
        XCTAssertNil(column.timeline.nowY, "the now line is on today only")
        XCTAssertNotEqual(strip.bars.count, stripBars, "the strip follows the day too")
        XCTAssertEqual(column.cells.days.first, Support.day(16), "the same week of cells")
    }

    func testTimeSetAsideOffersRemoveAndShowTheMail() throws {
        let block = CalendarEvent(id: CalendarEvent.newLocalID(accountID: Support.accountA.id), accountID: Support.accountA.id,
                                  providerID: nil, title: "Lease renewal", start: Support.at(15), end: Support.at(15, 30),
                                  sourceMessage: message, sync: .failed)
        let store = try Support.store()
        let (column, state, delegate, window) = try column(events: [], store: store)
        defer { window.close(); state.tearDown() }
        try store.addCalendarEvent(block)
        try store.failCalendarEvent(id: block.id)
        let model = column.details.model(for: try XCTUnwrap(state.events.first))
        XCTAssertEqual(model.actions.map(\.title), ["Show the mail", "Remove"])
        XCTAssertEqual(model.kicker, "Contoso · Set aside for a mail")
        XCTAssertTrue(model.lines.contains { $0.text == "Couldn't add this to Google Calendar." }, "the failed line")
        model.actions[1].handler()
        XCTAssertEqual(delegate.removed.map(\.id), [block.id])
    }

    func testTheMailsPencilSelectsItsConversationAndItsTimeSetsTimeAside() throws {
        let store = try Support.store()
        try store.upsertMessages([MessageMetadata(id: message, conversationID: conversation, subject: "Design review", snippet: "",
                                                  from: nil, date: Support.at(8), roles: [.inbox], isRead: true, isStarred: false,
                                                  hasAttachments: false)])
        let invitation = CalendarInvitation(method: .request, uid: "mail-uid", title: "Design review", start: Support.at(10),
                                            end: Support.at(10, 30), organizer: .init(address: "rachel@contoso.test"),
                                            userAddress: Support.accountA.email, userResponse: .needsAction)
        try store.saveBody(StoredBody(body: MessageBody(html: nil, text: ""), renderedHTML: "", plainText: "", invitation: invitation),
                           for: message)
        try store.saveMailTimes([MailTime(messageID: message, start: Support.at(16), phrase: "4pm")], for: message)
        let (column, state, delegate, window) = try column(store: store)
        defer { window.close(); state.tearDown() }
        state.select(conversation)
        XCTAssertTrue(Support.spin(until: { column.timeline.placed.contains { CalendarFit.isPencil($0.event) } }))

        let pencil = try XCTUnwrap(column.timeline.placed.first { CalendarFit.isPencil($0.event) })
        XCTAssertTrue(column.timeline.isPencilled(pencil.event))
        XCTAssertEqual(column.timeline.placed.last?.event.id, pencil.event.id, "the selection is drawn above its neighbours")
        try click(column.timeline, at: centre(pencil.face))
        XCTAssertEqual(delegate.selectedConversations, [conversation], "a pencil from mail selects its conversation")
        XCTAssertNil(column.details.card, "and opens no details")

        let mark = try XCTUnwrap(column.timeline.placedMarks.first { $0.mark.isMailTime })
        XCTAssertEqual(column.timeline.target(at: centre(mark.chip)), .mark(mark.mark.id), "marks lie above events")
        try click(column.timeline, at: centre(mark.chip))
        XCTAssertEqual(delegate.blocked.map(\.0), [conversation])
        XCTAssertEqual(delegate.blocked.map(\.1), [Support.at(16)], "30 minutes at the time the mail names")
    }

    func testJoinShowsOnTheNextCallOfTodayOnly() throws {
        let clock = Support.Clock()
        let store = try Support.store()
        try Support.write(Support.sampleWeek(), to: store)
        let state = Support.state(store: store, clock: clock)
        defer { state.tearDown() }
        let column = DayColumnView(state: state)
        let delegate = RecordingCalendarDelegate()
        column.delegate = delegate
        let window = Support.host(column, size: NSSize(width: 240, height: 900))
        defer { window.close() }
        let join = try XCTUnwrap(column.timeline.subviews.compactMap { $0 as? QuireButton }.first)
        XCTAssertFalse(join.isHidden, "the 12:00 call is next")
        let call = try XCTUnwrap(column.timeline.placed.first { $0.event.title == "Contract call with Fabrikam" })
        XCTAssertTrue(call.face.contains(join.alignmentRect(forFrame: join.frame)), "flush in its face")
        join.performClick(nil)
        XCTAssertEqual(delegate.openedURLs.map(\.absoluteString), ["https://meet.google.com/abc-defg-hij"])

        clock.now = Support.at(12, 50)
        state.clock.tick()
        XCTAssertTrue(join.isHidden, "the call has ended and nothing else today has one")
    }

    func testDayCellsAndWeekHeadingsShowTheirDay() throws {
        let (column, state, delegate, window) = try column()
        defer { window.close(); state.tearDown() }
        let cells = column.cells
        XCTAssertEqual(cells.days.count, 7)
        XCTAssertEqual(cells.days.first, Support.day(16), "the shown day's Monday-first week")
        XCTAssertEqual(cells.cells[3].segments.count, 6, "Thursday's busy events, the unanswered one hollow")
        XCTAssertTrue(cells.cells[3].segments.contains { $0.isHollow })
        XCTAssertNotNil(cells.cells[3].allDay, "the go-live's line on top")
        try click(cells, at: centre(cells.cellRect(4)))
        XCTAssertEqual(delegate.selectedDays, [Support.day(20)])

        state.span = .week
        let week = WeekView(state: state)
        week.delegate = delegate
        let weekWindow = Support.host(week, size: NSSize(width: 1_000, height: 700))
        defer { weekWindow.close() }
        try click(week.headings, at: centre(week.headings.rect(1)))
        XCTAssertTrue(delegate.calls.contains("openWeekHeading"))
        week.header.next.performClick(nil)
        week.header.week.performClick(nil)
        XCTAssertEqual(Array(delegate.calls.suffix(2)), ["turnDay(7)", "toggleWeek"])
    }

    // MARK: Drops

    private func drag(_ ids: [ConversationID], source: Any? = NSObject(), mask: NSDragOperation = [.copy, .move]) -> FakeDraggingInfo {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        pasteboards.append(pasteboard)
        let items: [NSPasteboardItem] = ids.map { id in
            let item = NSPasteboardItem()
            item.setString("Subject", forType: .string)
            if let data = try? JSONEncoder().encode(id) { item.setData(data, forType: MessageListViewController.conversationPasteboardType) }
            return item
        }
        pasteboard.writeObjects(items)
        return FakeDraggingInfo(pasteboard: pasteboard, source: source, mask: mask)
    }

    func testADropLandsOnTheQuarterHourAndShowsItsGhost() throws {
        let (column, state, delegate, window) = try column()
        defer { window.close(); state.tearDown() }
        let timeline = column.timeline
        let fit = try XCTUnwrap(timeline.fit)
        let x = timeline.dayX(0) + 40
        func y(_ minute: Double) -> CGFloat { timeline.hoursTop + CGFloat(fit.y(forMinute: minute)) }

        XCTAssertEqual(timeline.dropStart(at: NSPoint(x: x, y: y(13 * 60 + 7)))?.start, Support.at(13), "13:07 snaps to 13:00")
        XCTAssertEqual(timeline.dropStart(at: NSPoint(x: x, y: y(13 * 60 + 8)))?.start, Support.at(13, 15), "13:08 to 13:15")
        let fold = try XCTUnwrap(fit.folds.first)
        XCTAssertEqual(timeline.dropStart(at: NSPoint(x: x, y: timeline.hoursTop + CGFloat(fold.y) + 4))?.start,
                       Support.at(fold.to), "over a fold, the hour after it")
        XCTAssertNil(timeline.dropStart(at: NSPoint(x: 10, y: y(13 * 60))), "the gutter takes no drop")
        XCTAssertNil(timeline.dropStart(at: NSPoint(x: x, y: 2)), "nor the all-day band")

        // A row dragged over 14:20: the ghost from 14:15, 30 minutes; the drop asks the shell to set it aside.
        let info = drag([conversation])
        info.draggingLocation = timeline.convert(NSPoint(x: x, y: y(14 * 60 + 20)), to: nil)
        XCTAssertEqual(timeline.draggingUpdated(info), .copy)
        let ghost = try XCTUnwrap(timeline.ghostShown)
        XCTAssertEqual(ghost.minY, y(14 * 60 + 15) + Quire.Layout.CalendarPane.eventInsetY, accuracy: 0.5)
        XCTAssertEqual(ghost.height, y(14 * 60 + 45) - y(14 * 60 + 15) - 2 * Quire.Layout.CalendarPane.eventInsetY, accuracy: 0.5)
        XCTAssertTrue(timeline.performDragOperation(info))
        XCTAssertNil(timeline.ghostShown)
        XCTAssertEqual(delegate.blocked.map(\.1), [Support.at(14, 15)])
        XCTAssertEqual(delegate.blocked.map(\.0), [conversation])

        // Several rows, another app's drag, or ⌘ held: no ghost, no drop.
        let several = drag([conversation, ConversationID(accountID: Support.accountB.id, providerID: "thread-2")])
        several.draggingLocation = info.draggingLocation
        XCTAssertEqual(timeline.draggingUpdated(several), [])
        XCTAssertNil(timeline.ghostShown)
        let foreign = drag([conversation], source: nil)
        foreign.draggingLocation = info.draggingLocation
        XCTAssertEqual(timeline.draggingUpdated(foreign), [])
        let refused = drag([conversation], mask: [])
        refused.draggingLocation = info.draggingLocation
        XCTAssertEqual(timeline.draggingUpdated(refused), [])
        XCTAssertFalse(timeline.performDragOperation(several))
        XCTAssertEqual(delegate.blocked.count, 1)
    }

    func testARowDroppedOnADayCellAsksForThatDaysFirstFreeHalfHour() throws {
        let (column, state, delegate, window) = try column()
        defer { window.close(); state.tearDown() }
        let cells = column.cells
        let info = drag([conversation])
        info.draggingLocation = cells.convert(centre(cells.cellRect(5)), to: nil)
        XCTAssertEqual(cells.draggingUpdated(info), .copy)
        XCTAssertEqual(cells.dropIndex, 5, "the cell takes the focus ring")
        XCTAssertTrue(cells.performDragOperation(info))
        XCTAssertNil(cells.dropIndex)
        XCTAssertEqual(delegate.blockedFirstFree.map(\.1), [Support.day(21)])
    }

    func testTheWeeksFoldedWeekendTakesNoDrop() throws {
        let store = try Support.store()
        try Support.write(Support.sampleWeek(), to: store)
        let state = Support.state(store: store)
        defer { state.tearDown() }
        state.span = .week
        let week = WeekView(state: state)
        let window = Support.host(week, size: NSSize(width: 1_000, height: 700))
        defer { window.close() }
        let timeline = week.timeline
        let fit = try XCTUnwrap(timeline.fit)
        let y = timeline.hoursTop + CGFloat(fit.y(forMinute: 13 * 60))
        XCTAssertNil(timeline.dropStart(at: NSPoint(x: timeline.dayX(5) + 4, y: y)), "Saturday is folded")
        let friday = try XCTUnwrap(timeline.dropStart(at: NSPoint(x: timeline.dayX(4) + 10, y: y)))
        XCTAssertEqual(friday.dayIndex, 4)
        XCTAssertEqual(friday.start, Support.at(13, on: Support.day(20)))
    }

    // MARK: The week's invitation card

    func testTheWeekShowsTheInvitationsCardWithItsAnswers() throws {
        let store = try Support.store()
        try Support.write(Support.sampleWeek(), to: store)
        try store.upsertMessages([MessageMetadata(id: message, conversationID: conversation, subject: "Design review", snippet: "",
                                                  from: nil, date: Support.at(8), roles: [.inbox], isRead: true, isStarred: false,
                                                  hasAttachments: false)])
        let invitation = CalendarInvitation(method: .request, uid: "mail-uid", title: "Design review", start: Support.at(13, 30),
                                            end: Support.at(14, 30), location: "Bay 4",
                                            organizer: .init(name: "Rachel Kim", address: "rachel@contoso.test"),
                                            userAddress: Support.accountA.email, userResponse: .needsAction)
        try store.saveBody(StoredBody(body: MessageBody(html: nil, text: ""), renderedHTML: "", plainText: "", invitation: invitation),
                           for: message)
        let state = Support.state(store: store)
        defer { state.tearDown() }
        state.span = .week
        let week = WeekView(state: state)
        let delegate = RecordingCalendarDelegate()
        week.delegate = delegate
        let window = Support.host(week, size: NSSize(width: 1_100, height: 800))
        defer { window.close() }
        state.select(conversation)
        XCTAssertTrue(Support.spin(until: { week.invitationCard != nil }))
        let card = try XCTUnwrap(week.invitationCard)
        XCTAssertEqual(card.model.kicker, "Invitation · not answered")
        XCTAssertTrue(card.model.lines.contains { $0.text == "Bay 4 · from Rachel Kim" })
        XCTAssertTrue(card.model.lines.contains { $0.text == "Overlaps Roadmap review, 13:30 - 14:00, and 1 more" },
                      "the first overlap by start, and how many more")
        XCTAssertEqual(card.buttons.map(\.title), ["Accept", "Tentative", "Decline"])
        let pencil = try XCTUnwrap(week.timeline.placed.first { CalendarFit.isPencil($0.event) })
        let cardInTimeline = week.timeline.convert(card.frame, from: week)
        XCTAssertFalse(cardInTimeline.intersects(pencil.face), "beside its slot, never on it")
        card.buttons[0].performClick(nil)
        XCTAssertEqual(delegate.answers.map(\.0), [.accepted])
        XCTAssertEqual(delegate.answers.map(\.1), [message])

        XCTAssertTrue(week.hideInvitationCard(), "Esc hides it")
        XCTAssertNil(week.invitationCard)
        XCTAssertFalse(week.hideInvitationCard())
        try click(week.timeline, at: centre(pencil.face))
        XCTAssertNotNil(week.invitationCard, "a click on its event brings it back")
        XCTAssertTrue(delegate.selectedConversations.isEmpty, "that click only brings the card back")
    }

    // MARK: Keyboard and VoiceOver

    func testTabStepsThroughTheEventsInTimeOrderAndReturnOpensDetails() throws {
        let (column, state, _, window) = try column()
        defer { window.close(); state.tearDown() }
        let timeline = column.timeline
        XCTAssertTrue(window.makeFirstResponder(timeline))
        let order = timeline.focusOrder.map(\.event.title)
        XCTAssertEqual(order.first, "Contoso go-live", "the all-day band first")
        XCTAssertEqual(timeline.focusedEventID, timeline.focusOrder.first?.event.id)
        let tab = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: "\t",
                                                 charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: 48))
        timeline.keyDown(with: tab)
        XCTAssertEqual(timeline.focusedEventID, timeline.focusOrder[1].event.id)
        let enter = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: "\r",
                                                   charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        timeline.keyDown(with: enter)
        XCTAssertNotNil(column.details.card)
        XCTAssertTrue(column.dismissDetails())
        XCTAssertTrue(window.firstResponder === timeline, "focus comes back to the event the keyboard opened")
        XCTAssertEqual(column.keyViews.count, 4, "‹ › (Today is disabled on today), the cells, the events; no foot")
    }

    func testVoiceOverReadsTheColumnAsAListOfEvents() throws {
        let (column, state, _, window) = try column()
        defer { window.close(); state.tearDown() }
        XCTAssertEqual(column.accessibilityLabel(), "Day, Thursday 19 November")
        XCTAssertEqual(column.timeline.accessibilityRole(), .list)
        let labels = (column.timeline.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        XCTAssertTrue(labels.contains("Roadmap review, 13:00 to 14:00, Contoso, Bay 4"))
        XCTAssertTrue(labels.contains("Design critique, 15:00 to 16:00, Fabrikam, not answered"))
        XCTAssertTrue(labels.contains("Team drinks, 17:30 to 19:30, Fabrikam, tentative"))
        XCTAssertTrue(labels.contains("Contract call with Fabrikam, 12:00 to 12:45, Contoso, has a call"))
        XCTAssertTrue(labels.contains("Nothing from 00:00 to 09:00"), "a fold says what it holds")
        let cells = (column.cells.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        XCTAssertEqual(cells.count, 7)
        XCTAssertEqual(cells[3].accessibilityLabel(), "Thursday 19 November, 7 events")
        XCTAssertEqual(cells[3].isAccessibilitySelected(), true)

        state.span = .week
        let week = WeekView(state: state)
        let weekWindow = Support.host(week, size: NSSize(width: 1_000, height: 700))
        defer { weekWindow.close() }
        let columns = (week.accessibilityChildren() ?? []).compactMap { $0 as? CalendarWeekColumnAccessibilityElement }
        XCTAssertEqual(columns.map { $0.accessibilityLabel() ?? "" }.first, "Monday 16 November")
        XCTAssertEqual(columns.count, 7, "the week is seven columns")
        XCTAssertEqual((columns[3].accessibilityChildren() ?? []).count, 1 + 7, "Thursday's heading and its events")
    }

    func testTooltipsAreTitleCase() throws {
        let (column, state, _, window) = try column()
        defer { window.close(); state.tearDown() }
        XCTAssertEqual(column.header.previous.toolTip, "Previous Day  [")
        XCTAssertEqual(column.header.today.toolTip, "Today  T")
        XCTAssertEqual(column.header.next.toolTip, "Next Day  ]")
        XCTAssertFalse(column.header.today.isEnabled, "Today is disabled while the column shows today")
        XCTAssertEqual(CalendarTimelineView.titleCase("hiring sync with the team"), "Hiring Sync with the Team")
        let later = CalendarMark(id: "l", kind: .later(conversation), start: Support.at(17), span: 60, title: "Lease")
        XCTAssertEqual(CalendarMarkPainter.toolTip(for: later, text: state.text), "Comes Back from Later at 17:00")
        let send = CalendarMark(id: "s", kind: .sendLater(id: "1", accountID: Support.accountA.id), start: Support.at(16), span: 60,
                                title: "")
        XCTAssertEqual(CalendarMarkPainter.toolTip(for: send, text: state.text), "Sends at 16:00 While SuperSparrow Is Open")
    }
}
