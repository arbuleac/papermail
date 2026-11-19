import Foundation
import XCTest
@testable import SSCore

/// The times a body's words name are found when the body is stored, once, and handed to the store
/// (`Hydrator.saveMailTimes`): only for recent mail that is not a list's.
final class HydratorMailTimesTests: XCTestCase {
    private let account = Fixtures.accountID

    private func id(_ number: Int) -> MessageID {
        MessageID(accountID: account, providerID: "\(number)")
    }

    private func message(_ number: Int, hoursAgo: Double, listUnsubscribe: String? = nil) -> MessageMetadata {
        var message = Fixtures.message(number, conversation: "t\(number)")
        message.date = Date().addingTimeInterval(-hoursAgo * 3_600)
        message.listUnsubscribe = listUnsubscribe
        return message
    }

    /// A store holding `messages`, a provider serving `bodies` by provider id, and a hydrator over both.
    private func hydrator(_ messages: [MessageMetadata], bodies: [Int: MessageBody])
        throws -> (Hydrator, MailTimeRecordingStore, ScriptedProvider) {
        let store = MailTimeRecordingStore(base: InMemoryMailStore())
        try store.upsertMessages(messages)
        let provider = ScriptedProvider(accountID: account)
        for (number, body) in bodies { provider.bodies["\(number)"] = .success(body) }
        let hydrator = Hydrator(accountID: account, store: store, provider: provider, sanitizer: HTMLSanitizer(), tuning: SyncTuning())
        return (hydrator, store, provider)
    }

    func testTheTimesARecentBodyNamesAreSavedWhenItIsStored() async throws {
        let (hydrator, store, _) = try hydrator(
            [message(1, hoursAgo: 1), message(2, hoursAgo: 2)],
            bodies: [
                1: MessageBody(html: "<div>Hi Alex,</div><div>Could we move our call to tomorrow at 3pm?</div>", text: nil),
                2: MessageBody(html: nil, text: "Thanks for the notes, all good."),
            ]
        )

        let outcome = await hydrator.hydrateLive([id(1), id(2)])

        XCTAssertEqual(outcome.fetched, 2)
        let saved = store.savedMailTimes
        XCTAssertEqual(saved.map(\.message), [id(1)], "once, for the body that names a time; nothing for the other")
        let time = try XCTUnwrap(saved.first?.times.first)
        XCTAssertEqual(saved.first?.times.count, 1)
        XCTAssertEqual(time.messageID, id(1))
        XCTAssertEqual(time.phrase, "tomorrow at 3pm")
        let calendar = Calendar.autoupdatingCurrent
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date())))
        XCTAssertEqual(time.start, calendar.date(bySettingHour: 15, minute: 0, second: 0, of: tomorrow))
        XCTAssertNotNil(try store.body(for: id(1)), "the body is stored as ever")

        // Asked again, the stored body is served: nothing is read twice.
        _ = try await hydrator.ensureBody(for: id(1))
        XCTAssertEqual(store.savedMailTimes.count, 1)
    }

    func testOlderMailAndAListsMailAreNotRead() async throws {
        let text = "Could we move our call to tomorrow at 3pm?"
        let (hydrator, store, _) = try hydrator(
            [
                message(1, hoursAgo: 4 * 24),
                message(2, hoursAgo: 1, listUnsubscribe: "<https://news.example/unsubscribe>"),
                message(3, hoursAgo: 1),
            ],
            bodies: [
                1: MessageBody(html: nil, text: text),
                2: MessageBody(html: nil, text: text),
                // Graph names a list's mail only in the body it serves.
                3: MessageBody(html: nil, text: text, listUnsubscribe: "<mailto:leave@news.example>"),
            ]
        )

        let outcome = await hydrator.hydrateLive([id(1), id(2), id(3)])

        XCTAssertEqual(outcome.fetched, 3)
        XCTAssertTrue(store.savedMailTimes.isEmpty, "received four days ago, or a list's: no times")
    }

    /// The backfill's bodies go the same way: a recent one it fetches has its times found too.
    func testThePacedPathFindsTimesToo() async throws {
        let (hydrator, store, _) = try hydrator([message(1, hoursAgo: 5)], bodies: [1: MessageBody(html: nil, text: "Tomorrow at 10?")])

        let outcome = await hydrator.hydratePaced()

        XCTAssertEqual(outcome.fetched, 1)
        XCTAssertEqual(store.savedMailTimes.map(\.message), [id(1)])
        XCTAssertEqual(store.savedMailTimes.first?.times.map(\.phrase), ["Tomorrow at 10"])
    }
}
