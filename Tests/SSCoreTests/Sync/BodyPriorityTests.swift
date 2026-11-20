import Foundation
import XCTest
@testable import SSCore

/// Opening a message whose body is not stored puts that body ahead of the account's background work
/// (docs/ARCHITECTURE.md, "Opening a message"): no backfill request goes out while it is on its way, the live lane's
/// prefetch and the calendar's read wait for it, the hydrator's store reads never keep it from entering, an opened body
/// goes before the folded rest of its conversation, and a message turned to jumps the queue. The provider's bodies take
/// a while to come back, as over the network; nothing reaches it.
final class BodyPriorityTests: XCTestCase {
    private let account = Fixtures.accountID

    private func id(_ number: Int) -> MessageID {
        MessageID(accountID: account, providerID: "\(number)")
    }

    /// A settled account (a cursor, a finished listing) whose store holds `backlog` inbox messages without bodies, newer
    /// than the message opened (1), so the backfill's paced bodies keep going for the whole test.
    private func busyAccount(backlog: Int, store: InMemoryMailStore = InMemoryMailStore()) throws -> (InMemoryMailStore, ScriptedProvider) {
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages((1...(backlog + 1)).map { Fixtures.message($0, conversation: "t\($0)", isRead: true) })
        try store.setSyncCursor("c0", for: account)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: backlog + 1, isComplete: true),
                                    for: account)
        let provider = ScriptedProvider(accountID: account)
        for number in 1...(backlog + 1) {
            provider.bodies["\(number)"] = .success(MessageBody(html: "<p>\(number)</p>", text: "\(number)"))
        }
        return (store, provider)
    }

    /// The events from `start` on, from the start of `id`'s call to its answer.
    private func window(of id: String, in events: [String]) throws -> ArraySlice<String> {
        let start = try XCTUnwrap(events.firstIndex(of: "start:\(id)"), "\(id) was asked for")
        let end = try XCTUnwrap(events.firstIndex(of: "end:\(id)"), "\(id) was answered")
        return events[start...end]
    }

    // MARK: Ahead of the background

    func testAnOpenedBodyGoesOutAheadOfABusyBackfillAndNothingQueuedGoesUntilItLands() async throws {
        let (store, provider) = try busyAccount(backlog: 150)
        provider.bodyDelay = 0.08
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false)
        harness.engine.start()
        // Four paced bodies on their way at a time, one after another.
        try await waitUntil("the backfill is fetching bodies") { provider.bodyCalls.count >= 8 }

        let before = provider.bodyEvents.count
        let body = try await harness.engine.ensureBody(for: id(1), priority: .opened)
        XCTAssertEqual(body.plainText, "1")
        let events = Array(provider.bodyEvents[before...])
        let window = try window(of: "1", in: events)
        let startedMeanwhile = window.filter { $0.hasPrefix("start:") && $0 != "start:1" }
        XCTAssertEqual(startedMeanwhile, [], "no queued background body went out while the opened one was on its way")
        // Only a paced fetch already past its gate when the open came can start between the call and its request.
        let startedFirst = events[..<window.startIndex].filter { $0.hasPrefix("start:") }
        XCTAssertLessThanOrEqual(startedFirst.count, 4, "the open's request went out ahead of the queued batch")
        XCTAssertEqual(provider.bodyPriorities["1"], .foreground, "and asks the transport to send it first")

        let landed = provider.bodyCalls.count
        try await waitUntil("the backfill goes on once the open has landed") { provider.bodyCalls.count > landed }
        await harness.shutdown()
    }

    /// Without the hold the paced batch kept four bodies on their way and started a new one each time one came back,
    /// so an opened body shared the provider with a full batch for as long as it took.
    func testTheBackfillWaitsForEveryReaderFetchNotOnlyTheFirst() async throws {
        let (store, provider) = try busyAccount(backlog: 150)
        provider.bodyDelay = 0.05
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false)
        harness.engine.start()
        try await waitUntil("the backfill is fetching bodies") { provider.bodyCalls.count >= 8 }
        // A conversation of six whose bodies the reader asks for: the newest opened, the rest folded.
        let before = provider.bodyEvents.count
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { _ = try await harness.engine.ensureBody(for: self.id(6), priority: .opened) }
            for number in 1...5 {
                group.addTask { _ = try await harness.engine.ensureBody(for: self.id(number), priority: .conversation) }
            }
            try await group.waitForAll()
        }
        let events = Array(provider.bodyEvents[before...])
        let reader = Set((1...6).map { "start:\($0)" })
        let firstReader = try XCTUnwrap(events.firstIndex { reader.contains($0) })
        let lastAnswer = try XCTUnwrap(events.lastIndex { (1...6).map { "end:\($0)" }.contains($0) })
        let background = events[firstReader...lastAnswer].filter { $0.hasPrefix("start:") && !reader.contains($0) }
        XCTAssertEqual(background, [], "the backfill sent nothing until the last of the reader's bodies had landed")
        await harness.shutdown()
    }

    func testAnOpenEntersWhileTheBackfillIsReadingTheStoreSlowly() async throws {
        let base = InMemoryMailStore()
        let faulty = FaultyStore(base: base)
        let (store, provider) = try busyAccount(backlog: 20, store: base)
        _ = store
        let harness = try EngineHarness(store: base, provider: provider, seedAccount: false, engineStore: faulty)
        // Every look for missing bodies takes a second and a half, as a scan of a large mailbox can.
        faulty.missingBodiesDelay = 1.5
        harness.engine.start()
        try await waitUntil("the backfill is reading the store") { faulty.missingBodiesReads >= 1 }
        try await Task.sleep(for: .milliseconds(100))

        let asked = Date()
        let opening = Task { try await harness.engine.ensureBody(for: self.id(1), priority: .opened) }
        try await waitUntil("the opened body was asked for", timeout: 5) { provider.bodyCalls.contains("1") }
        let wait = Date().timeIntervalSince(asked)
        XCTAssertLessThan(wait, 0.75, "the open did not wait for the read to finish (it took \(wait) s)")
        _ = try await opening.value
        faulty.missingBodiesDelay = 0
        await harness.shutdown()
    }

    // MARK: The conversation's order

    func testTheOpenedBodyGoesFirstAndTheFoldedOnesFollowTwoAtATime() async throws {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages((1...6).map { Fixtures.message($0) })
        let provider = ScriptedProvider(accountID: account)
        for number in 1...6 { provider.bodies["\(number)"] = .success(MessageBody(html: nil, text: "\(number)")) }
        provider.bodyDelay = 0.03
        provider.heldBodies = ["6"]
        // Not started: nothing in the background, only the reader's fetches.
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false)
        let opened = Task { try await harness.engine.ensureBody(for: self.id(6), priority: .opened) }
        try await waitUntil("the opened body is on its way") { provider.bodyCalls == ["6"] }
        let folded = (1...5).map { number in
            Task { try await harness.engine.ensureBody(for: self.id(number), priority: .conversation) }
        }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(provider.bodyCalls, ["6"], "the folded bodies wait while the opened one is on its way")

        provider.releaseBody("6")
        _ = try await opened.value
        for task in folded { _ = try await task.value }
        XCTAssertEqual(provider.bodyCalls.first, "6")
        XCTAssertEqual(Set(provider.bodyCalls.dropFirst()), ["1", "2", "3", "4", "5"], "then the folded ones, each once")
        XCTAssertEqual(provider.bodyCalls.count, 6)
        XCTAssertEqual(provider.maxConcurrentBodyCalls, 2, "two at a time")
        XCTAssertEqual(provider.bodyPriorities.values.filter { $0 != .foreground }.count, 0)
        for number in 1...6 { XCTAssertNotNil(try store.body(for: id(number))) }
        await harness.shutdown()
    }

    func testAMessageTurnedToJumpsTheFoldedQueueAndIsFetchedOnce() async throws {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages((1...6).map { Fixtures.message($0) })
        let provider = ScriptedProvider(accountID: account)
        for number in 1...6 { provider.bodies["\(number)"] = .success(MessageBody(html: nil, text: "\(number)")) }
        provider.heldBodies = ["6"]
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false)
        let opened = Task { try await harness.engine.ensureBody(for: self.id(6), priority: .opened) }
        try await waitUntil("the opened body is on its way") { provider.bodyCalls == ["6"] }
        let folded = (1...5).map { number in
            Task { try await harness.engine.ensureBody(for: self.id(number), priority: .conversation) }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(provider.bodyCalls, ["6"])

        // The user expands the fourth: asked for again as opened, it goes now, beside the newest still on its way.
        let expanded = try await harness.engine.ensureBody(for: id(4), priority: .opened)
        XCTAssertEqual(expanded.plainText, "4")
        XCTAssertEqual(provider.bodyCalls, ["6", "4"], "ahead of the folded ones asked for before it")

        provider.releaseBody("6")
        _ = try await opened.value
        let folds = try await withThrowingTaskGroup(of: StoredBody.self) { group in
            for task in folded { group.addTask { try await task.value } }
            return try await group.reduce(into: [StoredBody]()) { $0.append($1) }
        }
        XCTAssertEqual(folds.count, 5, "the folded call for the expanded message got its body too")
        XCTAssertEqual(provider.bodyCalls.sorted(), ["1", "2", "3", "4", "5", "6"], "each body fetched once")
        await harness.shutdown()
    }

    func testTheOpenConversationGoesAheadOfPrerenderedNeighbours() async throws {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages((1...3).map { Fixtures.message($0) } + (10...11).map { Fixtures.message($0, conversation: "t2") })
        let provider = ScriptedProvider(accountID: account)
        for number in [1, 2, 3, 10, 11, 20] { provider.bodies["\(number)"] = .success(MessageBody(html: nil, text: "\(number)")) }
        try store.upsertMessages([Fixtures.message(20, conversation: "t3")])
        provider.heldBodies = ["20"]
        let harness = try EngineHarness(store: store, provider: provider, seedAccount: false)
        let opened = Task { try await harness.engine.ensureBody(for: self.id(20), priority: .opened) }
        try await waitUntil("the opened body is on its way") { provider.bodyCalls == ["20"] }
        // The neighbours' pre-render asked first; the open conversation's folded messages after them.
        let neighbours = [10, 11].map { number in
            Task { try await harness.engine.ensureBody(for: self.id(number), priority: .prefetch) }
        }
        // Each asks from its own task; the queue, not a guess at timing, says when all of them are waiting (a fixed
        // sleep let a folded message arrive after the release under a full suite's load, and a neighbour go first).
        try await waitForQueuedBodies(2, in: harness.engine)
        let conversation = [1, 2, 3].map { number in
            Task { try await harness.engine.ensureBody(for: self.id(number), priority: .conversation) }
        }
        try await waitForQueuedBodies(5, in: harness.engine)
        provider.releaseBody("20")
        _ = try await opened.value
        for task in neighbours + conversation { _ = try await task.value }
        let order = Array(provider.bodyCalls.dropFirst())
        let lastConversation = try XCTUnwrap(order.lastIndex { ["1", "2", "3"].contains($0) })
        let firstNeighbour = try XCTUnwrap(order.firstIndex { ["10", "11"].contains($0) })
        XCTAssertLessThan(lastConversation, firstNeighbour, "every folded message of the open conversation before a neighbour: \(order)")
        await harness.shutdown()
    }

    private func waitForQueuedBodies(_ count: Int, in engine: MailEngine, file: StaticString = #filePath,
                                     line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(30)
        while try await engine.foregroundBodyWaiters(for: account) < count {
            guard Date() < deadline else { return XCTFail("timed out waiting for \(count) queued bodies", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: The live lane and the calendar

    func testTheLivePrefetchWaitsForAnOpenedBody() async throws {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages([Fixtures.message(1), Fixtures.message(50), Fixtures.message(51)])
        let provider = ScriptedProvider(accountID: account)
        for number in [1, 50, 51] { provider.bodies["\(number)"] = .success(MessageBody(html: nil, text: "\(number)")) }
        provider.heldBodies = ["1"]
        var tuning = SyncTuning()
        tuning.backgroundYieldLimit = 10
        let hydrator = Hydrator(accountID: account, store: store, provider: provider, sanitizer: RecordingSanitizer(), tuning: tuning)
        let opened = Task { try await hydrator.ensureBody(for: self.id(1), priority: .opened) }
        try await waitUntil("the opened body is on its way") { provider.bodyCalls == ["1"] }
        let prefetch = Task { await hydrator.hydrateLive([self.id(50), self.id(51)]) }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(provider.bodyCalls, ["1"], "new mail's bodies wait for the one the user is reading")

        provider.releaseBody("1")
        _ = try await opened.value
        let outcome = await prefetch.value
        XCTAssertEqual(outcome.fetched, 2)
        XCTAssertEqual(Set(provider.bodyCalls.dropFirst()), ["50", "51"])
    }

    func testTheLivePrefetchStopsWaitingAfterTheLimit() async throws {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        try store.upsertMessages([Fixtures.message(1), Fixtures.message(50)])
        let provider = ScriptedProvider(accountID: account)
        for number in [1, 50] { provider.bodies["\(number)"] = .success(MessageBody(html: nil, text: "\(number)")) }
        provider.heldBodies = ["1"]
        var tuning = SyncTuning()
        tuning.backgroundYieldLimit = 0.3
        let hydrator = Hydrator(accountID: account, store: store, provider: provider, sanitizer: RecordingSanitizer(), tuning: tuning)
        let opened = Task { try await hydrator.ensureBody(for: self.id(1), priority: .opened) }
        try await waitUntil("the opened body is on its way") { provider.bodyCalls == ["1"] }
        let started = Date()
        let outcome = await hydrator.hydrateLive([id(50)])
        let waited = Date().timeIntervalSince(started)
        XCTAssertEqual(outcome.fetched, 1, "an open that hangs does not hold new mail's bodies for long")
        XCTAssertGreaterThanOrEqual(waited, 0.25)
        XCTAssertLessThan(waited, 3)
        provider.releaseBody("1")
        _ = try await opened.value
    }

    func testTheCalendarReadWaitsForAnOpenedBody() async throws {
        let store = InMemoryMailStore()
        try store.upsertAccount(Fixtures.account())
        let provider = ScriptedCalendarProvider(accountID: account, kind: .microsoft)
        let budget = QuotaBudget(quota: .standard(for: .microsoft))
        var tuning = SyncTuning()
        tuning.backgroundYieldLimit = 10
        let lane = CalendarLane(accountID: account, store: store, provider: provider, statusCenter: SyncStatusCenter(),
                                tuning: tuning, budget: budget, link: LaneLink(), isAppActive: { true })
        // The reader is waiting for a body of this account.
        budget.foreground.enter()
        let turn = Task { await lane.turn() }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(provider.readWindows.count, 0, "the window's read waits")
        budget.foreground.leave()
        await turn.value
        XCTAssertEqual(provider.readWindows.count, 1, "and goes once the body has landed")
    }

    // MARK: The budget's hold

    func testABackfillRequestWaitsWhileTheReaderWaitsForABody() async throws {
        for quota in [ProviderQuota.unlimited, .standard(for: .gmail)] {
            let budget = QuotaBudget(quota: quota)
            budget.foreground.enter()
            let granted = Task { try await budget.acquireBackfill(quota.bodyCost) }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(budget.foreground.backgroundWaits, 1, "waiting (\(quota.unitsPerMinute) a minute)")
            budget.foreground.leave()
            try await granted.value
        }
    }

    func testABackfillRequestWaitingForTheReaderCanBeCancelled() async throws {
        let budget = QuotaBudget(quota: .standard(for: .gmail))
        budget.foreground.enter()
        let granted = Task { try await budget.acquireBackfill(60) }
        try await Task.sleep(for: .milliseconds(50))
        granted.cancel()
        do {
            try await granted.value
            XCTFail("expected a cancellation")
        } catch is CancellationError {
            // expected
        }
        budget.foreground.leave()
    }

    func testTheHoldLetsWaitersGoWhenTheLastFetchLeavesOrTheLimitPasses() async throws {
        let hold = ForegroundHold()
        await hold.waitUntilIdle()
        hold.enter()
        hold.enter()
        let waiting = Task { await hold.waitUntilIdle() }
        hold.leave()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(hold.isActive, "one fetch is still on its way")
        hold.leave()
        await waiting.value
        XCTAssertFalse(hold.isActive)

        hold.enter()
        let started = Date()
        await hold.waitUntilIdle(limit: 0.1)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.09)
        let cancelled = Task { await hold.waitUntilIdle() }
        cancelled.cancel()
        await cancelled.value
        hold.leave()
    }
}
