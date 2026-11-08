import Foundation
import XCTest
@testable import SSCore

/// What the SQLite store does for Keep mail on this Mac and the maintenance around it (roadmap Q1.6,
/// docs/DATA-MODEL.md): which columns an eviction clears, that the full-text index stays consistent, incremental vacuum
/// on files created for it, the full-text optimize in steps, and that a sweep commits batch by batch.
final class SQLiteStorageBoundsTests: XCTestCase {
    private var directory: URL?
    private let account = AccountID("acct-a")
    private let now = Date()

    override func setUpWithError() throws {
        try super.setUpWithError()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SQLiteStorageBoundsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        directory = url
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
        try super.tearDownWithError()
    }

    private func store(file name: String? = nil) throws -> SQLiteMailStore {
        let store: SQLiteMailStore
        if let name {
            store = try SQLiteMailStore(path: try XCTUnwrap(directory).appendingPathComponent(name).path)
        } else {
            store = try SQLiteMailStore.inMemory()
        }
        try store.upsertAccount(Account(id: account, kind: .gmail, email: "a@example.com", displayName: "A", addedAt: now))
        return store
    }

    private func message(_ number: Int, daysAgo: Double) -> MessageMetadata {
        MessageMetadata(
            id: MessageID(accountID: account, providerID: "m\(number)"),
            conversationID: ConversationID(accountID: account, providerID: "c\(number)"),
            subject: "Subject \(number)", snippet: "Snippet \(number)",
            from: EmailAddress(name: "Sender", address: "sender@example.com"),
            date: MailboxClock.aligned(now.addingTimeInterval(-daysAgo * 86_400)),
            roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false
        )
    }

    /// A body whose source does not compress to nothing, so freeing it frees pages.
    private func body(_ words: String, size: Int = 0) -> StoredBody {
        let filler = (0..<(size / 36)).map { _ in UUID().uuidString }.joined(separator: " ")
        return StoredBody(body: MessageBody(html: "<p>\(words) \(filler)</p>", text: "\(words) \(filler)"),
                          renderedHTML: "<div>\(words) \(filler)</div>", plainText: words,
                          hasQuotedContent: false, blockedRemoteImageCount: 0, typesetting: .unstyled,
                          declaresColors: false, coveredByNewYork: true)
    }

    private var cutoff: Date { now.addingTimeInterval(-90 * 86_400) }

