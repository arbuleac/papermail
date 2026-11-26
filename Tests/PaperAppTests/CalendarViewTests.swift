import AppKit
import PaperCore
import PaperDesign
import XCTest
@testable import PaperApp

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
        XCTAssertEqual(card.model?.title, "Roadmap review")
        XCTAssertEqual(card.model?.kicker, "Contoso")
        XCTAssertEqual(card.model?.when, "Thu 19 Nov · 13:00 - 14:00")
        XCTAssertEqual(card.buttons.map(\.title), ["Accept", "Tentative", "Decline", "Open in Google Calendar"],
                       "an invitation: its answers, and no Join or Remove")

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
        XCTAssertTrue(Support.spin(until: { column.timeline.placed(withID: block.id) != nil }))
        column.timeline.activate(.event(block.id))
        let card = try XCTUnwrap(column.details.card)
        XCTAssertTrue(Support.spin(until: { card.model?.mail != nil }), "its mail, looked up")
        let model = try XCTUnwrap(card.model)
        XCTAssertEqual(model.actions.map(\.title), ["Remove"], "Show the mail is the Mail row now")
        XCTAssertEqual(model.kicker, "Contoso · Set aside for a mail")
        XCTAssertEqual(model.status?.text, "Couldn't add this to Google Calendar.", "the failed line")
        XCTAssertTrue(model.rows.isEmpty, "no rows for time set aside but its mail")
        XCTAssertNil(model.answers)
        card.buttons.first { $0.title == "Remove" }?.performClick(nil)
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
        XCTAssertTrue(delegate.selectedConversations.isEmpty, "a pencil from mail opens its details (1.22), selecting nothing")
        let details = try XCTUnwrap(column.details.card)
        XCTAssertTrue(details.model?.kicker.contains("Invitation") == true, details.model?.kicker ?? "")
        XCTAssertTrue(column.dismissDetails())

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

    /// The shell opens https links only: an http meeting or web link offers no Join, no call line and no Open in.
    func testOnlyLinksTheShellOpensAreOffered() throws {
        let legacy = Support.event("legacy", title: "Legacy call", start: Support.at(12), end: Support.at(13),
                                   joinURL: "http://meet.example.com/abc", webURL: "http://calendar.example.com/event")
        let (column, state, _, window) = try column(events: [legacy], height: 900)
        defer { window.close(); state.tearDown() }
        column.timeline.activate(.event(try XCTUnwrap(state.events.first).id))
        let model = try XCTUnwrap(column.details.card?.model)
        XCTAssertTrue(model.actions.isEmpty, "no Join and no Open in Google Calendar that would do nothing")
        XCTAssertFalse(model.rows.contains { $0.label == "Call" })
        let join = try XCTUnwrap(column.timeline.subviews.compactMap { $0 as? QuireButton }.first)
        XCTAssertTrue(join.isHidden, "the event's own Join neither")
        XCTAssertNotNil(CalendarText.link("https://meet.google.com/abc-defg-hij"))
        XCTAssertNil(CalendarText.link("http://meet.example.com/abc"))
        XCTAssertNil(CalendarText.link("javascript:alert(1)"))
    }

    /// A click opens an event's details or shows a day, and the list keeps the keyboard (§5.54): neither view takes
    /// focus while AppKit handles a mouse-down; Tab still reaches both.
    func testAClickNeverTakesTheKeyboardFromTheList() throws {
        let (column, state, _, window) = try column()
        defer { window.close(); state.tearDown() }
        XCTAssertTrue(column.timeline.acceptsFirstResponder, "Tab reaches the events")
        XCTAssertTrue(column.cells.acceptsFirstResponder)
        try handling(.leftMouseDown, in: window) {
            XCTAssertFalse(column.timeline.acceptsFirstResponder, "a click leaves the keyboard where it was")
            XCTAssertFalse(column.cells.acceptsFirstResponder)
        }
        XCTAssertTrue(column.timeline.acceptsFirstResponder)
    }

    /// Runs `body` while `type` is the event AppKit is handling (`NSApp.currentEvent`), as during a click.
    private func handling(_ type: NSEvent.EventType, in window: NSWindow, _ body: () throws -> Void) throws {
        func take(_ event: NSEvent) {
            NSApp.postEvent(event, atStart: true)
            _ = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true)
        }
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                     pressure: 1))
        take(click)
        XCTAssertEqual(NSApp.currentEvent?.type, type)
        defer {
            // Something no view reads, so no later test sees a click being handled.
            if let quiet = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                take(quiet)
            }
        }
        try body()
    }

    /// Opened from the column over a narrow reader (a wide list in a small window), the details never hang past the
    /// reader area's leading edge, where clicks go to the list.
    func testDetailsOverANarrowReaderStayWhereClicksReachThem() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: Quire.Layout.Window.readerMinWidth + Quire.Layout.CalendarPane.stripWidth,
                                        height: 600))
        // The column over the reader's edge, just before the strip; its timeline after the hour gutter.
        let columnX = host.bounds.width - Quire.Layout.CalendarPane.stripWidth - Quire.Layout.CalendarPane.columnWidth
        let timeline = NSView(frame: NSRect(x: columnX + Quire.Layout.CalendarPane.hourGutterColumn, y: 0,
                                            width: Quire.Layout.CalendarPane.columnWidth - Quire.Layout.CalendarPane.hourGutterColumn,
                                            height: 600))
        host.addSubview(timeline)
        let frame = CalendarDetailsPresenter.frame(for: 160, anchor: NSRect(x: 0, y: 180, width: 180, height: 40), in: timeline,
                                                   host: host, placement: .leadingOfColumn)
        let inHost = host.convert(frame, from: timeline)
        XCTAssertGreaterThanOrEqual(inHost.minX, Quire.Layout.CalendarPane.detailsGap, "inside the reader area")
        XCTAssertEqual(inHost.width, Quire.Layout.CalendarPane.detailsWidth)
    }

    /// In the week at about 1,000 pt, a mid-week afternoon face has room on neither side and none under it: the card goes
    /// over it, never on it. Only when there is no room over it either does it move up onto the face.
    func testDetailsInTheWeekNeverCoverTheirEventWhileThereIsRoomOverIt() {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 700))
        let timeline = FlippedView(frame: NSRect(x: 340, y: 0, width: 600, height: 640))
        host.addSubview(timeline)
        let gap = Quire.Layout.CalendarPane.detailsGap
        let thursday = NSRect(x: 260, y: 430, width: 80, height: 50)
        let frame = CalendarDetailsPresenter.frame(for: 320, anchor: thursday, in: timeline, host: host, placement: .besideEvent)
        XCTAssertFalse(frame.intersects(thursday), "the face stays in sight")
        XCTAssertEqual(frame.maxY, thursday.minY - gap, "over it, the gap between")
        XCTAssertGreaterThanOrEqual(frame.minY, timeline.bounds.minY)

        let morning = NSRect(x: 260, y: 60, width: 80, height: 50)
        let under = CalendarDetailsPresenter.frame(for: 320, anchor: morning, in: timeline, host: host, placement: .besideEvent)
        XCTAssertEqual(under.minY, morning.maxY + gap, "under it while that fits")

        let tall = CalendarDetailsPresenter.frame(for: 560, anchor: thursday, in: timeline, host: host, placement: .besideEvent)
        XCTAssertGreaterThanOrEqual(tall.minY, timeline.bounds.minY, "neither fits: never above the timeline's top")
        let wide = CalendarDetailsPresenter.frame(for: 320, anchor: NSRect(x: 40, y: 430, width: 80, height: 50), in: timeline,
                                                  host: host, placement: .besideEvent)
        XCTAssertEqual(wide.minX, 40 + 80 + gap, "after the face when it fits")
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
        // One quiet load line per day: answered busy time, overlaps counted once, the unanswered invitation left out.
        let share = CalendarDayCellsView.busyShare(cells.cells[3])
        let answered = cells.cells[3].segments.filter { !$0.isHollow }
        XCTAssertGreaterThan(share, 0)
        XCTAssertLessThanOrEqual(share, answered.map(\.width).reduce(0, +) + 1e-9, "overlaps never counted twice")
        let overlapping = CalendarFit.DayCell(day: Support.day(19), segments: [
            .init(eventID: "a", accountID: AccountID("x"), start: 0.1, width: 0.2, isHollow: false),
            .init(eventID: "b", accountID: AccountID("y"), start: 0.2, width: 0.2, isHollow: false),
            .init(eventID: "c", accountID: AccountID("y"), start: 0.8, width: 0.1, isHollow: true),
        ], allDay: nil)
        XCTAssertEqual(CalendarDayCellsView.busyShare(overlapping), 0.3, accuracy: 1e-9)
        XCTAssertEqual(CalendarDayCellsView.busyShare(CalendarFit.DayCell(day: Support.day(19), segments: [], allDay: nil)), 0)
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
        // One calendar button in the week's header: it goes back to the day.
        week.header.day.performClick(nil)
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
        XCTAssertTrue(Support.spin(until: { week.selectionDetails != nil }))
        let card = try XCTUnwrap(week.selectionDetails)
        let model = try XCTUnwrap(card.model)
        XCTAssertTrue(model.kicker.hasSuffix(" · Invitation · Not answered"), model.kicker)
        XCTAssertEqual(model.rows.first { $0.label == "Where" }?.lines.first?.first?.text, "Bay 4")
        XCTAssertEqual(model.rows.first { $0.label == "Organizer" }?.lines.first?.first?.text, "Rachel Kim")
        XCTAssertEqual(model.overlap, "Overlaps Roadmap review, 13:30 - 14:00, and 1 more", "the first overlap by start, and how many more")
        XCTAssertEqual(Array(card.buttons.map(\.title).prefix(3)), ["Accept", "Tentative", "Decline"])
        let pencil = try XCTUnwrap(week.timeline.placed.first { CalendarFit.isPencil($0.event) })
        let cardInTimeline = week.timeline.convert(card.frame, from: week)
        XCTAssertFalse(cardInTimeline.intersects(pencil.face), "beside its slot, never on it")
        card.buttons[0].performClick(nil)
        XCTAssertEqual(delegate.answers.map(\.0), [.accepted])
        XCTAssertEqual(delegate.answers.map(\.1), [message])

        XCTAssertTrue(week.hideSelectionDetails(), "Esc hides it")
        XCTAssertNil(week.selectionDetails)
        XCTAssertFalse(week.hideSelectionDetails())
        try click(week.timeline, at: centre(pencil.face))
        XCTAssertNotNil(week.selectionDetails, "a click on its event brings it back")
        XCTAssertTrue(delegate.selectedConversations.isEmpty, "that click only brings the card back")
    }

    /// The week's card says what its invitation overlaps in the reader card's words (§5.14), and says nothing once the
    /// user declines on this Mac, though the calendar's copy still says not answered until the next read.
    func testTheWeeksCardSaysItsOverlapAsTheReadersCardDoes() throws {
        let store = try Support.store()
        let invitation = CalendarInvitation(method: .request, uid: "mail-uid", title: "Design review", start: Support.at(13, 30),
                                            end: Support.at(14, 30), organizer: .init(name: "Rachel Kim", address: "rachel@contoso.test"),
                                            userAddress: Support.accountA.email, userResponse: .needsAction)
        try Support.write([
            Support.event("untitled", title: "", start: Support.at(13), end: Support.at(14)),
            Support.event("copy", title: "Design review", start: Support.at(13, 30), end: Support.at(14, 30), response: .needsAction,
                          invitationUID: "mail-uid"),
        ], to: store)
        let state = Support.state(store: store)
        defer { state.tearDown() }
        func card(_ response: CalendarEvent.Response) throws -> EventDetailsModel {
            var copy = try XCTUnwrap(state.events.first { $0.invitationUID == "mail-uid" })
            copy.response = response
            let overlap = CalendarFit.invitationOverlap(uid: invitation.uid, near: copy.start, in: state.events, pencil: nil,
                                                        accountID: copy.accountID)
            let words = WeekOverlapWords.line(overlap, startingOn: copy.start, state: state)
            return EventDetailsModel(.init(event: copy, accountName: "Contoso", overlap: words, text: state.text, now: state.now))
        }
        XCTAssertEqual(try card(.needsAction).overlap, "Overlaps an event with no title, 13:30 - 14:00")
        let declined = try card(.declined)
        XCTAssertEqual(declined.kicker, "Contoso · Declined")
        XCTAssertNil(declined.overlap, "it goes the moment the user declines")
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
        XCTAssertEqual(column.keyViews.count, 5, "‹ › and the week button (Today is disabled on today), the cells, the events; no foot")
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
        XCTAssertEqual(CalendarMarkPainter.toolTip(for: send, text: state.text), "Sends at 16:00 While Paper Is Open")
    }
}

/// A flipped plain view, as the timeline is: y grows downwards.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
