import AppKit
import PaperCore
import PaperDesign
import XCTest
@testable import PaperApp

/// `CalendarState` (spec §5.54): it follows the store for the shown days and only those, gathers what the fit lays out
/// (the scope's events, Later and Send Later, the selected mail's times and invitation), and keeps the minute tick to
/// when a calendar is on screen.
@MainActor
final class CalendarStateTests: XCTestCase {
    private typealias Support = CalendarTestSupport

    private final class Recorder: CalendarStateObserver {
        var changes: [CalendarChange] = []
        func calendarState(_ state: CalendarState, didChange change: CalendarChange) { changes.append(change) }
        var sawContent: Bool { changes.contains { $0.contains(.content) } }
    }

    private let conversation = ConversationID(accountID: Support.accountA.id, providerID: "thread-invite")
    private var message: MessageID { MessageID(accountID: Support.accountA.id, providerID: "msg-invite") }

    /// A conversation of one message, archived (so it can be snoozed), carrying `invitation` when given.
    private func seedConversation(in store: InMemoryMailStore, subject: String = "Design review",
                                  invitation: CalendarInvitation? = nil, reply: InvitationResponse? = nil) throws {
        try store.upsertMessages([MessageMetadata(
            id: message, conversationID: conversation, subject: subject, snippet: "", from: nil,
            to: [EmailAddress(name: nil, address: Support.accountA.email)], date: Support.at(8), roles: [],
            isRead: true, isStarred: false, hasAttachments: false, invitationReply: reply)])
        if let invitation {
            try store.saveBody(StoredBody(body: MessageBody(html: nil, text: "Invitation"), renderedHTML: "", plainText: "Invitation",
                                          invitation: invitation), for: message)
        }
    }

    private func invitation(uid: String = "review-uid", start: Date = Support.at(13, 15), end: Date = Support.at(13, 45),
                            userResponse: InvitationResponse? = .needsAction) -> CalendarInvitation {
        CalendarInvitation(method: .request, uid: uid, title: "Design review", start: start, end: end,
                           location: "Bay 4", organizer: .init(name: "Rachel Kim", address: "rachel@contoso.test"),
                           userAddress: Support.accountA.email, userResponse: userResponse)
    }

    // MARK: The store

    func testTheStateFollowsTheStore() throws {
        let store = try Support.store()
        let state = Support.state(store: store)
        defer { state.tearDown() }
        let recorder = Recorder()
        state.addObserver(recorder)
        XCTAssertTrue(state.events.isEmpty)

        try Support.write([Support.event("review", title: "Roadmap review", start: Support.at(13), end: Support.at(14))], to: store)
        XCTAssertEqual(state.events.map(\.title), ["Roadmap review"], "the store's observation delivers on the main thread")
        XCTAssertTrue(recorder.sawContent)
        XCTAssertEqual(state.content(for: [Support.today]).events.map(\.title), ["Roadmap review"])

        // Time set aside: drawn at once, as the store holds it.
        let block = CalendarEvent(id: CalendarEvent.newLocalID(accountID: Support.accountA.id), accountID: Support.accountA.id,
                                  providerID: nil, title: "Lease renewal", start: Support.at(15), end: Support.at(15, 30),
                                  sourceMessage: message, sync: .creating)
        try store.addCalendarEvent(block)
        XCTAssertEqual(Set(state.content(for: [Support.today]).events.map(\.title)), ["Roadmap review", "Lease renewal"])

        // Removed: being deleted is never drawn.
        let review = try XCTUnwrap(state.events.first { $0.title == "Roadmap review" })
        try store.removeCalendarEvent(id: review.id)
        XCTAssertEqual(state.content(for: [Support.today]).events.map(\.title), ["Lease renewal"])
    }

