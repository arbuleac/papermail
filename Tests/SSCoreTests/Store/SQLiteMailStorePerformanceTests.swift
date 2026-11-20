import XCTest
@testable import SSCore

/// The store half of the budgets in docs/ARCHITECTURE.md, measured on the synthetic mailbox (`PerfMailbox`: 300,000
/// messages, three accounts, a Graph mailbox of 200 folders) in a real file, with Keep mail on this Mac at Everything
/// and then at 1 year: the first sweep runs between the two, and every read and write is measured again after it. It
/// takes a while to load, so it only runs with `SS_PERF=1` in the environment:
///
///     SS_PERF=1 swift test --filter SQLiteMailStorePerformanceTests
///
/// `SS_PERF_MESSAGES` sets another size.
final class SQLiteMailStorePerformanceTests: XCTestCase {
    private typealias Perf = PerfMailbox
    private static let batchSize = PerfMailbox.batchSize

    func testSyntheticMailboxStaysWithinBudget() async throws {
        guard ProcessInfo.processInfo.environment["SS_PERF"] == "1" else {
            throw XCTSkip("set SS_PERF=1 to run the synthetic-mailbox benchmark")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMailStorePerformanceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)

        let mailbox = Perf.make()
        let loaded = try Perf.load(mailbox, into: store)
        Perf.report("load \(mailbox.messages.count) messages in \(Self.batchSize)-message batches", loaded.load)
        Perf.report("slowest load batch", loaded.slowestBatch)
        Perf.report("hydrate \(mailbox.messages.count) bodies", loaded.hydrate)

        let inboxCount = try store.conversations(ConversationQuery(view: .inbox, limit: .max)).count
        let allCount = try store.conversations(ConversationQuery(view: .all, limit: .max)).count
        print("SS_PERF conversations: \(allCount) total, \(inboxCount) in the inbox")

        // Local actions go through the engine, as a key does: applied to the store and queued in one transaction.
        let harness = try EngineHarness(seedAccount: false, engineStore: store)
        let engine = harness.engine
        let threads = Dictionary(grouping: mailbox.messages, by: \.conversationID)
        var used: Set<ConversationID> = []
        /// An inbox conversation of `size` messages, none in the Trash or Spam, not acted on yet in this run, all of it
        /// received since `since`.
        func freshConversation(size: Int = 8, since: Date = .distantPast) throws -> [MessageMetadata] {
            let thread = try XCTUnwrap(mailbox.messages.lazy.compactMap { threads[$0.conversationID] }.first { thread in
                thread.count == size && thread.contains { $0.roles.contains(.inbox) } && !used.contains(thread[0].conversationID)
                    && thread.allSatisfy { $0.roles.isDisjoint(with: [.trash, .spam]) && $0.date >= since }
            })
            used.insert(thread[0].conversationID)
            return thread
        }

        try measureReads(store, mailbox: mailbox, retention: "Everything", open: try freshConversation())
        try measureWrites(store, mailbox: mailbox, engine: engine, retention: "Everything", round: 0, conversation: { try freshConversation() })

        // Keep mail on this Mac at 1 year: the first sweep after the setting, as the launch sweep or a narrowed window runs
        // it, while the user stars and unstars a conversation inside the window every 2 ms.
        let cutoff = Perf.oneYearCutoff(mailbox)
        let starred = try XCTUnwrap(mailbox.messages.last { $0.date >= cutoff && $0.roles.contains(.inbox) })
        var star = false
        let toggle = { () throws -> Void in
            star.toggle()
            try engine.perform(.setStarred(star), on: [starred.id])
        }
        let sweepResult = SweepBox()
        let duringSweep = try Perf.actions(during: { sweepResult.value = try Perf.sweep(store, to: cutoff) }, toggle)
        let sweep = try XCTUnwrap(sweepResult.value)
        Perf.report("1 year: first sweep, \(sweep.evicted) bodies evicted in \(sweep.batches) batches", sweep.total)
        Perf.report("1 year: slowest sweep batch, read and write", sweep.slowestBatch)
        Perf.report("1 year: a sweep batch's hold on the writer, median", sweep.medianWrite)
        Perf.report("1 year: a sweep batch's hold on the writer, p95", sweep.p95Write)
        Perf.report("1 year: a sweep batch's hold on the writer, longest", sweep.slowestWrite)
        Perf.report("1 year: star during the sweep, median of \(duringSweep.count)", Perf.percentile(duringSweep, 0.5))
        Perf.report("1 year: star during the sweep, p95", Perf.percentile(duringSweep, 0.95))
        Perf.report("1 year: star during the sweep, longest", duringSweep.max() ?? 0)
        XCTAssertGreaterThan(sweep.evicted, mailbox.messages.count / 3, "about half the fixture lies outside a year")
        // The documented exception (ARCHITECTURE.md, "Storage bounds" and the budget table): one batch in twenty is the
        // commit in which SQLite checkpoints its WAL, so during the few seconds of a first sweep to 1 year the slowest
        // keys wait 20 to 27 ms. Half of them still land well inside the 16 ms, and none waits longer than one checkpoint.
        XCTAssertLessThan(Perf.percentile(duringSweep, 0.5), 16, "a local action during the sweep is inside its budget")
        XCTAssertLessThan(duringSweep.max() ?? 0, 40, "and waits for one sweep batch's checkpoint at most")
        let again = try Perf.sweep(store, to: cutoff)
        Perf.report("1 year: a sweep with nothing left to evict (\(again.batches) batches)", again.total)
        XCTAssertEqual(again.evicted, 0)

        // The backfill stores a body outside the window already evicted, one transaction a body; inside it, whole.
        let old = mailbox.messages.filter { $0.date < cutoff && $0.roles.isDisjoint(with: [.drafts]) }.prefix(51)
        let recent = mailbox.messages.filter { $0.date >= cutoff }.prefix(51)
        var evictedSaves: [Double] = [], wholeSaves: [Double] = []
        for message in old {
            evictedSaves.append(try Perf.milliseconds { _ = try store.saveBody(mailbox.body(for: message), for: message.id,
                                                                               evictingIfReceivedBefore: cutoff) })
        }
        for message in recent {
            wholeSaves.append(try Perf.milliseconds { _ = try store.saveBody(mailbox.body(for: message), for: message.id,
                                                                             evictingIfReceivedBefore: cutoff) })
        }
        Perf.report("1 year: the backfill saves a body outside the window, evicted, median", evictedSaves.sorted()[evictedSaves.count / 2])
        Perf.report("1 year: the backfill saves a body inside the window, whole, median", wholeSaves.sorted()[wholeSaves.count / 2])
        XCTAssertNil(try store.body(for: try XCTUnwrap(old.first).id), "stored evicted")

        let recentConversation = try freshConversation(since: cutoff)
        try measureReads(store, mailbox: mailbox, retention: "1 year", open: recentConversation)
        try measureWrites(store, mailbox: mailbox, engine: engine, retention: "1 year", round: 1, conversation: { try freshConversation() })

        // A Graph folder gone (deleted, or dropped by the folder walk): every message the account stores in it is queued
        // for a lookup, the user starring meanwhile.
        let graph = try XCTUnwrap(mailbox.accounts.first { $0.kind == .microsoft })
        let folder = try XCTUnwrap(mailbox.graphFolderIDs.first)
        let inFolder = mailbox.messages.filter { $0.id.accountID == graph.id && $0.folderID == folder }.count
        var queued = 0
        let gone = try Perf.milliseconds { queued = try store.queueLookups(accountID: graph.id, inFolders: [folder]) }
        Perf.report("a Graph folder of \(mailbox.graphFolderIDs.count) gone: \(queued) of its \(inFolder) messages queued for lookup", gone)
        XCTAssertEqual(queued, inFolder)
        // Five more folders gone, one after another, each its own scan, the user starring every 2 ms meanwhile. The scan
        // reads the account's 100,000 rows on a reader; only the inserts take the writer (it held it for the whole scan,
        // 63 ms a folder, before roadmap Q4.3).
        let goneOneByOne = Array(mailbox.graphFolderIDs.dropFirst().prefix(5))
        let duringLookups = try Perf.actions(during: {
            for folder in goneOneByOne { _ = try store.queueLookups(accountID: graph.id, inFolders: [folder]) }
        }, toggle)
        Perf.report("five Graph folders gone one after another; star meanwhile, median of \(duringLookups.count)", Perf.percentile(duringLookups, 0.5))
        Perf.report("five Graph folders gone one after another; star meanwhile, longest", duringLookups.max() ?? 0)
        XCTAssertLessThan(duringLookups.max() ?? 0, 16, "a local action never waits for a folder's scan")

        await harness.shutdown()
        try store.close()
    }

