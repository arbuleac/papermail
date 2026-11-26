import XCTest
import PaperCore

/// Answers on the calendar (docs/DATA-MODEL.md, "Calendar events" › Answers and "Pending answers win"): an answer's
/// enqueue writes the rows it covers and records what each said, in one transaction; a read keeps a live answer's word;
/// a give-up puts the rows back. The state lives in the operation alone. Both stores, through `MailStoreContractTests`.
extension MailStoreContractTests {
    // MARK: Fixtures

    private func invitedEvent(_ providerID: String, account: AccountID? = nil, uid: String? = nil, series: String? = nil,
                              start: TimeInterval, response: CalendarEvent.Response = .needsAction) -> CalendarEvent {
        let accountID = account ?? accountA
        return CalendarEvent(id: CalendarEvent.localID(accountID: accountID, providerID: providerID), accountID: accountID,
                             providerID: providerID, title: "Weekly", start: date(start), end: date(start + 1_800),
                             response: response, invitationUID: uid, seriesID: series)
    }

    private var answerWeek: DateInterval { DateInterval(start: date(0), end: date(7 * 86_400)) }

    private func answerOperation(_ response: InvitationResponse, scope: CalendarCopies.Scope, account: AccountID? = nil,
                                 providerEventID: String? = "evt", targets: [MessageID] = [], at offset: TimeInterval = 0,
                                 id: String = UUID().uuidString) -> Operation {
        let accountID = account ?? accountA
        var answer = InvitationAnswer(response: response, uid: "uid", title: "Weekly", start: date(0), end: date(1_800),
                                      organizer: EmailAddress(address: "org@example.com"),
                                      attendee: EmailAddress(address: "a@example.com"), replyID: UUID().uuidString)
        answer.calendar = CalendarCopies(scope: scope, providerEventID: providerEventID)
        return Operation(id: id, accountID: accountID, change: .answerInvitation(answer), targets: targets,
                         createdAt: date(offset))
    }

    private func eventResponse(_ providerID: String, _ account: AccountID? = nil) throws -> CalendarEvent.Response? {
        try store.calendarEvent(id: CalendarEvent.localID(accountID: account ?? accountA, providerID: providerID))?.response
    }

    private func storedAnswer(_ id: String) throws -> InvitationAnswer? {
        let operation = try store.pendingOperations(accountID: accountA, limit: 100).first { $0.id == id }
        guard case .answerInvitation(let answer)? = operation?.change else { return nil }
        return answer
    }

    // MARK: Enqueue

    func testAnAnswerShowsOnTheInvitationsEventsInItsEnqueue() throws {
        // Exchange gives each occurrence its own UID, the series' with its date written in.
        let series = "040000008200E00074C5B7101A82E00800000000A0B1C2D3000000000000000010000000AABBCCDD"
        let occurrence = { (date: String) in
            String(series.prefix(32)) + date + String(series.dropFirst(40))
        }
        try store.replaceCalendarEvents([
            invitedEvent("once", uid: "uid-1@google.com", start: 3_600),
            invitedEvent("mine", uid: "uid-1@google.com", start: 3_600, response: .organizer),
            invitedEvent("other", uid: "uid-2@google.com", start: 7_200),
            invitedEvent("plain", start: 9_000),
            invitedEvent("w1", uid: occurrence("07EA0105"), start: 86_400),
            invitedEvent("w2", uid: occurrence("07EA0106"), start: 2 * 86_400),
            invitedEvent("w3", uid: occurrence("07EA0107"), start: 3 * 86_400),
        ], accountID: accountA, window: answerWeek)
        try store.replaceCalendarEvents([invitedEvent("theirs", account: accountB, uid: "uid-1@google.com", start: 3_600)],
                                        accountID: accountB, window: answerWeek)

        try store.enqueue(answerOperation(.declined, scope: .invitation(uid: "uid-1@google.com", near: nil), id: "op-1"))
        XCTAssertEqual(try eventResponse("once"), .declined)
        XCTAssertEqual(try eventResponse("mine"), .organizer, "the user's own event is not an invitation to them")
        XCTAssertEqual(try eventResponse("other"), .needsAction)
        XCTAssertEqual(try eventResponse("theirs", accountB), .needsAction, "another account's copy is its own")
        XCTAssertEqual(try storedAnswer("op-1")?.calendar?.previous,
                       [CalendarEvent.localID(accountID: accountA, providerID: "once"): .needsAction], "what each row said")

        // A series answered: every occurrence. One occurrence answered: the one nearest its start.
        try store.enqueue(answerOperation(.accepted, scope: .invitation(uid: series, near: nil), at: 1))
        XCTAssertEqual(try ["w1", "w2", "w3"].map { try eventResponse($0) }, [.accepted, .accepted, .accepted])
        try store.enqueue(answerOperation(.tentative, scope: .invitation(uid: series, near: date(2 * 86_400 + 600)), at: 2))
        XCTAssertEqual(try ["w1", "w2", "w3"].map { try eventResponse($0) }, [.accepted, .tentative, .accepted])

        // A row being deleted is left as it is.
        try store.removeCalendarEvent(id: CalendarEvent.localID(accountID: accountA, providerID: "other"))
        try store.enqueue(answerOperation(.accepted, scope: .invitation(uid: "uid-2@google.com", near: nil), at: 3))
        XCTAssertEqual(try store.calendarEvent(id: CalendarEvent.localID(accountID: accountA, providerID: "other"))?.response,
                       .needsAction)
    }

