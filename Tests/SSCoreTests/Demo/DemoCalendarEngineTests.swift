import Foundation
import XCTest
@testable import SSCore

/// The demo calendar through the engine, wired as demo mode wires it (MailEngine + InMemoryMailStore +
/// DemoMailProvider): each demo account's calendar lane reads its calendar into the store after the first live cycle,
/// with no Connect, and time set aside is created on the demo calendar and removed from it.
final class DemoCalendarEngineTests: XCTestCase {
    private var cacheDirectory: URL!

    override func setUp() {
        super.setUp()
        cacheDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SuperSparrowDemoCalendarTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        super.tearDown()
    }

    private func seededEngine(service: DemoMailService) async throws -> (MailEngine, InMemoryMailStore, [Account]) {
        var tuning = SyncTuning()
        tuning.pollInterval = 0.1
        tuning.backoffBase = 0.05
        tuning.backoffCap = 0.5
        let store = InMemoryMailStore()
        let engine = MailEngine(
            store: store,
            tokenStore: InMemoryTokenStore(),
            tokenProvider: DemoTokenProvider(),
            authenticator: DemoAuthenticator(),
            sanitizer: HTMLSanitizer(),
            providerFactory: { service.provider(for: $0) },
            tuning: tuning,
            attachmentCacheDirectory: cacheDirectory
        )
        engine.start()
        return (engine, store, try await DemoSeeder.seedIfNeeded(engine))
    }

    func testTheDemoShowsItsCalendarsAndKeepsTheTimeSetAside() async throws {
        let service = DemoMailService(liveInterval: 3_600)
        let (engine, store, accounts) = try await seededEngine(service: service)
        let recorder = PhaseRecorder()
        let observation = engine.observeStatus { recorder.record($0) }
        defer { observation.cancel() }
        let window = CalendarWindow.around(Date())

        try await waitUntil("every demo calendar read", timeout: 15) {
            let states = recorder.latest.map(\.calendar)
            return states.count == 2 && states.allSatisfy { if case .current = $0 { return true } else { return false } }
        }
        for account in accounts {
            let provider = try XCTUnwrap(service.provider(for: account) as? CalendarProvider)
            let served = try await provider.calendarEvents(in: window).events
            let stored = try store.calendarEvents(in: window, accountIDs: [account.id])
            XCTAssertGreaterThan(stored.count, 10, account.email)
            XCTAssertEqual(Set(stored.map(\.id)), Set(served.map(\.id)), "\(account.email): the store holds what the calendar has")
            XCTAssertTrue(stored.allSatisfy { $0.sync == .synced && $0.accountID == account.id })
        }
        let outlook = try XCTUnwrap(accounts.first { $0.kind == .microsoft })
        XCTAssertTrue(try store.calendarEvents(in: window, accountIDs: [outlook.id]).contains { $0.title == "Standup" })
        XCTAssertTrue(try store.calendarEvents(in: window, accountIDs: nil).contains { $0.response == .needsAction },
                      "the open invitations are on their calendars")

        // Time set aside for a mail reaches the demo calendar, and comes back from it as one event.
        let gmail = try XCTUnwrap(accounts.first { $0.kind == .gmail })
        let provider = try XCTUnwrap(service.provider(for: gmail) as? CalendarProvider)
        let mail = try XCTUnwrap(try store.conversations(ConversationQuery(accountIDs: [gmail.id], view: .inbox, limit: 1)).first)
        let source = try XCTUnwrap(try store.messages(in: mail.id).last).id
        let start = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400 + 13 * 3_600)
        let block = CalendarEvent(id: CalendarEvent.newLocalID(accountID: gmail.id), accountID: gmail.id, providerID: nil,
                                  title: mail.subject, start: start, end: start.addingTimeInterval(1_800),
                                  sourceMessage: source, sync: .creating)
        try engine.addCalendarEvent(block)
        try await waitUntil("set aside on the demo calendar", timeout: 15) {
            try store.calendarEvents(in: window, accountIDs: [gmail.id]).first { $0.id == block.id }?.sync == .synced
        }
        let settled = try XCTUnwrap(try store.calendarEvents(in: window, accountIDs: [gmail.id]).first { $0.id == block.id })
        let providerID = try XCTUnwrap(settled.providerID)
        XCTAssertEqual(settled.sourceMessage, source)
        var served = try await provider.calendarEvents(in: window).events
        XCTAssertEqual(served.filter { $0.providerID == providerID }.count, 1)

        let readAt = { recorder.latest.first { $0.accountID == gmail.id }?.calendar }
        guard case .current(let lastRead)? = readAt() else { return XCTFail("the block's turn read the calendar") }
        engine.refreshCalendars(accountID: gmail.id)
        try await waitUntil("read again", timeout: 15) {
            guard case .current(let at)? = readAt() else { return false }
            return at > lastRead
        }
        XCTAssertEqual(try store.calendarEvents(in: window, accountIDs: [gmail.id]).filter { $0.clientKey == settled.clientKey }.count, 1,
                       "the read finds the block by its key")

        try engine.removeCalendarEvent(id: block.id)
        try await waitUntil("removed from the demo calendar", timeout: 15) {
            try store.calendarEvents(in: window, accountIDs: [gmail.id]).allSatisfy { $0.id != block.id }
        }
        served = try await provider.calendarEvents(in: window).events
        XCTAssertFalse(served.contains { $0.providerID == providerID })
        await engine.stopAndWait()
    }
}