    func testTheRangeIsReadAgainOnlyWhenTheShownDaysLeaveIt() throws {
        let store = try Support.store()
        let later = Support.event("later", title: "Planning", start: Support.at(10, on: Support.day(10, month: 12)),
                                  end: Support.at(11, on: Support.day(10, month: 12)))
        try Support.write([later, Support.event("today", title: "Today's", start: Support.at(13), end: Support.at(14))], to: store)
        let state = Support.state(store: store)
        defer { state.tearDown() }
        let range = try XCTUnwrap(state.observedRange)
        XCTAssertTrue(range.contains(Support.day(9)) && range.contains(Support.day(29)), "the shown week with a week either side")
        XCTAssertFalse(state.events.contains { $0.title == "Planning" }, "three weeks out is not read")

        state.shownDay = Support.day(20)
        XCTAssertEqual(state.observedRange, range, "a turn within the week reads nothing")
        state.shownDay = Support.day(24)
        XCTAssertEqual(state.observedRange, range, "next week is inside the range already")

        state.shownDay = Support.day(10, month: 12)
        let moved = try XCTUnwrap(state.observedRange)
        XCTAssertNotEqual(moved, range)
        XCTAssertTrue(moved.contains(Support.day(10, month: 12)))
        XCTAssertTrue(state.events.contains { $0.title == "Planning" }, "the new range is read at once")
        XCTAssertEqual(state.content(for: [state.shownDay]).events.map(\.title), ["Planning"])

        // A write in the range left behind wakes nothing here any more.
        state.shownDay = Support.today
        state.span = .week
        state.shownWeek = Support.day(10, month: 12)
        XCTAssertTrue(try XCTUnwrap(state.observedRange).contains(Support.day(7, month: 12)), "the week view's days are observed")
        XCTAssertEqual(state.shownWeekDays.first, Support.day(7, month: 12), "the week starts on Monday")
    }

    func testTheScopeNarrowsToOneAccount() throws {
        let store = try Support.store()
        try Support.write(Support.sampleWeek(), to: store)
        let state = Support.state(store: store)
        defer { state.tearDown() }
        let all = state.content(for: [Support.today]).events
        XCTAssertTrue(all.contains { $0.accountID == Support.accountA.id } && all.contains { $0.accountID == Support.accountB.id })
        XCTAssertFalse(all.contains { $0.response == .declined }, "declined events are never laid out")
        state.scope = .account(Support.accountA.id)
        let one = state.content(for: [Support.today]).events
        XCTAssertFalse(one.isEmpty)
        XCTAssertTrue(one.allSatisfy { $0.accountID == Support.accountA.id })
    }

    // MARK: Marks

    func testLaterAndSendLaterAreMarkedOnTheirDay() throws {
        let store = try Support.store()
        try seedConversation(in: store, subject: "Lease renewal")
        try store.setSnoozes([Snooze.Change(conversationID: conversation, until: Support.at(17))], enqueueing: [], at: Support.at(8))
        let outgoing = OutgoingMessage(accountID: Support.accountB.id, to: [EmailAddress(name: nil, address: "sam@example.com")],
                                       subject: "Follow-up", html: "", text: "")
        try store.enqueueSend(PendingSend(id: "send-1", message: outgoing, sendAfter: Support.at(16), status: .later))
        let state = Support.state(store: store)
        defer { state.tearDown() }
        XCTAssertTrue(Support.spin(until: { state.content(for: [Support.today]).marks.contains { $0.title == "Lease renewal" } }),
                      "Later's subject is read off the main thread")
        let marks = state.content(for: [Support.today]).marks
        XCTAssertEqual(marks.count, 2)
        XCTAssertTrue(marks.contains { $0.kind == .later(conversation) && $0.start == Support.at(17) })
        XCTAssertTrue(marks.contains { $0.kind == .sendLater(id: "send-1", accountID: Support.accountB.id) && $0.title == "Follow-up" })
        XCTAssertTrue(state.content(for: [Support.day(20)]).marks.isEmpty, "only on their day")
        state.scope = .account(Support.accountA.id)
        XCTAssertEqual(state.content(for: [Support.today]).marks.map(\.title), ["Lease renewal"], "the scope applies to marks")

        // The fit opens their hours.
        let fit = CalendarFit(days: [Support.today], events: [], marks: state.content(for: [Support.today]).fitMarks, height: 600,
                              width: 196, calendar: Support.calendar, metrics: CalendarMetrics.fit)
        XCTAssertEqual(fit.marks.count, 1)
    }