    func testAnAnswerToOneEventOrToItsSeriesCoversThoseRowsAlone() throws {
        try store.replaceCalendarEvents([
            invitedEvent("s1", series: "S", start: 3_600),
            invitedEvent("s2", series: "S", start: 86_400 + 3_600, response: .accepted),
            invitedEvent("s3", series: "S", start: 2 * 86_400 + 3_600),
            invitedEvent("own", series: "S", start: 3 * 86_400, response: .organizer),
            invitedEvent("t1", series: "T", start: 7_200),
        ], accountID: accountA, window: answerWeek)
        try store.replaceCalendarEvents([invitedEvent("b1", account: accountB, series: "S", start: 3_600)],
                                        accountID: accountB, window: answerWeek)

        let s2 = CalendarEvent.localID(accountID: accountA, providerID: "s2")
        try store.enqueue(answerOperation(.declined, scope: .event(id: s2), id: "op-one"))
        XCTAssertEqual(try ["s1", "s2", "s3", "t1"].map { try eventResponse($0) }, [.needsAction, .declined, .needsAction, .needsAction])
        XCTAssertEqual(try storedAnswer("op-one")?.calendar?.previous, [s2: .accepted])

        try store.enqueue(answerOperation(.accepted, scope: .series(id: "S"), at: 1, id: "op-all"))
        XCTAssertEqual(try ["s1", "s2", "s3", "own", "t1"].map { try eventResponse($0) },
                       [.accepted, .accepted, .accepted, .organizer, .needsAction])
        XCTAssertEqual(try eventResponse("b1", accountB), .needsAction, "another account's series is its own")
        let previous = try XCTUnwrap(try storedAnswer("op-all")?.calendar?.previous)
        XCTAssertEqual(previous, [
            CalendarEvent.localID(accountID: accountA, providerID: "s1"): .needsAction, s2: .declined,
            CalendarEvent.localID(accountID: accountA, providerID: "s3"): .needsAction,
        ], "every covered row, the organizer's left out")
    }

