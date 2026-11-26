import Foundation
import XCTest
@testable import PaperCore

/// Answering an event from its details (docs/ARCHITECTURE.md, "Calendar invitations" › Answering): through the
/// invitation's message when it names exactly the span answered and still describes the event, else on the calendar
/// with no message; store first, queued, the route returned.
final class MailEngineCalendarAnswerTests: XCTestCase {
    private let message = MessageID(accountID: Fixtures.accountID, providerID: "2")
    private let start = Fixtures.baseDate.addingTimeInterval(86_400)

    private func event(_ providerID: String, series: String? = nil, start offset: TimeInterval = 0,
                       response: CalendarEvent.Response = .needsAction, sync: CalendarEvent.Sync = .synced,
                       kind: CalendarEvent.Kind? = nil, source: MessageID? = nil) -> CalendarEvent {
        CalendarEvent(id: CalendarEvent.localID(accountID: Fixtures.accountID, providerID: providerID), accountID: Fixtures.accountID,
                      providerID: providerID, title: "Design review", start: start.addingTimeInterval(offset),
                      end: start.addingTimeInterval(offset + 3_600), response: response, organizer: "Ben Carter",
                      invitationUID: "uid-1@google.com", sourceMessage: source, sync: sync, seriesID: series,
                      originalStart: series == nil ? nil : start.addingTimeInterval(offset), kind: kind)
    }

    private func invitation(recurrenceID: Date? = nil, repeats: String? = nil, start: Date? = nil) -> CalendarInvitation {
        let first = start ?? self.start
        return CalendarInvitation(
            method: .request, uid: "uid-1@google.com", sequence: 3, recurrenceID: recurrenceID, title: "Design review",
            start: first, end: first.addingTimeInterval(3_600),
            organizer: CalendarInvitation.Person(name: "Ben Carter", address: "ben@example.com"),
            attendees: [CalendarInvitation.Person(name: "Me Myself", address: "me@example.com", response: .needsAction)],
            repeats: repeats, userAddress: "me@example.com", userResponse: .needsAction)
    }

    private func harness(events: [CalendarEvent], invitation: CalendarInvitation? = nil,
                         permission: AccountPermission? = .calendar) async throws -> EngineHarness {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [["": .success(Fixtures.page(1...3, next: nil, cursor: "c0"))]]
        // Held for the permission unless a test grants it, so what was queued can be read before it goes.
        provider.permissionNeeded = permission
        let harness = try EngineHarness(provider: provider)
        harness.engine.start()
        try await waitUntil("bootstrap complete") { try harness.store.syncCursor(for: Fixtures.accountID) == "c0" }
        if let invitation {
            try harness.store.saveBody(StoredBody(body: MessageBody(html: "<p>Invite</p>", text: nil), renderedHTML: "<p>Invite</p>",
                                                  plainText: "Invite", invitation: invitation), for: message)
        }
        try harness.store.replaceCalendarEvents(events, accountID: Fixtures.accountID,
                                                window: DateInterval(start: start.addingTimeInterval(-86_400), duration: 30 * 86_400))
        return harness
    }