    func testTheSelectedMailsTimesAreMarkedUntilTimeIsSetAsideThere() throws {
        let store = try Support.store()
        try seedConversation(in: store)
        try store.saveMailTimes([MailTime(messageID: message, start: Support.at(15), phrase: "Thursday at 3pm"),
                                 MailTime(messageID: message, start: Support.at(9), phrase: "9am, already past"),
                                 MailTime(messageID: message, start: Support.at(14, on: Support.day(20)), duration: 3_600,
                                          phrase: "Friday 2 to 3pm")], for: message)
        let state = Support.state(store: store)
        defer { state.tearDown() }
        XCTAssertTrue(state.content(for: [Support.today]).marks.isEmpty)
        state.select(conversation)
        XCTAssertTrue(Support.spin(until: { state.selection != nil }), "the selection is read off the main thread")
        XCTAssertEqual(state.selection?.mailTimes.count, 3)
        let marks = state.content(for: [Support.today]).marks
        XCTAssertEqual(marks.map(\.start), [Support.at(15)], "only times still ahead")
        XCTAssertEqual(marks.first?.span, CalendarState.blockLength, "a time with no length keeps 30 minutes open")
        XCTAssertEqual(state.content(for: [Support.day(20)]).marks.first?.span, 3_600, "the length the mail names")
        XCTAssertEqual(state.selectionDay, Support.today, "no invitation: the day of the first time it names that is ahead")

        // Set aside at that time: the mark goes, and the block carries the margin rule.
        let block = CalendarEvent(id: CalendarEvent.newLocalID(accountID: Support.accountA.id), accountID: Support.accountA.id,
                                  providerID: nil, title: "Design review", start: Support.at(15), end: Support.at(15, 30),
                                  sourceMessage: message, sync: .creating)
        try store.addCalendarEvent(block)
        let content = state.content(for: [Support.today])
        XCTAssertTrue(content.marks.isEmpty)
        XCTAssertEqual(content.selectedEventIDs, [block.id])

        // Another selection takes it all away.
        state.select(nil)
        XCTAssertTrue(state.content(for: [Support.today]).selectedEventIDs.isEmpty)
    }

    // MARK: The selected invitation

    func testTheInvitationIsPencilledOnlyWhileNoEventHasItsUID() throws {
        let store = try Support.store()
        try Support.write([Support.event("review", title: "Roadmap review", start: Support.at(13), end: Support.at(14))], to: store)
        try seedConversation(in: store, invitation: invitation())
        let state = Support.state(store: store)
        defer { state.tearDown() }
        state.select(conversation)
        XCTAssertTrue(Support.spin(until: { state.selection?.invitation != nil }))
        XCTAssertEqual(state.selectionDay, Support.today, "J and K turn the column to the invitation's day")

        var content = state.content(for: [Support.today])
        let pencilID = try XCTUnwrap(content.pencilID)
        XCTAssertTrue(CalendarFit.isPencil(try XCTUnwrap(content.events.first { $0.id == pencilID })))
        XCTAssertTrue(content.selectedEventIDs.contains(pencilID), "the pencil carries the margin rule")
        XCTAssertEqual(content.hatches[pencilID], [DateInterval(start: Support.at(13, 15), end: Support.at(13, 45))],
                       "hatched over the time it shares")
        XCTAssertEqual(content.overlapTitles[pencilID], ["Roadmap review"])

        // The provider's copy arrives: drawn once, as the calendar has it.
        let copy = Support.event("design", title: "Design review", start: Support.at(13, 15), end: Support.at(13, 45),
                                 response: .needsAction, invitationUID: "review-uid")
        try Support.write([Support.event("review", title: "Roadmap review", start: Support.at(13), end: Support.at(14)), copy], to: store)
        content = state.content(for: [Support.today])
        XCTAssertNil(content.pencilID)
        XCTAssertFalse(content.events.contains { CalendarFit.isPencil($0) })
        XCTAssertTrue(content.selectedEventIDs.contains(copy.id))
        XCTAssertEqual(content.hatches[copy.id]?.count, 1, "its own UID is never an overlap")
    }