    func testCreatingAndDeletingRowsAreNotAnswered() throws {
        let block = CalendarEvent(id: "\(accountA.rawValue)|local-x", accountID: accountA, providerID: nil, title: "Lunch?",
                                  start: date(3_600), end: date(5_400), response: .needsAction,
                                  sourceMessage: MessageID(accountID: accountA, providerID: "m"), clientKey: "k", sync: .creating)
        try store.addCalendarEvent(block)
        try store.replaceCalendarEvents([invitedEvent("gone", start: 7_200)], accountID: accountA, window: answerWeek)
        try store.removeCalendarEvent(id: CalendarEvent.localID(accountID: accountA, providerID: "gone"))

        try store.enqueue(answerOperation(.accepted, scope: .event(id: block.id), id: "op-a"))
        try store.enqueue(answerOperation(.accepted, scope: .event(id: CalendarEvent.localID(accountID: accountA, providerID: "gone")),
                                          at: 1, id: "op-b"))
        XCTAssertEqual(try store.calendarEvent(id: block.id)?.response, .needsAction)
        XCTAssertEqual(try storedAnswer("op-a")?.calendar?.previous, [:])
        XCTAssertEqual(try storedAnswer("op-b")?.calendar?.previous, [:])
    }

    // MARK: Pending answers win

    func testAReadBeforeTheSendKeepsTheAnswerAndOneAfterWritesTheProvidersWord() throws {
        let read = [invitedEvent("e", series: "S", start: 3_600), invitedEvent("f", series: "S", start: 86_400)]
        try store.replaceCalendarEvents(read, accountID: accountA, window: answerWeek)
        let operation = answerOperation(.accepted, scope: .series(id: "S"), id: "op-series")
        try store.enqueue(operation)

        // The window brings in another occurrence, and says the old answer for the others.
        try store.replaceCalendarEvents(read + [invitedEvent("g", series: "S", start: 2 * 86_400)], accountID: accountA,
                                        window: answerWeek)
        XCTAssertEqual(try ["e", "f", "g"].map { try eventResponse($0) }, [.accepted, .accepted, .accepted],
                       "a live answer wins over the read, a new occurrence included")
        XCTAssertEqual(try storedAnswer("op-series")?.calendar?.previous.count, 2, "a read never rewrites the operation")

        try store.confirmOperation(id: "op-series")
        try store.replaceCalendarEvents(read, accountID: accountA, window: answerWeek)
        XCTAssertEqual(try ["e", "f"].map { try eventResponse($0) }, [.needsAction, .needsAction], "the provider's word once it went")
    }

    func testAnUndecodableOperationIsSkippedByARead() throws {
        try store.replaceCalendarEvents([invitedEvent("e", start: 3_600)], accountID: accountA, window: answerWeek)
        try store.enqueue(Operation(accountID: accountA, change: .setRead(true), targets: []))
        try store.replaceCalendarEvents([invitedEvent("e", start: 3_600, response: .tentative)], accountID: accountA,
                                        window: answerWeek)
        XCTAssertEqual(try eventResponse("e"), .tentative)
    }

    // MARK: Give-up

    func testAGiveUpPutsEveryRowBackButNotOneAReadRewrote() throws {
        try store.replaceCalendarEvents([
            invitedEvent("a", series: "S", start: 3_600), invitedEvent("b", series: "S", start: 86_400, response: .tentative),
            invitedEvent("c", series: "S", start: 2 * 86_400),
        ], accountID: accountA, window: answerWeek)
        var operation = answerOperation(.declined, scope: .series(id: "S"), id: "op-x")
        try store.enqueue(operation)
        operation = try XCTUnwrap(try store.pendingOperations(accountID: accountA, limit: 10).first)
        XCTAssertEqual(try ["a", "b", "c"].map { try eventResponse($0) }, [.declined, .declined, .declined])

        operation.status = .failed
        operation.nextAttemptAt = date(86_400)
        try store.updateOperation(operation)
        XCTAssertEqual(try ["a", "b", "c"].map { try eventResponse($0) }, [.needsAction, .tentative, .needsAction],
                       "each row has its own answer back")

        // A row that no longer says the given-up answer (a later answer went out and the read wrote it) keeps its word.
        let c = CalendarEvent.localID(accountID: accountA, providerID: "c")
        try store.enqueue(answerOperation(.accepted, scope: .event(id: c), at: 10, id: "op-y"))
        try store.enqueue(answerOperation(.declined, scope: .event(id: c), at: 11, id: "op-z"))
        try store.confirmOperation(id: "op-z")
        var stale = try XCTUnwrap(try store.pendingOperations(accountID: accountA, limit: 10).first { $0.id == "op-y" })
        stale.status = .failed
        try store.updateOperation(stale)
        XCTAssertEqual(try eventResponse("c"), .declined, "the answer that went out stays")
    }

