import Foundation
import XCTest
@testable import PaperCore

/// An answer given from the calendar (docs/ARCHITECTURE.md, "Calendar invitations" › Answering) names no message: the
/// outbox sends it itself, once, on the provider's event; a gone event gives it up at once and puts its rows back; a
/// throttle keeps it; it waits untried for the calendar permission; and a newer answer to the same event replaces it.
final class OperationRunnerTests: XCTestCase {
    private let eventID = CalendarEvent.localID(accountID: Fixtures.accountID, providerID: "evt")

    private func store() throws -> InMemoryMailStore {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        let event = CalendarEvent(id: eventID, accountID: Fixtures.accountID, providerID: "evt", title: "Weekly",
                                  start: Date(timeIntervalSinceNow: 86_400), end: Date(timeIntervalSinceNow: 88_200),
                                  response: .needsAction)
        try store.replaceCalendarEvents([event], accountID: Fixtures.accountID,
                                        window: DateInterval(start: Date(), duration: 7 * 86_400))
        return store
    }

    private func calendarAnswer(_ response: InvitationResponse, providerEventID: String? = "evt",
                                createdAt: Date = Date()) -> PaperCore.Operation {
        var answer = InvitationAnswer(response: response, uid: "", title: "Weekly", start: Date(), end: Date(),
                                      organizer: EmailAddress(address: "org@example.com"),
                                      attendee: EmailAddress(address: "me@example.com"), replyID: UUID().uuidString)
        answer.calendar = CalendarCopies(scope: .event(id: eventID), providerEventID: providerEventID)
        return PaperCore.Operation(accountID: Fixtures.accountID, change: .answerInvitation(answer), targets: [],
                                   createdAt: createdAt)
    }

    private func runner(_ store: InMemoryMailStore, _ provider: ScriptedProvider,
                        tune: (inout SyncTuning) -> Void = { _ in }) -> OperationRunner {
        var tuning = SyncTuning()
        tuning.backoffBase = 0.001
        tuning.backoffCap = 0.004
        tune(&tuning)
        return OperationRunner(accountID: Fixtures.accountID, store: store, provider: provider, tuning: tuning)
    }

    private func pending(_ store: InMemoryMailStore) throws -> [PaperCore.Operation] {
        try store.pendingOperations(accountID: Fixtures.accountID, limit: 10)
    }

    func testAnAnswerWithNoMessageIsOneProviderCallThenConfirmed() async throws {
        let store = try store()
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        try store.enqueue(calendarAnswer(.accepted))
        let outcome = await runner(store, provider).drain()

        XCTAssertEqual(provider.applyCalls.count, 1)
        XCTAssertEqual(provider.applyCalls.first?.ids, [], "the event, not a message")
        XCTAssertTrue(outcome.answeredInvitation, "the calendar lane reads once the answer went")
        XCTAssertTrue(try pending(store).isEmpty, "confirmed")
        XCTAssertEqual(try store.calendarEvent(id: eventID)?.response, .accepted, "the row keeps the answer")
    }

    func testAGoneEventGivesTheAnswerUpAtOnceAndPutsTheRowBack() async throws {
        let store = try store()
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.applyResults = [.failure(ProviderError.notFound)]
        try store.enqueue(calendarAnswer(.declined))
        XCTAssertEqual(try store.calendarEvent(id: eventID)?.response, .declined)
        _ = await runner(store, provider).drain()

        XCTAssertTrue(try pending(store).isEmpty)
        XCTAssertEqual(try store.calendarEvent(id: eventID)?.response, .needsAction, "given up: the previous answer is back")
    }

    func testAThrottleKeepsTheAnswerPending() async throws {
        let store = try store()
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.applyResults = [.failure(ProviderError.throttled(retryAfter: 30))]
        try store.enqueue(calendarAnswer(.tentative))
        let outcome = await runner(store, provider).drain()

        let left = try XCTUnwrap(try pending(store).first)
        XCTAssertEqual(left.status, .pending)
        XCTAssertNotNil(outcome.throttle)
        XCTAssertEqual(try store.calendarEvent(id: eventID)?.response, .tentative)
    }

    /// An operation with no target from before 1.22 (no event named) is done with no call, as it always was.
    func testAnOlderTargetlessOperationIsConfirmedWithNoCall() async throws {
        let store = try store()
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        var answer = InvitationAnswer(response: .accepted, uid: "u", title: "T", start: Date(), end: Date(),
                                      organizer: EmailAddress(address: "o@example.com"), attendee: EmailAddress(address: "m@example.com"))
        answer.calendar = nil
        try store.enqueue(PaperCore.Operation(accountID: Fixtures.accountID, change: .answerInvitation(answer), targets: []))
        _ = await runner(store, provider).drain()
        XCTAssertTrue(provider.applyCalls.isEmpty)
        XCTAssertTrue(try pending(store).isEmpty)
    }

    func testWithoutThePermissionTheAnswerWaitsUntried() async throws {
        let store = try store()
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.permissionNeeded = .calendar
        try store.enqueue(calendarAnswer(.accepted))
        let outcome = await runner(store, provider).drain()
        XCTAssertTrue(provider.applyCalls.isEmpty)
        XCTAssertEqual(outcome.permissionsNeeded, [.calendar])
        XCTAssertEqual(try pending(store).first?.attempts, 0)
    }

    /// A second answer to the same event before the first went out replaces it, keyed by the event, and takes over what
    /// each row said before the first, so a give-up puts back the answer that went out.
    func testANewerAnswerToTheSameEventDropsTheOlderAndTakesOverItsRows() async throws {
        let store = try store()
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.permissionNeeded = .calendar
        let now = Date()
        try store.enqueue(calendarAnswer(.accepted, createdAt: now))
        try store.enqueue(calendarAnswer(.declined, createdAt: now.addingTimeInterval(0.001)))
        try store.enqueue(calendarAnswer(.tentative, providerEventID: "other", createdAt: now.addingTimeInterval(0.002)))
        _ = await runner(store, provider).drain()

        let left = try pending(store)
        XCTAssertEqual(left.count, 2, "the older answer to the same event is dropped; another event's stays")
        guard case .answerInvitation(let survivor)? = left.first?.change else { return XCTFail("no answer left") }
        XCTAssertEqual(survivor.response, .declined)
        XCTAssertEqual(survivor.calendar?.previous, [eventID: .needsAction], "what the row said before the first")
        XCTAssertEqual(OperationRunner.answerKey(of: left[0]), "calendar|evt")
    }
}