    func testDeclinedIsNeverDrawnNorOverlapped() throws {
        let store = try Support.store()
        try Support.write([
            Support.event("vendor", title: "Vendor demo", start: Support.at(13), end: Support.at(14), response: .declined),
            Support.event("focus", title: "Focus", start: Support.at(13), end: Support.at(14), isFree: true),
            Support.event("offsite", title: "Offsite", start: Support.floating(19), end: Support.floating(20), isAllDay: true),
        ], to: store)
        try seedConversation(in: store, invitation: invitation(), reply: nil)
        let state = Support.state(store: store)
        defer { state.tearDown() }
        state.select(conversation)
        XCTAssertTrue(Support.spin(until: { state.selection?.invitation != nil }))
        let content = state.content(for: [Support.today])
        XCTAssertFalse(content.events.contains { $0.title == "Vendor demo" })
        let pencilID = try XCTUnwrap(content.pencilID)
        XCTAssertNil(content.hatches[pencilID], "declined, free and all-day events are no overlap")

    }

    func testAnInvitationTheUserDeclinedIsNotPencilled() throws {
        let store = try Support.store()
        try seedConversation(in: store, invitation: invitation(userResponse: .declined))
        let state = Support.state(store: store)
        defer { state.tearDown() }
        state.select(conversation)
        XCTAssertTrue(Support.spin(until: { state.selection?.invitation != nil }))
        XCTAssertEqual(state.selection?.response, .declined)
        XCTAssertNil(state.content(for: [Support.today]).pencilID)
        XCTAssertFalse(state.content(for: [Support.today]).events.contains { CalendarFit.isPencil($0) })
    }

    func testANewerRevisionArrivingInTheConversationMovesThePencil() throws {
        let store = try Support.store()
        try seedConversation(in: store, invitation: invitation())
        let state = Support.state(store: store)
        defer { state.tearDown() }
        state.select(conversation)
        XCTAssertTrue(Support.spin(until: { state.selection?.invitation != nil }))
        XCTAssertEqual(state.selectionPencil?.start, Support.at(13, 15))

        // The organizer moves it: a later message carries SEQUENCE 1. The conversation's observation reads it again.
        let update = MessageID(accountID: Support.accountA.id, providerID: "msg-update")
        try store.upsertMessages([MessageMetadata(
            id: update, conversationID: conversation, subject: "Updated: Design review", snippet: "", from: nil,
            to: [EmailAddress(name: nil, address: Support.accountA.email)], date: Support.at(9), roles: [],
            isRead: true, isStarred: false, hasAttachments: false)])
        var moved = invitation(start: Support.at(16), end: Support.at(16, 30))
        moved.sequence = 1
        try store.saveBody(StoredBody(body: MessageBody(html: nil, text: ""), renderedHTML: "", plainText: "", invitation: moved),
                           for: update)
        state.reloadSelection()
        XCTAssertTrue(Support.spin(until: { state.selectionPencil?.start == Support.at(16) }), "the newest revision is drawn")
        XCTAssertEqual(state.selection?.invitationMessage, update, "and it is the one an answer names")
    }

    // MARK: Statuses

    func testAnAccountWithoutTheCalendarPermissionIsOfferedConnect() throws {
        let store = try Support.store()
        let statuses: CalendarState.StatusObserver = { onChange in
            onChange([AccountSyncStatus(accountID: Support.accountA.id, phase: .idle, calendar: .notConnected),
                      AccountSyncStatus(accountID: Support.accountB.id, phase: .idle, calendar: .current(Support.at(11)))])
            return StoreObservation {}
        }
        let state = Support.state(store: store, observeStatus: statuses)
        defer { state.tearDown() }
        XCTAssertEqual(state.accountsToConnect, [Support.accountA.id])
        XCTAssertTrue(state.accountsWithCalendarAPIOff.isEmpty)

        let delegate = RecordingCalendarDelegate()
        let column = DayColumnView(state: state)
        column.delegate = delegate
        let window = Support.host(column, size: NSSize(width: 240, height: 700))
        defer { window.close() }
        XCTAssertFalse(column.foot.isHidden)
        XCTAssertEqual(column.foot.connectMessage, "Show events from your calendars")
        XCTAssertGreaterThan(column.foot.frame.height, 0)
        XCTAssertEqual(column.timeline.frame.maxY, column.foot.frame.minY, "the fit takes the foot's height off first")
        let connect = try XCTUnwrap(column.foot.keyViews.first as? QuireButton)
        connect.performClick(nil)
        XCTAssertEqual(delegate.connected, [[Support.accountA.id]])
        state.isConnecting = true
        XCTAssertTrue(connect.isLoading, "Connect shows its loading state while an account is asked")
    }