    func testEvictionClearsTheSourceAndRenderedHTMLAndKeepsTheIndexWhole() throws {
        let store = try store()
        try store.upsertMessages([message(1, daysAgo: 400), message(2, daysAgo: 1)])
        try store.saveBody(body("aardvark", size: 4_000), for: message(1, daysAgo: 400).id)
        try store.saveBody(body("badger"), for: message(2, daysAgo: 1).id)

        XCTAssertEqual(try store.evictBodies(receivedBefore: cutoff, excluding: [], limit: 10), 1)

        let evicted = try XCTUnwrap(try store.bodyRowState(for: message(1, daysAgo: 400).id))
        XCTAssertTrue(evicted.evicted)
        XCTAssertFalse(evicted.hasHTML, "the compressed HTML source is gone")
        XCTAssertFalse(evicted.hasText, "and the text part")
        XCTAssertEqual(evicted.renderedBytes, 0, "the rendered HTML is an empty blob (the column is NOT NULL)")
        XCTAssertEqual(evicted.plainText, "aardvark", "the plain text stays for search")
        let kept = try XCTUnwrap(try store.bodyRowState(for: message(2, daysAgo: 1).id))
        XCTAssertFalse(kept.evicted)
        XCTAssertTrue(kept.hasHTML)
        XCTAssertGreaterThan(kept.renderedBytes, 0)
        try store.verifyFullTextIndex()
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .all, searchText: "aardvark")).map(\.id.providerID), ["c1"])

        // Fetched again: whole, and the index still agrees with it.
        try store.saveBody(body("aardvark again"), for: message(1, daysAgo: 400).id)
        XCTAssertEqual(try store.bodyRowState(for: message(1, daysAgo: 400).id)?.evicted, false)
        try store.verifyFullTextIndex()
    }

    /// The backfill's save outside the window writes the plain text and the index, never the source: the file stays a
    /// fraction of what the same bodies stored whole take, so a short window bounds the store while a large mailbox's
    /// backfill runs, even in a file an earlier build created, which can never give space back.
    func testBodiesSavedOutsideTheWindowNeverTakeTheirFullSizeOnDisk() throws {
        let whole = try store(file: "whole.sqlite")
        let bounded = try store(file: "bounded.sqlite")
        defer {
            try? whole.close()
            try? bounded.close()
        }
        let messages = (1...60).map { message($0, daysAgo: 400) }
        try whole.upsertMessages(messages)
        try bounded.upsertMessages(messages)
        for message in messages {
            let fetched = body("text \(message.id.providerID)", size: 20_000)
            try whole.saveBody(fetched, for: message.id)
            XCTAssertTrue(try bounded.saveBody(fetched, for: message.id, evictingIfReceivedBefore: cutoff))
        }

        let state = try XCTUnwrap(try bounded.bodyRowState(for: messages[0].id))
        XCTAssertTrue(state.evicted)
        XCTAssertFalse(state.hasHTML)
        XCTAssertFalse(state.hasText)
        XCTAssertEqual(state.renderedBytes, 0)
        XCTAssertEqual(state.plainText, "text m1")
        try bounded.verifyFullTextIndex()
        XCTAssertEqual(try bounded.conversations(ConversationQuery(view: .all, searchText: "text", limit: 100)).count, 60)
        let wholePages = try whole.pageCounts().pages
        XCTAssertLessThan(try bounded.pageCounts().pages * 4, wholePages, "a fraction of the file the whole bodies take")
    }

    /// The size Settings shows follows a clean-up even in a file that keeps its size: the pages an eviction frees stay
    /// in the file for reuse, and the measurement leaves them out.
    func testTheMailboxSizeFollowsACleanUpThoughTheFileKeepsItsSize() throws {
        let path = try XCTUnwrap(directory).appendingPathComponent("footprint.sqlite").path
        let store = try store(file: "footprint.sqlite")
        defer { try? store.close() }
        let attachments = try XCTUnwrap(directory).appendingPathComponent("no-attachments", isDirectory: true)
        func onDisk() -> Int64 {
            ["", "-wal", "-shm"].reduce(0) { total, suffix in
                total + ((try? FileManager.default.attributesOfItem(atPath: path + suffix)[.size] as? Int64) ?? 0)
            }
        }
        let messages = (1...60).map { message($0, daysAgo: 400) }
        try store.upsertMessages(messages)
        for message in messages { try store.saveBody(body("text \(message.id.providerID)", size: 20_000), for: message.id) }
        let filesBefore = onDisk()
        let before = MailboxFootprint.bytes(databasePath: path, attachmentDirectory: attachments)

        XCTAssertEqual(try store.evictBodies(receivedBefore: cutoff, excluding: [], limit: 100), 60)
        let after = MailboxFootprint.bytes(databasePath: path, attachmentDirectory: attachments)

        XCTAssertGreaterThanOrEqual(onDisk(), filesBefore, "no vacuum ran, so the files keep their size")
        XCTAssertGreaterThan(MailboxFootprint.freeBytes(databasePath: path), 0, "the evicted bodies' pages are free for reuse")
        XCTAssertLessThan(after * 2, before, "the size shown drops with what the mail now takes")
    }

    /// A sweep is many short transactions, never one long one: a user action written meanwhile waits for one batch.
    func testASweepCommitsBatchByBatch() async throws {
        let store = try store()
        let old = (1...10).map { message($0, daysAgo: 400 + Double($0)) }
        try store.upsertMessages(old + [message(99, daysAgo: 1)])
        for message in old { try store.saveBody(body("old \(message.id.providerID)"), for: message.id) }
        try store.saveBody(body("recent"), for: message(99, daysAgo: 1).id)
        let commits = Counter()
        let observation = try store.observeBodyCommits { commits.increment() }
        defer { observation.cancel() }

        var tuning = SyncTuning()
        tuning.evictionBatchSize = 3
        let sweeper = StorageSweeper(store: store, maintenance: nil, tuning: tuning, retention: { .threeMonths }, changed: {})
        await sweeper.request(.evict)
        await sweeper.waitUntilIdle()

        XCTAssertEqual(commits.value, 4, "ten bodies in batches of three: four transactions")
        for message in old { XCTAssertNil(try store.body(for: message.id)) }
        XCTAssertNotNil(try store.body(for: message(99, daysAgo: 1).id))
    }

    /// A batch asks for its rules again inside its write, holding the writer: a message the reader marked kept, or a
    /// window widened, while the batch read its candidates on a reader (or waited for the writer behind a backfill
    /// page) is honoured.
    func testABatchAsksForItsRulesAgainBeforeTheBodiesGo() throws {
        let store = try store()
        let shown = message(1, daysAgo: 400)
        let other = message(2, daysAgo: 380)
        let halfYear = message(3, daysAgo: 182)
        try store.upsertMessages([shown, other, halfYear])
        for message in [shown, other, halfYear] { try store.saveBody(body("text \(message.id.providerID)"), for: message.id) }

        var asked = 0
        let marked = try store.evictBodies(from: nil, limit: 10) {
            asked += 1
            // The reader marks the message it renders after the candidates were read.
            return (self.cutoff, asked == 1 ? [] : [shown.id])
        }
        XCTAssertEqual(asked, 2, "once to look, once in the write")
        XCTAssertEqual(marked.evicted, 2)
        XCTAssertNotNil(try store.body(for: shown.id), "marked while the batch was under way: whole")
        XCTAssertNil(try store.body(for: other.id))
        XCTAssertNil(try store.body(for: halfYear.id))

        try store.saveBody(body("text m2"), for: other.id)
        try store.saveBody(body("text m3"), for: halfYear.id)
        asked = 0
        let everything = try store.evictBodies(from: nil, limit: 10) {
            asked += 1
            return asked == 1 ? (self.cutoff, [shown.id]) : nil
        }
        XCTAssertEqual(everything.evicted, 0, "Everything chosen while the batch looked: nothing goes")
        XCTAssertNotNil(try store.body(for: other.id))

        asked = 0
        let longer = try store.evictBodies(from: nil, limit: 10) {
            asked += 1
            return (asked == 1 ? self.cutoff : self.now.addingTimeInterval(-365 * 86_400), [shown.id])
        }
        XCTAssertEqual(longer.evicted, 1, "a year chosen while the batch looked: only what is older goes")
        XCTAssertNil(try store.body(for: other.id))
        XCTAssertNotNil(try store.body(for: halfYear.id))
    }

    /// The candidate read is a range on `messages_by_date` bounded on both sides: below by where the last batch stopped,
    /// above by the cutoff. `evicted` is only checked once a row has been read, so without the lower bound each batch
    /// would walk again past every body earlier batches evicted, and a first sweep would cost the square of the mailbox.
    func testTheCandidateReadIsARangeFromWhereTheLastBatchStopped() throws {
        let store = try store()
        let plan = try store.evictionCandidatesPlan()
        XCTAssertTrue(plan.contains { $0.contains("messages_by_date") && $0.contains("date_ms>? AND date_ms<?") }, "\(plan)")
        XCTAssertFalse(plan.contains { $0.hasPrefix("SCAN m") || $0.hasPrefix("SCAN messages") }, "\(plan)")
    }

    /// A new file is created for incremental vacuum, so the pages an eviction or a delete frees go back to the file
    /// system a bounded step at a time.
    func testANewFileGivesFreePagesBackInSteps() throws {
        let store = try store(file: "new.sqlite")
        defer { try? store.close() }
        XCTAssertEqual(try store.autoVacuumMode(), 2, "INCREMENTAL")
        let messages = (1...60).map { message($0, daysAgo: 400) }
        try store.upsertMessages(messages)
        for message in messages { try store.saveBody(body("text", size: 20_000), for: message.id) }
        XCTAssertEqual(try store.reclaimFreePages(upTo: 8), 0, "nothing is free yet")

        while try store.evictBodies(receivedBefore: cutoff, excluding: [], limit: 20) > 0 {}
        let before = try store.pageCounts()
        XCTAssertGreaterThan(before.free, 16, "evicting the sources freed pages")

        XCTAssertEqual(try store.reclaimFreePages(upTo: 8), 8, "one step hands back at most what it is asked for")
        var steps = 1
        while let reclaimed = try store.reclaimFreePages(upTo: 8), reclaimed == 8 { steps += 1 }
        let after = try store.pageCounts()
        XCTAssertEqual(after.free, 0)
        XCTAssertEqual(after.pages, before.pages - before.free, "the file shrank by every free page")
        XCTAssertGreaterThan(steps, 1)
        XCTAssertEqual(try store.reclaimFreePages(upTo: 8), 0)
        XCTAssertEqual(try store.body(for: messages[0].id), nil)
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .all, searchText: "text")).count, 60)
    }

    /// FTS5's optimize, done as 'merge' steps: many index writes leave many b-trees, the steps merge them, and search
    /// and the index's own integrity check agree afterwards.
    func testTheFullTextOptimizeMergesInStepsAndSearchStillWorks() throws {
        let store = try store()
        for number in 1...120 {
            try store.upsertMessages([message(number, daysAgo: Double(number))])
            try store.saveBody(body("word\(number) shared"), for: message(number, daysAgo: Double(number)).id)
        }
        let steps = try mergeAll(store)
        XCTAssertGreaterThan(steps, 1, "the merge took more than the step that finds nothing left")
        XCTAssertLessThan(steps, 10_000, "and it settled")
        try store.verifyFullTextIndex()
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .all, searchText: "word77")).map(\.id.providerID), ["c77"])
        XCTAssertEqual(try store.conversations(ConversationQuery(view: .all, searchText: "shared", limit: 500)).count, 120)
        XCTAssertLessThanOrEqual(try mergeAll(store), 2, "an optimized index has (almost) nothing left to merge")
        try store.optimize()
    }

    /// The sweeper's loop, one page per step: steps until one finds nothing left.
    private func mergeAll(_ store: SQLiteMailStore) throws -> Int {
        var steps = 0
        while steps < 10_000 {
            let merged = try store.mergeFullTextIndex(pages: 1, startingOver: steps == 0)
            steps += 1
            if !merged { break }
        }
        return steps
    }

    // MARK: The sweeper's vacuum steps

    func testIncrementalVacuumRunsOnlyWhereTheFileAllowsIt() async throws {
        var tuning = SyncTuning()
        tuning.vacuumPagesPerStep = 256
        let store = InMemoryMailStore()

        let oldFile = MaintenanceSpy(reclaimable: nil)
        let sweeper = StorageSweeper(store: store, maintenance: oldFile, tuning: tuning, retention: { .everything }, changed: {})
        await sweeper.request(.reclaim)
        await sweeper.waitUntilIdle()
        XCTAssertEqual(oldFile.reclaimRequests, [256], "asked once; a file without incremental vacuum answers nil and nothing more is tried")

        let newFile = MaintenanceSpy(reclaimable: 600)
        let changed = Counter()
        let sweeper2 = StorageSweeper(store: store, maintenance: newFile, tuning: tuning, retention: { .everything },
                                      changed: { changed.increment() })
        await sweeper2.request(.reclaim)
        await sweeper2.waitUntilIdle()
        XCTAssertEqual(newFile.reclaimRequests, [256, 256, 256], "steps until one hands back fewer pages than asked")
        XCTAssertEqual(newFile.reclaimed, 600)
        XCTAssertEqual(changed.value, 1, "the size changed, so subscribers hear of it once")

        tuning.vacuumMaxSteps = 2
        let capped = MaintenanceSpy(reclaimable: 10_000)
        let sweeper3 = StorageSweeper(store: store, maintenance: capped, tuning: tuning, retention: { .everything }, changed: {})
        await sweeper3.request(.reclaim)
        await sweeper3.waitUntilIdle()
        XCTAssertEqual(capped.reclaimRequests.count, 2, "one idle moment takes a bounded number of steps")
    }
}

