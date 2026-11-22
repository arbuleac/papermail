import Foundation
import XCTest
@testable import PaperCore

/// Keep mail on this Mac in the engine (roadmap Q1.6, docs/ARCHITECTURE.md "Storage bounds"): when sweeps run (once
/// per launch after the first live cycle, when the window narrows, when a backfill ends, never on a timer), that
/// widening the window fetches nothing back, that opening an evicted message fetches it and keeps it for the rest of
/// the run, and the full-text optimize after a backfill.
final class StorageSweepTests: XCTestCase {
    private let id = Fixtures.accountID

    /// Fixture messages are dated November 2023, well outside a year; this one arrived today.
    private func recent(_ number: Int) -> MessageMetadata {
        var message = Fixtures.message(number)
        message.date = MailboxClock.aligned(Date().addingTimeInterval(-3_600))
        return message
    }

    private func storedBody(_ text: String) -> StoredBody {
        StoredBody(body: MessageBody(html: "<p>\(text)</p>", text: text), renderedHTML: "<p>\(text)</p>", plainText: text,
                   typesetting: .unstyled, declaresColors: false, coveredByNewYork: true)
    }

    /// An account whose head page and backfill are done, so its live lane only polls (empty pages) and its backfill
    /// lane has nothing to do: the sweeps under test are the only work.
    private func settledAccount(_ store: InMemoryMailStore, old: ClosedRange<Int>, recent recentNumbers: [Int] = []) throws {
        try store.setSyncCursor("c0", for: id)
        try store.setBootstrapState(BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: 1, isComplete: true), for: id)
        let messages = old.map { Fixtures.message($0) } + recentNumbers.map(recent)
        try store.upsertMessages(messages)
        for message in messages { try store.saveBody(storedBody("text \(message.id.providerID)"), for: message.id) }
    }

    private func messageID(_ number: Int) -> MessageID {
        MessageID(accountID: id, providerID: "\(number)")
    }

    // MARK: When

    /// The saved window is swept once per launch, after the first live cycle, and not again however many polls follow:
    /// nothing runs on a timer.
    func testTheFirstLiveCycleSweepsOnceAndPollsNeverSweepAgain() async throws {
        let store = InMemoryMailStore()
        let faulty = FaultyStore(base: store)
        let harness = try EngineHarness(store: store, engineStore: faulty, tune: { $0.evictionBatchSize = 2 })
        try settledAccount(store, old: 1...5, recent: [50])
        harness.engine.setMailRetention(.threeMonths)
        XCTAssertEqual(faulty.evictionCalls, 0, "an engine that is not running sweeps nothing")

        harness.engine.start()
        try await waitUntil("the launch sweep evicted the old bodies") { (1...5).allSatisfy { store.isEvicted(self.messageID($0)) } }
        await harness.engine.waitForStorageWork()
        XCTAssertNotNil(try store.body(for: messageID(50)), "today's mail keeps its body")
        let calls = faulty.evictionCalls
        XCTAssertEqual(calls, 3, "five bodies in batches of two, the last finding fewer than it asked for")
        XCTAssertEqual(faulty.evictionBatchStarts, [nil, Fixtures.message(2).date, Fixtures.message(4).date],
                       "each batch starts where the last one stopped, so the sweep reads the mailbox once")

        let polls = harness.provider.changesCalls.count
        try await waitUntil("several more polls") { harness.provider.changesCalls.count >= polls + 5 }
        await harness.engine.waitForStorageWork()
        XCTAssertEqual(faulty.evictionCalls, calls, "polls never sweep again")
        await harness.shutdown()
    }

    /// Narrowing the window while running sweeps at once. Widening it, back to Everything, evicts nothing more and
    /// fetches nothing back: the evicted bodies return only as their messages are opened.
    func testNarrowingSweepsAtOnceAndWideningFetchesNothingBack() async throws {
        let store = InMemoryMailStore()
        let faulty = FaultyStore(base: store)
        let harness = try EngineHarness(store: store, engineStore: faulty)
        try settledAccount(store, old: 1...3, recent: [40])
        for number in [1, 2, 3, 40] { harness.provider.bodies["\(number)"] = .success(MessageBody(html: "<p>\(number)</p>", text: "\(number)")) }
        let changes = Counter()
        let observation = harness.engine.observeStorageChanges { changes.increment() }
        defer { observation.cancel() }
        harness.engine.start()
        try await waitUntil("the first poll") { !harness.provider.changesCalls.isEmpty }
        await harness.engine.waitForStorageWork()
        XCTAssertNotNil(try store.body(for: messageID(1)), "Everything keeps every body")

        harness.engine.setMailRetention(.oneYear)
        XCTAssertEqual(harness.engine.mailRetention, .oneYear)
        try await waitUntil("narrowing swept") { (1...3).allSatisfy { store.isEvicted(self.messageID($0)) } }
        try await waitUntil("subscribers heard the size changed") { changes.value >= 1 }
        XCTAssertNotNil(try store.body(for: messageID(40)))

        await harness.engine.waitForStorageWork()
        let sweepsBeforeWidening = faulty.evictionCalls
        harness.engine.setMailRetention(.threeMonths)
        try await waitUntil("a narrower window sweeps again") { faulty.evictionCalls > sweepsBeforeWidening }
        await harness.engine.waitForStorageWork()
        let narrowed = faulty.evictionCalls
        harness.engine.setMailRetention(.oneYear)
        let pollsAfterOneYear = harness.provider.changesCalls.count
        try await waitUntil("a few polls after widening") { harness.provider.changesCalls.count >= pollsAfterOneYear + 4 }
        await harness.engine.waitForStorageWork()
        XCTAssertEqual(faulty.evictionCalls, narrowed, "a wider window starts no sweep")
        harness.engine.setMailRetention(.everything)
        let polls = harness.provider.changesCalls.count
        try await waitUntil("a few polls after Everything") { harness.provider.changesCalls.count >= polls + 4 }
        await harness.engine.waitForStorageWork()
        XCTAssertEqual(faulty.evictionCalls, narrowed, "nor does Everything")
        XCTAssertEqual(harness.provider.bodyCalls, [], "no body was fetched back")
        XCTAssertTrue((1...3).allSatisfy { store.isEvicted(messageID($0)) }, "and none was restored")
        XCTAssertEqual(try store.messageIDsMissingBodies(accountID: id, limit: 10), [], "the backfill is offered none of them")
        XCTAssertEqual(try allMessages(store).count, 4, "every message is still listed")
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .all, searchText: "text")).count, 1,
                       "and searched, through the plain text the evicted bodies kept")
        await harness.shutdown()
    }

    /// A large mailbox's sweep runs for seconds to a minute. Choosing Everything during it stops it at the next batch:
    /// widening never fetches back, so a sweep that went on to the old cutoff would leave the user with the shorter
    /// window's mailbox.
    func testChoosingEverythingDuringASweepStopsItAtTheNextBatch() async throws {
        let store = InMemoryMailStore()
        let faulty = FaultyStore(base: store)
        let harness = try EngineHarness(store: store, engineStore: faulty, tune: { $0.evictionBatchSize = 1 })
        try settledAccount(store, old: 1...10)
        let engine = harness.engine
        faulty.afterEviction { batch in
            if batch == 1 { engine.setMailRetention(.everything) }
        }
        engine.setMailRetention(.threeMonths)
        engine.start()
        try await waitUntil("the launch sweep's first batch") { faulty.evictionCalls >= 1 }
        await engine.waitForStorageWork()
        XCTAssertEqual(engine.mailRetention, .everything)
        XCTAssertEqual(faulty.sweptBodies, 1, "only the batch before Everything was chosen")
        XCTAssertEqual(faulty.evictionCalls, 1, "and no batch after it")
        XCTAssertEqual((1...10).filter { store.isEvicted(messageID($0)) }.count, 1)
        await harness.shutdown()
    }

    /// Choosing Everything while a batch is under way (looking for its candidates, or waiting for the writer) stops that
    /// batch too: the store reads the window again inside its write.
    func testChoosingEverythingWhileABatchIsUnderWayEvictsNothingOfIt() async throws {
        let store = InMemoryMailStore()
        let faulty = FaultyStore(base: store)
        let harness = try EngineHarness(store: store, engineStore: faulty, tune: { $0.evictionBatchSize = 10 })
        try settledAccount(store, old: 1...3)
        let engine = harness.engine
        faulty.duringEviction { batch in
            if batch == 1 { engine.setMailRetention(.everything) }
        }
        engine.setMailRetention(.threeMonths)
        engine.start()
        try await waitUntil("the launch sweep's first batch") { faulty.evictionCalls >= 1 }
        await engine.waitForStorageWork()
        XCTAssertEqual(faulty.evictionCalls, 1)
        XCTAssertEqual(faulty.sweptBodies, 0, "the batch under way evicted nothing")
        XCTAssertFalse((1...3).contains { store.isEvicted(messageID($0)) })
        await harness.shutdown()
    }

    /// The reader marks a conversation it renders while a batch is under way: the batch reads the marks again inside its
    /// write, so the body stays whole while the rest of the batch goes.
    func testABodyTheReaderMarksWhileABatchIsUnderWayStaysWhole() async throws {
        let store = InMemoryMailStore()
        let faulty = FaultyStore(base: store)
        let harness = try EngineHarness(store: store, engineStore: faulty, tune: { $0.evictionBatchSize = 10 })
        try settledAccount(store, old: 1...3)
        let engine = harness.engine
        let shown = messageID(2)
        faulty.duringEviction { batch in
            if batch == 1 { engine.keepBodies(of: [shown]) }
        }
        engine.setMailRetention(.threeMonths)
        engine.start()
        try await waitUntil("the launch sweep") { store.isEvicted(self.messageID(1)) && store.isEvicted(self.messageID(3)) }
        await engine.waitForStorageWork()
        XCTAssertFalse(store.isEvicted(shown), "marked while the batch was under way: whole")
        XCTAssertNotNil(try store.body(for: shown))
        await harness.shutdown()
    }

    /// Choosing a longer window during a sweep carries it on to the longer window's cutoff: mail the new window keeps
    /// keeps its body, mail outside both goes.
    func testChoosingALongerWindowDuringASweepKeepsWhatItKeeps() async throws {
        let store = InMemoryMailStore()
        let faulty = FaultyStore(base: store)
        let harness = try EngineHarness(store: store, engineStore: faulty, tune: { $0.evictionBatchSize = 1 })
        try settledAccount(store, old: 1...4)
        // Six months old: outside three months, inside a year.
        let halfYear = (20...23).map { number -> MessageMetadata in
            var message = Fixtures.message(number)
            message.date = MailboxClock.aligned(Date().addingTimeInterval(-182 * 86_400))
            return message
        }
        try store.upsertMessages(halfYear)
        for message in halfYear { try store.saveBody(storedBody("text \(message.id.providerID)"), for: message.id) }
        let engine = harness.engine
        faulty.afterEviction { batch in
            if batch == 1 { engine.setMailRetention(.oneYear) }
        }
        engine.setMailRetention(.threeMonths)
        engine.start()
        try await waitUntil("the launch sweep's first batch") { faulty.evictionCalls >= 1 }
        await engine.waitForStorageWork()
        XCTAssertTrue((1...4).allSatisfy { store.isEvicted(messageID($0)) }, "older than a year: evicted")
        XCTAssertFalse(halfYear.contains { store.isEvicted($0.id) }, "inside the year now chosen: whole")
        XCTAssertTrue(try halfYear.allSatisfy { try store.body(for: $0.id) != nil })
        await harness.shutdown()
    }

    /// Opening an evicted message fetches its body at once, as for mail the backfill has not reached, and the mark goes.
    /// It is kept for the rest of the run: a later sweep (here, the window narrowing again) leaves it, while it still
    /// evicts another old body.
    func testOpeningAnEvictedMessageFetchesItAndLaterSweepsLeaveIt() async throws {
        let harness = try EngineHarness()
        let store = harness.store
        try settledAccount(store, old: 1...2)
        harness.provider.bodies["1"] = .success(MessageBody(html: "<p>fetched again</p>", text: "fetched again"))
        harness.engine.setMailRetention(.threeMonths)
        harness.engine.start()
        try await waitUntil("the launch sweep") { store.isEvicted(self.messageID(1)) && store.isEvicted(self.messageID(2)) }

        let opened = try await harness.engine.ensureBody(for: messageID(1))
        XCTAssertEqual(opened.body.html, "<p>fetched again</p>")
        XCTAssertEqual(harness.provider.bodyCalls, ["1"], "fetched once, at once")
        XCTAssertFalse(store.isEvicted(messageID(1)), "the mark is cleared")
        XCTAssertEqual(try store.body(for: messageID(1))?.body.html, "<p>fetched again</p>")

        // The backfill fetches message 2 again for its text (as it would a body it never had), then the window narrows.
        try store.saveBody(storedBody("text 2 again"), for: messageID(2))
        harness.engine.setMailRetention(.everything)
        harness.engine.setMailRetention(.threeMonths)
        try await waitUntil("the second sweep") { store.isEvicted(self.messageID(2)) }
        await harness.engine.waitForStorageWork()
        XCTAssertFalse(store.isEvicted(messageID(1)), "the opened message stays whole until a later launch")
        XCTAssertEqual(try store.body(for: messageID(1))?.body.html, "<p>fetched again</p>")
        XCTAssertEqual(harness.provider.bodyCalls, ["1"], "and is not fetched twice")
        await harness.shutdown()
    }

    /// The backfill stores the old mail it brings in already evicted (source gone, text kept), so the store never grows
    /// past what the window keeps while it runs, and a backfill that ends optimizes the full-text index and sweeps (here
    /// finding nothing left to evict). Idle polls afterwards do neither again.
    func testABackfillStoresOldMailEvictedAndItsEndOptimizesTheIndex() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [[
            "": .success(BootstrapPage(messages: [recent(1)], nextPage: "p2", changeCursor: "c0")),
            "p2": .success(Fixtures.page(2...4, next: nil)),
        ]]
        for number in 1...4 { provider.bodies["\(number)"] = .success(MessageBody(html: "<p>b\(number)</p>", text: "body\(number)")) }
        let spy = MaintenanceSpy()
        let store = InMemoryMailStore()
        let faulty = FaultyStore(base: store)
        let harness = try EngineHarness(store: store, provider: provider, engineStore: faulty, maintenance: spy)
        harness.engine.setMailRetention(.oneYear)
        harness.engine.start()

        try await waitUntil("backfill complete") { try store.bootstrapState(for: self.id)?.isComplete == true }
        try await waitUntil("the index optimized once the backfill went idle") { spy.fullTextOptimizeCalls == 1 }
        try await waitUntil("the old mail stored evicted") { (2...4).allSatisfy { store.isEvicted(self.messageID($0)) } }
        await harness.engine.waitForStorageWork()
        XCTAssertGreaterThan(faulty.evictionCalls, 0, "the backfill's end swept")
        XCTAssertEqual(faulty.sweptBodies, 0, "and found every old body already stored evicted")
        XCTAssertNotNil(try store.body(for: messageID(1)), "the head page's recent mail keeps its body")
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .all, searchText: "body3")).count, 1,
                       "an evicted message's text is still searched")
        XCTAssertGreaterThanOrEqual(spy.reclaimRequests.count, 1, "and free pages are handed back at the same moment")

        let polls = provider.changesCalls.count
        try await waitUntil("idle polls") { provider.changesCalls.count >= polls + 5 }
        await harness.engine.waitForStorageWork()
        XCTAssertEqual(spy.fullTextOptimizeCalls, 1, "an idle lane does not optimize again")
        await harness.shutdown()
    }

    /// The backfill fetches only what is missing, newest first, and stores each body as it saves it: one older than the
    /// window evicted, so a large mailbox's first backfill never takes the full size on disk (a file an earlier build
    /// created could never give that space back). A body inside the window, one kept for this run because someone
    /// asked for it (the reader, `ensureBody`), and the live lane's are stored whole.
    func testTheBackfillStoresBodiesOutsideTheWindowAlreadyEvicted() async throws {
        let store = InMemoryMailStore()
        try store.upsertMessages([Fixtures.message(1), Fixtures.message(2), recent(3), Fixtures.message(4)])
        let provider = ScriptedProvider(accountID: id)
        for number in 1...4 { provider.bodies["\(number)"] = .success(MessageBody(html: "<p>body\(number)</p>", text: "body\(number)")) }
        let keepMail = KeepMailState()
        XCTAssertEqual(keepMail.setRetention(.oneYear), .everything)
        keepMail.keep([messageID(2)])
        let hydrator = Hydrator(accountID: id, store: store, provider: provider, sanitizer: RecordingSanitizer(), tuning: SyncTuning(),
                                evictionCutoff: { keepMail.evictionCutoff(for: $0) })

        _ = await hydrator.hydrateLive([messageID(4)])
        let outcome = await hydrator.hydratePaced()

        XCTAssertEqual(outcome.fetched, 3)
        XCTAssertTrue(store.isEvicted(messageID(1)), "older than the window: stored evicted")
        XCTAssertNil(try store.body(for: messageID(1)))
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .all, searchText: "body1")).count, 1, "its text is searched")
        XCTAssertNotNil(try store.body(for: messageID(2)), "kept for this run: whole")
        XCTAssertNotNil(try store.body(for: messageID(3)), "inside the window: whole")
        XCTAssertNotNil(try store.body(for: messageID(4)), "the live lane's: whole")
        XCTAssertEqual(try store.messageIDsMissingBodies(accountID: id, limit: 10), [], "nothing is fetched again")

        // Everything stores whole.
        XCTAssertEqual(keepMail.setRetention(.everything), .oneYear)
        XCTAssertNil(keepMail.evictionCutoff(for: messageID(1)))
    }

    /// Opening an old message just as the backfill saves its body: the backfill read the window before the reader marked
    /// the message kept and stores it evicted, while the opening joins that fetch. The reader reads the body back from
    /// the store, so it must be there, whole, and fetched once. Here the opening lands while the evicting save waits for
    /// the writer (busy with a page).
    func testOpeningOldMailWhileTheBackfillSavesItEvictedStoresItWhole() async throws {
        try await openWhileTheBackfillSaves(heldAfterSave: false)
    }

    /// As above, the opening landing after the evicting save, before the backfill's fetch has finished.
    func testOpeningOldMailJustAfterTheBackfillSavedItEvictedStoresItWhole() async throws {
        try await openWhileTheBackfillSaves(heldAfterSave: true)
    }

    private func openWhileTheBackfillSaves(heldAfterSave: Bool) async throws {
        let phase = heldAfterSave ? "held after the evicting save" : "held before the evicting save"
        let store = InMemoryMailStore()
        let faulty = FaultyStore(base: store)
        let old = Fixtures.message(1)
        try store.upsertMessages([old])
        let provider = ScriptedProvider(accountID: id)
        provider.bodies["1"] = .success(MessageBody(html: "<p>one</p>", text: "one"))
        let keepMail = KeepMailState()
        _ = keepMail.setRetention(.threeMonths)
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        faulty.aroundEvictingSaves { saved in
            guard saved == heldAfterSave else { return }
            held.signal()
            release.wait()
        }
        let hydrator = Hydrator(accountID: id, store: faulty, provider: provider, sanitizer: RecordingSanitizer(), tuning: SyncTuning(),
                                evictionCutoff: { keepMail.evictionCutoff(for: $0) })
        let paced = Task { await hydrator.hydratePaced() }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                held.wait()
                continuation.resume()
            }
        }

        // What MailEngine.ensureBody does: finds no body, marks the message kept, asks the hydrator.
        XCTAssertNil(try store.body(for: old.id), phase)
        keepMail.keep([old.id])
        let reads = faulty.bodyReads
        let opening = Task { try await hydrator.ensureBody(for: old.id) }
        // The opening looks at the store and joins the fetch in one turn of the hydrator, which the fetch needs before
        // it is done, so once it has looked the join is certain.
        try await waitUntil("the opening looked at the store") { faulty.bodyReads > reads }
        release.signal()
        let opened = try await opening.value
        _ = await paced.value

        XCTAssertEqual(opened.body.html, "<p>one</p>", phase)
        XCTAssertEqual(try store.body(for: old.id)?.body.html, "<p>one</p>", "whole in the store, where the reader reads it: \(phase)")
        XCTAssertFalse(store.isEvicted(old.id), phase)
        XCTAssertEqual(provider.bodyCalls, ["1"], "fetched once, the opening joining the backfill's fetch: \(phase)")
    }

    /// The full-text optimize after a backfill rewrites the whole index, about a second on a large mailbox. It runs one
    /// merge step per turn of the sweeper, and opening mail never waits on the sweeper, so neither opening an old
    /// message nor stopping the engine (quitting) waits for the merge.
    func testAFullTextMergeHoldsUpNeitherOpeningMailNorStopping() async throws {
        let provider = ScriptedProvider(accountID: Fixtures.accountID)
        provider.bootstrapRuns = [[
            "": .success(BootstrapPage(messages: [recent(1)], nextPage: "p2", changeCursor: "c0")),
            "p2": .success(Fixtures.page(2...4, next: nil)),
        ]]
        for number in 1...4 { provider.bodies["\(number)"] = .success(MessageBody(html: "<p>b\(number)</p>", text: "body\(number)")) }
        // 400 steps of 20 ms: eight seconds of merging if nothing could get in between.
        let spy = MaintenanceSpy(mergeSteps: 400, mergeStepDuration: 0.02)
        let harness = try EngineHarness(provider: provider, maintenance: spy)
        let store = harness.store
        harness.engine.setMailRetention(.oneYear)
        harness.engine.start()
        try await waitUntil("the merge under way") { spy.mergeStepsTaken >= 3 }
        XCTAssertTrue(store.isEvicted(messageID(2)))

        let opening = Date()
        let opened = try await harness.engine.ensureBody(for: messageID(2))
        XCTAssertEqual(opened.body.html, "<p>b2</p>")
        XCTAssertLessThan(Date().timeIntervalSince(opening), 1, "opening old mail does not wait for the merge")
        XCTAssertLessThan(spy.mergeStepsTaken, 300, "which is still under way")

        let stopping = Date()
        await harness.engine.stopAndWait()
        XCTAssertLessThan(Date().timeIntervalSince(stopping), 1.5, "stopping waits for one step, not the merge")
        let steps = spy.mergeStepsTaken
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(spy.mergeStepsTaken, steps, "and no step runs after it")
        await harness.shutdown()
    }

    /// What the reader shows is kept whole for the run: a sweep leaves it, so a conversation on screen keeps its body and
    /// the attachment list its chips and Quick Look read.
    func testBodiesTheReaderShowsAreLeftOutOfSweeps() async throws {
        let harness = try EngineHarness()
        let store = harness.store
        try settledAccount(store, old: 1...3)
        harness.engine.start()
        try await waitUntil("the first poll") { !harness.provider.changesCalls.isEmpty }
        await harness.engine.waitForStorageWork()

        harness.engine.keepBodies(of: [messageID(2)])
        harness.engine.setMailRetention(.threeMonths)
        try await waitUntil("the sweep") { store.isEvicted(self.messageID(1)) && store.isEvicted(self.messageID(3)) }
        await harness.engine.waitForStorageWork()
        XCTAssertFalse(store.isEvicted(messageID(2)), "the message on screen keeps its body")
        XCTAssertNotNil(try store.body(for: messageID(2))?.body.html)
        XCTAssertEqual(harness.provider.bodyCalls, [])
        await harness.shutdown()
    }

    /// The bodies of a few new messages the live lane hands to the backfill lane are not a backfill: no optimize.
    func testHandedOverBodiesAreNotABackfill() async throws {
        let spy = MaintenanceSpy()
        let harness = try EngineHarness(maintenance: spy, tune: { $0.liveHydrationLimit = 1 })
        let store = harness.store
        try settledAccount(store, old: 1...1)
        let arriving = (10...13).map(recent)
        for message in arriving { harness.provider.bodies[message.id.providerID] = .success(MessageBody(html: "<p>n</p>", text: "n")) }
        harness.provider.enqueueChanges(.success(Fixtures.changes(upserts: arriving, cursor: "c1")))
        harness.engine.start()
        try await waitUntil("every new body fetched") { try arriving.allSatisfy { try store.body(for: $0.id) != nil } }
        let polls = harness.provider.changesCalls.count
        try await waitUntil("a few more polls") { harness.provider.changesCalls.count >= polls + 4 }
        await harness.engine.waitForStorageWork()
        XCTAssertEqual(spy.fullTextOptimizeCalls, 0)
        await harness.shutdown()
    }

    /// Quitting stops a sweep between batches; the store is never written after the engine says it stopped.
    func testStoppingTheEngineStopsTheSweep() async throws {
        let store = InMemoryMailStore()
        let faulty = FaultyStore(base: store)
        let harness = try EngineHarness(store: store, engineStore: faulty, tune: { $0.evictionBatchSize = 1 })
        try settledAccount(store, old: 1...40)
        harness.engine.setMailRetention(.threeMonths)
        harness.engine.start()
        try await waitUntil("the sweep started") { faulty.evictionCalls > 0 }
        await harness.engine.stopAndWait()
        let afterStop = faulty.evictionCalls
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(faulty.evictionCalls, afterStop)
        await harness.shutdown()
    }
}