    // MARK: Now

    func testTheMinuteTickRunsOnlyWhileACalendarIsOnScreen() throws {
        let store = try Support.store()
        let state = Support.state(store: store)
        defer { state.tearDown() }
        state.clock.visibilityOverride = true
        let column = DayColumnView(state: state)
        XCTAssertFalse(state.clock.isTicking, "not in a window")
        let window = Support.host(column, size: NSSize(width: 240, height: 700))
        defer { window.close() }
        XCTAssertTrue(state.clock.isTicking)
        column.isHidden = true
        XCTAssertFalse(state.clock.isTicking, "hidden")
        column.isHidden = false
        XCTAssertTrue(state.clock.isTicking)
        state.clock.visibilityOverride = false
        XCTAssertFalse(state.clock.isTicking, "the window is covered or minimised")
        state.clock.visibilityOverride = true
        XCTAssertTrue(state.clock.isTicking)
        column.removeFromSuperview()
        XCTAssertFalse(state.clock.isTicking, "out of the window")
    }

    func testATickMovesTheNowLineAndMidnightTurnsTheDay() throws {
        let store = try Support.store()
        try Support.write([Support.event("review", title: "Roadmap review", start: Support.at(13), end: Support.at(14))], to: store)
        let clock = Support.Clock()
        let state = Support.state(store: store, clock: clock)
        defer { state.tearDown() }
        let recorder = Recorder()
        state.addObserver(recorder)
        let column = DayColumnView(state: state)
        let window = Support.host(column, size: NSSize(width: 240, height: 800))
        defer { window.close() }
        let before = try XCTUnwrap(column.timeline.nowY)
        let fitVersion = column.timeline.content.version

        clock.now = Support.at(12, 40)
        state.clock.tick()
        XCTAssertEqual(recorder.changes.last, .now, "a minute is only the now line")
        XCTAssertGreaterThan(try XCTUnwrap(column.timeline.nowY), before)
        XCTAssertEqual(column.timeline.content.version, fitVersion, "a tick never refits")

        clock.now = Support.at(0, 1, on: Support.day(20))
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        XCTAssertTrue(recorder.changes.last?.contains(.day) == true)
        XCTAssertEqual(state.shownDay, Support.day(20), "a column that showed today turns to the new today")
        XCTAssertEqual(state.shownWeek, Support.day(20), "and so does a week that showed this week")
        XCTAssertEqual(column.header.kicker, "Today")
        XCTAssertNotNil(column.timeline.nowY, "with its now line")

        // A day the user turned to stays where it is.
        state.shownDay = Support.day(24)
        state.shownWeek = Support.day(30)
        clock.now = Support.at(0, 1, on: Support.day(21))
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        XCTAssertEqual(state.shownDay, Support.day(24))
        XCTAssertEqual(state.shownWeek, Support.day(30))
        XCTAssertEqual(column.header.kicker, "Next week")
    }

    // MARK: Speed

    /// The calendar looks at a conversation's invitations on every J and K: it reads them alone, never a whole body.
    func testTheSelectionDecompressesNoBody() throws {
        let base = try Support.store()
        try seedConversation(in: base, invitation: invitation())
        let store = PageFailingStore(base: base)
        let read = CalendarSelection.read(conversation, from: store)
        XCTAssertEqual(read.invitation?.uid, "review-uid")
        XCTAssertEqual(store.bodyReads, 0)
    }