    // MARK: Reads

    private func measureReads(_ store: SQLiteMailStore, mailbox: SyntheticMailbox, retention: String,
                              open conversation: [MessageMetadata]) throws {
        // Reads: median of several runs after one warm-up, since a list refresh is never the first read.
        let inbox = try Perf.median(runs: 7) { try store.conversations(ConversationQuery(view: .inbox)) }
        Perf.report("\(retention): unified inbox, 200 rows", inbox.milliseconds)
        XCTAssertFalse(inbox.value.isEmpty)
        XCTAssertLessThan(inbox.milliseconds, 50, "inbox query budget")

        let focusedUnread = try Perf.median(runs: 7) {
            try store.conversations(ConversationQuery(accountIDs: [mailbox.accounts[0].id], view: .inbox, section: .focused, unreadOnly: true))
        }
        Perf.report("\(retention): one account, focused, unread only", focusedUnread.milliseconds)
        XCTAssertLessThan(focusedUnread.milliseconds, 50, "filtered inbox budget")

        let unread = try Perf.median(runs: 7) { try store.unreadInboxCount(accountIDs: nil) }
        Perf.report("\(retention): unread inbox count (\(unread.value))", unread.milliseconds)

        // Search as the user types a name, a subject phrase and a body word; the last token is a prefix.
        for text in ["nakam", "quarterly bud", "spreadsheet"] {
            let search = try Perf.median(runs: 5) { try store.conversations(ConversationQuery(view: .all, searchText: text)) }
            Perf.report("\(retention): search \"\(text)\" (\(search.value.count) rows)", search.milliseconds)
            XCTAssertFalse(search.value.isEmpty, text)
            XCTAssertLessThan(search.milliseconds, 50, "search budget for \"\(text)\"")
        }

        // The store's part of opening a conversation whose bodies are cached: its messages, then each body.
        let id = conversation[0].conversationID
        let opened = try Perf.median(runs: 7) { () -> Int in
            let messages = try store.messages(in: id)
            return try messages.compactMap { try store.body(for: $0.id) }.count
        }
        Perf.report("\(retention): a conversation's \(conversation.count) messages and their bodies read (\(opened.value) bodies)", opened.milliseconds)
        XCTAssertEqual(opened.value, conversation.count, "a conversation inside the window keeps its bodies")

        let hydration = try Perf.median(runs: 5) { try store.messageIDsMissingBodies(accountID: mailbox.accounts[0].id, limit: 50) }
        Perf.report("\(retention): next 50 bodies to hydrate", hydration.milliseconds)
    }