    private func queuedAnswers(_ harness: EngineHarness) throws -> [(answer: InvitationAnswer, targets: [MessageID])] {
        try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 20).compactMap { operation in
            guard case .answerInvitation(let answer) = operation.change else { return nil }
            return (answer, operation.targets)
        }
    }

    func testWithNoMailTheAnswerIsQueuedOnTheCalendarAndSentOnce() async throws {
        let single = event("evt")
        let harness = try await harness(events: [single], permission: nil)
        let route = try harness.engine.answerCalendarEvent(.accepted, eventID: single.id, span: .occurrence, invitationMessage: nil)
        XCTAssertEqual(route, .calendar)
        XCTAssertEqual(try harness.store.calendarEvent(id: single.id)?.response, .accepted, "store first")
        try await waitUntil("sent") { harness.provider.applyCalls.count == 1 }
        let call = try XCTUnwrap(harness.provider.applyCalls.first)
        XCTAssertEqual(call.ids, [])
        guard case .answerInvitation(let answer) = call.change else { return XCTFail("not an answer") }
        XCTAssertEqual(answer.calendar?.providerEventID, "evt")
        XCTAssertEqual(answer.calendar?.scope, .event(id: single.id), "a single event is answered as one")
        XCTAssertEqual(answer.previous, .needsAction)
        XCTAssertEqual(answer.attendee.address, "me@example.com")
        XCTAssertNil(answer.graphEventID, "Gmail names the event by the calendar part alone")
        XCTAssertNotNil(answer.replyID)
        try await waitUntil("confirmed") { try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10).isEmpty }
        XCTAssertEqual(harness.provider.applyCalls.count, 1)
        await harness.shutdown()
    }

    func testTheSameAnswerTwiceQueuesNothing() async throws {
        let single = event("evt", response: .accepted)
        let harness = try await harness(events: [single])
        XCTAssertNil(try harness.engine.answerCalendarEvent(.accepted, eventID: single.id, span: .single, invitationMessage: nil))
        XCTAssertTrue(try queuedAnswers(harness).isEmpty)
        await harness.shutdown()
    }

    func testAllEventsCoversEveryOccurrenceAndNamesTheSeries() async throws {
        let rows = [event("s1", series: "S"), event("s2", series: "S", start: 7 * 86_400, response: .tentative),
                    event("s3", series: "S", start: 14 * 86_400)]
        let harness = try await harness(events: rows)
        XCTAssertEqual(try harness.engine.answerCalendarEvent(.declined, eventID: rows[1].id, span: .series, invitationMessage: nil),
                       .calendar)
        XCTAssertEqual(try rows.map { try harness.store.calendarEvent(id: $0.id)?.response }, [.declined, .declined, .declined])
        let queued = try XCTUnwrap(try queuedAnswers(harness).first)
        XCTAssertEqual(queued.answer.calendar?.scope, .series(id: "S"))
        XCTAssertEqual(queued.answer.calendar?.providerEventID, "S", "the series, not the occurrence")
        XCTAssertEqual(queued.targets, [])
        await harness.shutdown()
    }

    func testTheMailRouteWhenTheMailNamesTheSpanAndStillDescribesTheEvent() async throws {
        let single = event("evt")
        let harness = try await harness(events: [single], invitation: invitation())
        XCTAssertEqual(try harness.engine.answerCalendarEvent(.tentative, eventID: single.id, span: .single, invitationMessage: message),
                       .mail)
        let queued = try XCTUnwrap(try queuedAnswers(harness).first)
        XCTAssertEqual(queued.targets, [message])
        XCTAssertNil(queued.answer.calendar?.providerEventID)
        XCTAssertEqual(try harness.store.message(message)?.invitationReply, .tentative)
        XCTAssertEqual(try harness.store.calendarEvent(id: single.id)?.response, .tentative)
        XCTAssertNil(try harness.engine.answerCalendarEvent(.tentative, eventID: single.id, span: .single, invitationMessage: message),
                     "the mail already says it")
        await harness.shutdown()
    }

    func testAMailToTheSeriesAnswersAllEventsButNotThisEvent() async throws {
        let rows = [event("s1", series: "S"), event("s2", series: "S", start: 7 * 86_400)]
        let harness = try await harness(events: rows, invitation: invitation(repeats: "Every week"))
        XCTAssertEqual(try harness.engine.answerCalendarEvent(.accepted, eventID: rows[1].id, span: .occurrence,
                                                              invitationMessage: message), .calendar, "This Event: not the mail's span")
        XCTAssertEqual(try harness.engine.answerCalendarEvent(.declined, eventID: rows[1].id, span: .series,
                                                              invitationMessage: message), .mail)
        await harness.shutdown()
    }

    func testAMailToOneOccurrenceAnswersThatOccurrence() async throws {
        let rows = [event("s1", series: "S"), event("s2", series: "S", start: 7 * 86_400)]
        let harness = try await harness(events: rows, invitation: invitation(recurrenceID: start.addingTimeInterval(7 * 86_400),
                                                                             start: start.addingTimeInterval(7 * 86_400)))
        XCTAssertEqual(try harness.engine.answerCalendarEvent(.accepted, eventID: rows[1].id, span: .occurrence,
                                                              invitationMessage: message), .mail)
        XCTAssertEqual(try harness.engine.answerCalendarEvent(.accepted, eventID: rows[0].id, span: .occurrence,
                                                              invitationMessage: message), .calendar, "another occurrence")
        await harness.shutdown()
    }

    func testAMovedEventOrAnEvictedMailTakesTheCalendar() async throws {
        let moved = event("evt")
        let harness = try await harness(events: [moved], invitation: invitation(start: start.addingTimeInterval(-3_600)))
        XCTAssertEqual(try harness.engine.answerCalendarEvent(.accepted, eventID: moved.id, span: .single, invitationMessage: message),
                       .calendar, "the mail no longer describes the event")
        await harness.shutdown()

        let kept = event("evt2")
        let evicted = try await self.harness(events: [kept], invitation: nil)
        XCTAssertEqual(try evicted.engine.answerCalendarEvent(.accepted, eventID: kept.id, span: .single, invitationMessage: message),
                       .calendar, "no invitation to read: the body went")
        await evicted.shutdown()
    }

    /// The user accepted in Paper, then changed to Tentative on the phone: the message still carries the old reply, but
    /// both cards show Tentative, and Accept from either goes out again.
    func testAnOlderReplyOnTheMailNeverRefusesAnAnswerTheCalendarNoLongerSays() async throws {
        let single = event("evt")
        let window = DateInterval(start: start.addingTimeInterval(-86_400), duration: 30 * 86_400)
        let harness = try await harness(events: [single], invitation: invitation())
        func sentAndTheTentativeOnThePhone() throws {
            for operation in try harness.store.pendingOperations(accountID: Fixtures.accountID, limit: 10) {
                try harness.store.confirmOperation(id: operation.id)
            }
            var phone = single
            phone.response = .tentative
            try harness.store.replaceCalendarEvents([phone], accountID: Fixtures.accountID, window: window)
        }
        XCTAssertTrue(try harness.engine.answerInvitation(.accepted, to: message))
        try sentAndTheTentativeOnThePhone()
        XCTAssertEqual(try harness.store.message(message)?.invitationReply, .accepted)
        XCTAssertEqual(try harness.store.calendarEvent(id: single.id)?.response, .tentative)

        // From the details: the mail's span, so through the mail, though the mail's reply already says Accept.
        XCTAssertEqual(try harness.engine.answerCalendarEvent(.accepted, eventID: single.id, span: .single, invitationMessage: message),
                       .mail)
        XCTAssertEqual(try harness.store.calendarEvent(id: single.id)?.response, .accepted)
        let fromDetails = try queuedAnswers(harness)
        XCTAssertEqual(fromDetails.count, 1)
        XCTAssertEqual(fromDetails.first?.answer.calendar?.previous[single.id], .tentative, "a give-up puts the phone's back")

        // From the reader's card, which shows the calendar copy's answer.
        try sentAndTheTentativeOnThePhone()
        XCTAssertTrue(try harness.engine.answerInvitation(.accepted, to: message))
        XCTAssertEqual(try harness.store.calendarEvent(id: single.id)?.response, .accepted)
        XCTAssertEqual(try queuedAnswers(harness).count, 1)
        XCTAssertFalse(try harness.engine.answerInvitation(.accepted, to: message), "the card shows it now: nothing more")
        XCTAssertEqual(try queuedAnswers(harness).count, 1)
        await harness.shutdown()
    }

    /// Decline then Accept on All Events while the first waits: the clicked occurrence said Accept before, but the others
    /// did not, so the series' Accept still goes out.
    func testASeriesAnswerThatEndsWhereTheClickedOccurrenceStartedIsStillSent() async throws {
        let rows = [event("s1", series: "S", response: .accepted), event("s2", series: "S", start: 7 * 86_400),
                    event("s3", series: "S", start: 14 * 86_400)]
        let harness = try await harness(events: rows)
        XCTAssertEqual(try harness.engine.answerCalendarEvent(.declined, eventID: rows[0].id, span: .series, invitationMessage: nil),
                       .calendar)
        XCTAssertEqual(try harness.engine.answerCalendarEvent(.accepted, eventID: rows[0].id, span: .series, invitationMessage: nil),
                       .calendar)
        try await waitUntil("the replaced answer dropped") { try self.queuedAnswers(harness).count == 1 }
        let kept = try XCTUnwrap(try queuedAnswers(harness).first)
        XCTAssertEqual(kept.answer.response, .accepted)
        XCTAssertEqual(kept.answer.previous, .accepted, "the clicked occurrence's, before the first")
        XCTAssertEqual(kept.answer.calendar?.previous, [rows[0].id: .accepted, rows[1].id: .needsAction, rows[2].id: .needsAction])

        _ = try await harness.engine.reconnect(Fixtures.account())
        harness.provider.permissionNeeded = nil
        harness.engine.syncNow(accountID: Fixtures.accountID)
        try await waitUntil("sent after the grant") {
            harness.provider.applyCalls.contains { if case .answerInvitation = $0.change { return true } else { return false } }
        }
        let sent = harness.provider.applyCalls.compactMap { call -> InvitationAnswer? in
            guard case .answerInvitation(let answer) = call.change else { return nil }
            return answer
        }
        XCTAssertEqual(sent.map(\.response), [.accepted], "the organizer hears the series' Accept, once")
        XCTAssertEqual(sent.first?.calendar?.providerEventID, "S")
        await harness.shutdown()
    }

    func testOnlyAnInvitationOnTheCalendarCanBeAnswered() async throws {
        let mine = event("mine", response: .organizer)
        let focus = event("focus", kind: .focusTime)
        let block = CalendarEvent(id: "\(Fixtures.accountID.rawValue)|local-b", accountID: Fixtures.accountID, providerID: nil,
                                  title: "Lunch?", start: start, end: start.addingTimeInterval(1_800), response: .needsAction,
                                  sourceMessage: message, clientKey: "k", sync: .creating)
        let setAside = event("aside", source: message)
        let harness = try await harness(events: [mine, focus, setAside])
        try harness.store.addCalendarEvent(block)
        for id in [mine.id, focus.id, block.id, setAside.id] {
            XCTAssertThrowsError(try harness.engine.answerCalendarEvent(.accepted, eventID: id, span: .single, invitationMessage: nil), id) {
                guard case .conflict? = $0 as? StoreError else { return XCTFail("\($0)") }
            }
        }
        XCTAssertThrowsError(try harness.engine.answerCalendarEvent(.accepted, eventID: "acct|none", span: .single,
                                                                    invitationMessage: nil)) {
            guard case .notFound? = $0 as? StoreError else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(try queuedAnswers(harness).isEmpty)
        await harness.shutdown()
    }
}