    /// The store reports every write to the messages table, whichever conversation it touched: only a change to what the
    /// selection's read uses reads it again.
    func testOnlyAChangeToTheSelectedConversationReadsItAgain() throws {
        let base = try Support.store()
        try seedConversation(in: base, invitation: invitation())
        let store = PageFailingStore(base: base)
        let state = Support.state(store: store)
        defer { state.tearDown() }
        state.select(conversation)
        XCTAssertTrue(Support.spin(until: { state.selection?.invitation != nil }))
        XCTAssertEqual(store.mailTimeReads, 1)

        let other = ConversationID(accountID: Support.accountB.id, providerID: "thread-other")
        for index in 0..<20 {
            try base.upsertMessages([MessageMetadata(
                id: MessageID(accountID: Support.accountB.id, providerID: "other-\(index)"), conversationID: other,
                subject: "Elsewhere", snippet: "", from: nil, date: Support.at(7), roles: [.inbox], isRead: false,
                isStarred: false, hasAttachments: false)])
        }
        var starred = try XCTUnwrap(try base.message(message))
        starred.isStarred = true
        try base.upsertMessages([starred])
        Support.spin(until: { false }, timeout: 0.3)
        XCTAssertEqual(store.mailTimeReads, 1, "other conversations and a star change nothing the calendar draws")

        let reply = MessageID(accountID: Support.accountA.id, providerID: "msg-reply")
        try base.upsertMessages([MessageMetadata(
            id: reply, conversationID: conversation, subject: "Re: Design review", snippet: "", from: nil, date: Support.at(9),
            roles: [], isRead: true, isStarred: false, hasAttachments: false)])
        XCTAssertTrue(Support.spin(until: { store.mailTimeReads == 2 }), "a new message in it is read")
        XCTAssertTrue(Support.spin(until: { state.selection?.subject == "Re: Design review" }))
    }

    /// A calendar coming on screen reads the selection at once, so it shows its day in its first frame.
    func testSelectingAtOnceReadsTheContextWithoutAWait() throws {
        let store = try Support.store()
        try seedConversation(in: store, invitation: invitation(start: Support.at(10, on: Support.day(24)), end: Support.at(11, on: Support.day(24))))
        let state = Support.state(store: store)
        defer { state.tearDown() }
        state.select(conversation, readNow: true)
        XCTAssertEqual(state.selection?.conversationID, conversation)
        XCTAssertEqual(state.selectionDay, Support.day(24))
    }

    /// Every read republishes `.current` at a new instant: the views are told only when what they show changes.
    func testANewReadTimeTellsTheViewsNothing() throws {
        let store = try Support.store()
        var publish: (@Sendable ([AccountSyncStatus]) -> Void)?
        let statuses: CalendarState.StatusObserver = { onChange in
            publish = onChange
            onChange([AccountSyncStatus(accountID: Support.accountA.id, phase: .idle, calendar: .current(Support.at(11)))])
            return StoreObservation {}
        }
        let state = Support.state(store: store, observeStatus: statuses)
        defer { state.tearDown() }
        let recorder = Recorder()
        state.addObserver(recorder)
        let send = try XCTUnwrap(publish)
        send([AccountSyncStatus(accountID: Support.accountA.id, phase: .idle, calendar: .current(Support.at(11, 1)))])
        send([AccountSyncStatus(accountID: Support.accountA.id, phase: .idle, calendar: .failing(lastRead: Support.at(11, 1)))])
        send([AccountSyncStatus(accountID: Support.accountA.id, phase: .idle, calendar: .failing(lastRead: Support.at(11, 2)))])
        XCTAssertEqual(recorder.changes.filter { $0.contains(.statuses) }.count, 1, "only the turn to failing")
        send([AccountSyncStatus(accountID: Support.accountA.id, phase: .idle, calendar: .notConnected)])
        XCTAssertEqual(recorder.changes.filter { $0.contains(.statuses) }.count, 2)
        XCTAssertEqual(state.accountsToConnect, [Support.accountA.id])
    }
}