/// A thread-safe counter for callbacks from any thread.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

/// Records the maintenance the engine asks for. `reclaimable` nil plays a file without incremental vacuum. An optimize
/// of the full-text index finds `mergeSteps` steps of work, each taking `mergeStepDuration` of the calling thread.
final class MaintenanceSpy: MailStoreMaintenance, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int?
    private var requests: [Int] = []
    private var given = 0
    private var optimizes = 0
    private var fullTextOptimizes = 0
    private var merges = 0
    private var mergeWorkLeft = 0
    private let mergeSteps: Int
    private let mergeStepDuration: TimeInterval

    init(reclaimable: Int? = 0, mergeSteps: Int = 1, mergeStepDuration: TimeInterval = 0) {
        remaining = reclaimable
        self.mergeSteps = mergeSteps
        self.mergeStepDuration = mergeStepDuration
    }

    var reclaimRequests: [Int] { lock.withLock { requests } }
    var reclaimed: Int { lock.withLock { given } }
    var optimizeCalls: Int { lock.withLock { optimizes } }
    /// Optimizes started (merge steps that start over).
    var fullTextOptimizeCalls: Int { lock.withLock { fullTextOptimizes } }
    var mergeStepsTaken: Int { lock.withLock { merges } }

    func optimize() throws {
        lock.withLock { optimizes += 1 }
    }

    func mergeFullTextIndex(pages: Int, startingOver: Bool) throws -> Bool {
        let merged: Bool = lock.withLock {
            merges += 1
            if startingOver {
                fullTextOptimizes += 1
                mergeWorkLeft = mergeSteps
            }
            guard mergeWorkLeft > 0 else { return false }
            mergeWorkLeft -= 1
            return true
        }
        if mergeStepDuration > 0 { Thread.sleep(forTimeInterval: mergeStepDuration) }
        return merged
    }

    func reclaimFreePages(upTo pages: Int) throws -> Int? {
        lock.withLock {
            requests.append(pages)
            guard let left = remaining else { return nil }
            let step = min(pages, left)
            remaining = left - step
            given += step
            return step
        }
    }
}