    // MARK: Writes

    private func measureWrites(_ store: SQLiteMailStore, mailbox: SyntheticMailbox, engine: MailEngine, retention: String,
                               round: Int, conversation: () throws -> [MessageMetadata]) throws {
        // A poll re-upserting a page of known messages, and pages of brand-new ones.
        let known = Array(mailbox.messages.dropFirst(round * Self.batchSize).prefix(Self.batchSize))
        let reupsert = try Perf.median(runs: 5) { try store.upsertMessages(known) }
        Perf.report("\(retention): re-upsert \(Self.batchSize) known messages", reupsert.milliseconds)
        XCTAssertLessThan(reupsert.milliseconds, 100, "upsert budget")

        let fresh = SyntheticMailbox(seed: 99 + UInt64(round), accountCount: 3, messageCount: Self.batchSize * 5).messages.map { original in
            var message = original
            message.id = MessageID(accountID: original.id.accountID, providerID: "new\(round)-" + original.id.providerID)
            message.conversationID = ConversationID(accountID: original.id.accountID, providerID: "new\(round)-" + original.conversationID.providerID)
            return message
        }
        var insertTimings: [Double] = []
        for batch in stride(from: 0, to: fresh.count, by: Self.batchSize).map({ Array(fresh[$0..<$0 + Self.batchSize]) }) {
            insertTimings.append(try Perf.milliseconds { try store.upsertMessages(batch) })
        }
        let insert = insertTimings.sorted()[insertTimings.count / 2]
        Perf.report("\(retention): insert \(Self.batchSize) new messages", insert)
        XCTAssertLessThan(insert, 100, "upsert budget")

        // Every local action of the budget row, on an 8-message conversation, through the engine as a key sends it.
        func action(_ label: String, _ work: () throws -> Void) throws {
            let elapsed = try Perf.milliseconds(work)
            Perf.report("\(retention): \(label)", elapsed)
            XCTAssertLessThan(elapsed, 16, "local action budget: \(label)")
        }
        let kind = { (account: AccountID) in mailbox.accounts.first { $0.id == account }?.kind ?? .gmail }
        func targets(_ change: MetadataChange, _ thread: [MessageMetadata]) -> [MessageID] {
            MailActionRecord.targets(for: change, in: thread, kind: kind(thread[0].id.accountID)).map(\.id)
        }
        let archived = try conversation()
        try action("archive an 8-message conversation") { try engine.perform(.archive, on: targets(.archive, archived)) }
        let starred = try conversation()
        try action("star an 8-message conversation") { try engine.perform(.setStarred(true), on: targets(.setStarred(true), starred)) }
        let read = try conversation()
        try action("mark an 8-message conversation read") { try engine.perform(.setRead(true), on: targets(.setRead(true), read)) }
        let spam = try conversation()
        try action("mark an 8-message conversation as spam") { try engine.perform(.markSpam, on: targets(.markSpam, spam)) }
        let snoozed = try conversation()
        try action("snooze an 8-message conversation (its archive in the same write)") {
            try engine.setSnoozes([Snooze.Change(conversationID: snoozed[0].conversationID, until: Date().addingTimeInterval(86_400))],
                                  performing: [MailActionRecord.Step(change: .archive, targets: targets(.archive, snoozed))])
        }
        let muted = try conversation()
        try action("mute an 8-message conversation (its archive in the same write)") {
            try engine.setMuted(true, conversations: [muted[0].conversationID],
                                performing: [MailActionRecord.Step(change: .archive, targets: targets(.archive, muted))], returnMarks: [:])
        }
        let ruled = try conversation()
        let sender = try XCTUnwrap(ruled.first { $0.roles.contains(.inbox) }?.from?.address)
        let fromSender = ruled.filter { $0.from?.address == sender && $0.roles.contains(.inbox) }.map(\.id)
        try action("block a sender (their mail in the conversation trashed in the same write)") {
            try engine.setSenderRule(.trash, for: sender, accountID: ruled[0].id.accountID,
                                     performing: [MailActionRecord.Step(change: .trash, targets: fromSender)])
        }
        let unsubscribed = try conversation()
        try action("unsubscribe (one-click request and the archive in one write)") {
            try engine.unsubscribe(.oneClick(URL(string: "https://list.example.com/u/\(round)")!), accountID: unsubscribed[0].id.accountID,
                                   archiving: targets(.archive, unsubscribed), endingSnoozesOf: [])
        }

        // Arrival rules (Mute, sender rules): a page of new mail into a mailbox with mutes and rules set, then a burst every
        // message of which a rule takes, each archived or trashed in the page's own write. Last, since the operations they
        // queue make every later upsert replay them.
        let mutedForArrival = Array(Set(mailbox.messages.dropFirst(2_000 * round).prefix(2_000).map(\.conversationID)).prefix(50))
        try store.setMuted(true, conversations: mutedForArrival, enqueueing: [])
        for account in mailbox.accounts {
            for n in 0..<100 {
                try store.setSenderRule(n % 2 == 0 ? .trash : .archive, for: "sender\(n)@rules.example", accountID: account.id,
                                        enqueueing: [], at: Date())
            }
        }
        let ruledMail = SyntheticMailbox(seed: 11 + UInt64(round), accountCount: 3, messageCount: Self.batchSize * 3).messages
        let arriving = ruledMail.enumerated().map { index, original in
            var message = original
            message.id = MessageID(accountID: original.id.accountID, providerID: "arrive\(round)-\(index)")
            message.roles = [.inbox]
            if index % 10 == 0, let conversation = mutedForArrival.first(where: { $0.accountID == original.id.accountID }) {
                message.conversationID = conversation
            } else {
                message.conversationID = ConversationID(accountID: original.id.accountID,
                                                        providerID: "arrive\(round)-" + original.conversationID.providerID)
            }
            if index % 10 == 5 { message.from = EmailAddress(address: "sender\(index % 100)@rules.example") }
            return message
        }
        let mixed = try Perf.milliseconds { try store.upsertMessages(Array(arriving.prefix(Self.batchSize))) }
        Perf.report("\(retention): insert \(Self.batchSize) new messages, a tenth muted and a tenth ruled", mixed)
        XCTAssertLessThan(mixed, 100, "upsert budget with arrival rules")

        let burst = arriving.dropFirst(Self.batchSize).prefix(Self.batchSize).enumerated().map { index, original in
            var message = original
            message.from = EmailAddress(address: "sender\(index % 100)@rules.example")
            return message
        }
        let everyOne = try Perf.milliseconds { try store.upsertMessages(burst) }
        Perf.report("\(retention): insert \(Self.batchSize) new messages, every one taken by a rule", everyOne)
        XCTAssertLessThan(everyOne, 100, "a burst of ruled mail keeps the upsert budget")
    }
}

/// What the sweep on another thread hands back to the test thread, read once it is done.
private final class SweepBox: @unchecked Sendable {
    var value: PerfMailbox.Sweep?
}