    func testAGiveUpUnderANewerAnswerRewritesWhatThatOneReplaced() throws {
        try store.replaceCalendarEvents([invitedEvent("e", start: 3_600)], accountID: accountA, window: answerWeek)
        let id = CalendarEvent.localID(accountID: accountA, providerID: "e")
        try store.enqueue(answerOperation(.accepted, scope: .event(id: id), id: "op-1"))
        try store.enqueue(answerOperation(.declined, scope: .event(id: id), at: 1, id: "op-2"))
        XCTAssertEqual(try storedAnswer("op-2")?.calendar?.previous, [id: .accepted])

        var first = try XCTUnwrap(try store.pendingOperations(accountID: accountA, limit: 10).first { $0.id == "op-1" })
        first.status = .failed
        try store.updateOperation(first)
        XCTAssertEqual(try eventResponse("e"), .declined, "the newer answer rules the row")
        XCTAssertEqual(try storedAnswer("op-2")?.calendar?.previous, [id: .needsAction],
                       "the newer answer now replaces what the given-up one replaced")

        var second = try XCTUnwrap(try store.pendingOperations(accountID: accountA, limit: 10).first { $0.id == "op-2" })
        second.status = .failed
        try store.updateOperation(second)
        XCTAssertEqual(try eventResponse("e"), .needsAction, "back to the answer that went out: none")
    }

    // MARK: The card and the failures

    func testTheCardFollowsTheRowItsDetailsAndTheOutbox() throws {
        try store.replaceCalendarEvents([invitedEvent("e", start: 3_600)], accountID: accountA, window: answerWeek)
        let id = CalendarEvent.localID(accountID: accountA, providerID: "e")
        let box = CardBox()
        let observation = store.observeEventCard(id: id) { state in
            XCTAssertTrue(Thread.isMainThread)
            box.append(state)
        }
        defer { observation.cancel() }
        func expect(_ step: String, _ check: @escaping (EventCardState?) -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !(box.last.map(check) ?? false), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertTrue(box.last.map(check) ?? false, step)
        }
        expect("the row first") { $0?.event.response == .needsAction && $0?.answer == nil && $0?.details == nil }

        try store.enqueue(answerOperation(.accepted, scope: .event(id: id), id: "op-c"))
        expect("an answer on its way") { $0?.event.response == .accepted && $0?.answer == .live(.accepted) }

        XCTAssertTrue(try store.saveCalendarEventDetails(CalendarEventDetails(repeats: "Every week"), eventID: id, version: "v1",
                                                         readAt: date(60)))
        expect("details arrive") { $0?.details?.details.repeats == "Every week" && $0?.details?.version == "v1" }

        var operation = try XCTUnwrap(try store.pendingOperations(accountID: accountA, limit: 10).first)
        operation.status = .failed
        try store.updateOperation(operation)
        expect("given up") { $0?.event.response == .needsAction && $0?.answer == .failed }

        try store.deleteOperation(id: "op-c")
        expect("pruned") { $0?.answer == nil }

        try store.replaceCalendarEvents([], accountID: accountA, window: answerWeek)
        expect("the row gone") { $0 == nil }
    }

    /// A given-up answer stays in the outbox for a day, but once a later answer to the event went out (and left it) the
    /// row says that one, and the card no longer says the failure.
    func testAGivenUpAnswerIsPastOnceALaterOneWentOut() throws {
        try store.replaceCalendarEvents([invitedEvent("e", start: 3_600)], accountID: accountA, window: answerWeek)
        let id = CalendarEvent.localID(accountID: accountA, providerID: "e")
        let box = CardBox()
        let observation = store.observeEventCard(id: id) { box.append($0) }
        defer { observation.cancel() }
        func expect(_ step: String, _ check: @escaping (EventCardState?) -> Bool) {
            let deadline = Date().addingTimeInterval(3)
            while !(box.last.map(check) ?? false), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            XCTAssertTrue(box.last.map(check) ?? false, step)
        }
        try store.enqueue(answerOperation(.accepted, scope: .event(id: id), id: "op-1"))
        var first = try XCTUnwrap(try store.pendingOperations(accountID: accountA, limit: 10).first)
        first.status = .failed
        first.nextAttemptAt = date(86_400)
        try store.updateOperation(first)
        expect("given up, put back") { $0?.event.response == .needsAction && $0?.answer == .failed }

        try store.enqueue(answerOperation(.accepted, scope: .event(id: id), at: 1, id: "op-2"))
        expect("again, on its way") { $0?.event.response == .accepted && $0?.answer == .live(.accepted) }
        try store.confirmOperation(id: "op-2")
        expect("sent: the failure is past") { $0?.event.response == .accepted && $0?.answer == nil }
    }

    /// Accept given up (the row back to tentative), then Decline and Tentative sent: the row says tentative again, the
    /// word the give-up put back, but later answers went out, so the failure is past and leaves the outbox with the first.
    func testAConfirmedAnswerSettlesTheFailuresQueuedBeforeIt() throws {
        try store.replaceCalendarEvents([invitedEvent("e", start: 3_600, response: .tentative)], accountID: accountA,
                                        window: answerWeek)
        let id = CalendarEvent.localID(accountID: accountA, providerID: "e")
        let card = CardBox()
        let observation = store.observeEventCard(id: id) { card.append($0) }
        let failures = ObservedValues()
        let failedObservation = store.observeFailedCalendarAnswers { failures.append($0.sorted()) }
        defer { observation.cancel(); failedObservation.cancel() }
        expectCard(card, "the row first") { $0?.answer == nil }
        expectFailures(failures, [], "none yet")

        try store.enqueue(answerOperation(.accepted, scope: .event(id: id), id: "op-1"))
        try giveUp("op-1")
        expectCard(card, "given up, put back") { $0?.event.response == .tentative && $0?.answer == .failed }
        expectFailures(failures, ["op-1"], "the window's toast hears of it")

        try store.enqueue(answerOperation(.declined, scope: .event(id: id), at: 1, id: "op-2"))
        try store.confirmOperation(id: "op-2")
        expectCard(card, "declined, sent") { $0?.event.response == .declined && $0?.answer == nil }
        expectFailures(failures, [], "the failure went with the answer that went out after it")

        try store.enqueue(answerOperation(.tentative, scope: .event(id: id), at: 2, id: "op-3"))
        try store.confirmOperation(id: "op-3")
        expectCard(card, "tentative again, sent: no failure line") { $0?.event.response == .tentative && $0?.answer == nil }
    }

    /// A failure stands on the rows no later answer covers, and a failure queued after the confirmed answer is its own.
    func testAConfirmedAnswerSettlesAFailureOnlyWhereItGoesAndOnlyAnOlderOne() throws {
        try store.replaceCalendarEvents([
            invitedEvent("a", series: "S", start: 3_600, response: .tentative),
            invitedEvent("b", series: "S", start: 86_400, response: .tentative),
        ], accountID: accountA, window: answerWeek)
        let a = CalendarEvent.localID(accountID: accountA, providerID: "a")
        let b = CalendarEvent.localID(accountID: accountA, providerID: "b")
        let cardA = CardBox(), cardB = CardBox()
        let observations = [store.observeEventCard(id: a) { cardA.append($0) }, store.observeEventCard(id: b) { cardB.append($0) }]
        let failures = ObservedValues()
        let failedObservation = store.observeFailedCalendarAnswers { failures.append($0.sorted()) }
        defer { observations.forEach { $0.cancel() }; failedObservation.cancel() }
        expectCard(cardA, "a first") { $0?.answer == nil }
        expectCard(cardB, "b first") { $0?.answer == nil }
        expectFailures(failures, [], "none yet")

        try store.enqueue(answerOperation(.accepted, scope: .series(id: "S"), id: "op-1"))
        try giveUp("op-1")
        // Delivered before the answers that follow, so the occurrence's check below needs a value the store sent after
        // them: on SQLite the observation delivers later, and its first value says what the check asks for.
        expectCard(cardA, "a given up") { $0?.event.response == .tentative && $0?.answer == .failed }
        expectCard(cardB, "b given up") { $0?.event.response == .tentative && $0?.answer == .failed }
        try store.enqueue(answerOperation(.declined, scope: .event(id: a), at: 1, id: "op-2"))
        try store.confirmOperation(id: "op-2")
        try store.enqueue(answerOperation(.tentative, scope: .event(id: a), at: 2, id: "op-3"))
        try store.confirmOperation(id: "op-3")
        expectCard(cardA, "the occurrence answered since: past") { $0?.event.response == .tentative && $0?.answer == nil }
        expectCard(cardB, "the occurrence nothing answered since: still failed") {
            $0?.event.response == .tentative && $0?.answer == .failed
        }
        expectFailures(failures, ["op-1"], "kept while a row of it still stands")

        // Decline queued, then Accept queued and given up over it; the Decline then goes: the Accept came after it, and
        // its failure stands.
        try store.enqueue(answerOperation(.declined, scope: .event(id: a), at: 3, id: "op-4"))
        try store.enqueue(answerOperation(.accepted, scope: .event(id: a), at: 4, id: "op-5"))
        try giveUp("op-5")
        try store.confirmOperation(id: "op-4")
        expectCard(cardA, "a newer failure is its own") { $0?.event.response == .declined && $0?.answer == .failed }
        expectFailures(failures, ["op-1", "op-5"], "both still stand")
    }

    private func giveUp(_ id: String) throws {
        var operation = try XCTUnwrap(try store.pendingOperations(accountID: accountA, limit: 100).first { $0.id == id })
        operation.status = .failed
        operation.nextAttemptAt = date(86_400)
        try store.updateOperation(operation)
    }

    /// Waits for the value the observation delivers when it starts (the in-memory store sends it on the next turn of the
    /// run loop, after any write made meanwhile has been delivered at once), so a later value is never overtaken by it.
    private func expectCard(_ box: CardBox, _ step: String, file: StaticString = #filePath, line: UInt = #line,
                            _ check: @escaping (EventCardState?) -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !(box.last.map(check) ?? false), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(box.last.map(check) ?? false, step, file: file, line: line)
    }

    private func expectFailures(_ box: ObservedValues, _ ids: [String], _ step: String, file: StaticString = #filePath,
                                line: UInt = #line) {
        let deadline = Date().addingTimeInterval(3)
        while box.values.last != ids, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(box.values.last, ids, step, file: file, line: line)
    }

    func testOnlyFailedAnswersWithNoMessageAreReported() throws {
        try store.upsertMessages([message("m1", in: "c1")])
        let box = ObservedValues()
        let observation = store.observeFailedCalendarAnswers { ids in box.append(ids.sorted()) }
        defer { observation.cancel() }
        try store.enqueue(answerOperation(.accepted, scope: .event(id: "x"), id: "op-calendar"))
        try store.enqueue(answerOperation(.accepted, scope: .invitation(uid: "u", near: nil), providerEventID: nil,
                                          targets: [MessageID(accountID: accountA, providerID: "m1")], at: 1, id: "op-mail"))
        for id in ["op-calendar", "op-mail"] {
            var operation = try XCTUnwrap(try store.pendingOperations(accountID: accountA, limit: 10).first { $0.id == id })
            operation.status = .failed
            try store.updateOperation(operation)
        }
        let deadline = Date().addingTimeInterval(3)
        while box.values.last != ["op-calendar"], Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(box.values.last, ["op-calendar"])
    }
}

/// The states an observation delivered, read on the main thread.
final class CardBox: @unchecked Sendable {
    private let lock = NSLock()
    private var states: [EventCardState?] = []

    var last: EventCardState?? {
        lock.lock(); defer { lock.unlock() }
        return states.last
    }

    func append(_ state: EventCardState?) {
        lock.lock(); defer { lock.unlock() }
        states.append(state)
    }
}
