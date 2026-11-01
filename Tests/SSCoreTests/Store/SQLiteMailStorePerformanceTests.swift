import XCTest
import SSCore

/// The store half of the budgets in docs/ARCHITECTURE.md, measured on a 100,000-message synthetic mailbox in a
/// real file. It takes a while to load, so it only runs with `SS_PERF=1` in the environment:
///
///     SS_PERF=1 swift test --filter SQLiteMailStorePerformanceTests
final class SQLiteMailStorePerformanceTests: XCTestCase {
    private static let messageCount = 100_000
    private static let batchSize = 200

    func testHundredThousandMessageMailboxStaysWithinBudget() throws {
        guard ProcessInfo.processInfo.environment["SS_PERF"] == "1" else {
            throw XCTSkip("set SS_PERF=1 to run the 100k-message benchmark")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SQLiteMailStorePerformanceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)

        let mailbox = SyntheticMailbox(seed: 7, accountCount: 3, messageCount: Self.messageCount)
        for account in mailbox.accounts {
            try store.upsertAccount(account)
        }

        // Load the way the sync engine does: metadata pages first, then bodies in hydration batches.
        var slowestBatch = 0.0
        let load = try measure {
            for batch in mailbox.batches(of: Self.batchSize) {
                let elapsed = try measure { try store.upsertMessages(batch) }
                slowestBatch = max(slowestBatch, elapsed)
            }
        }
        report("load \(Self.messageCount) messages in \(Self.batchSize)-message batches", load)
        report("slowest load batch", slowestBatch)

        let hydrate = try measure {
            for batch in mailbox.batches(of: Self.batchSize) {
                try store.saveBodies(batch.map { (id: $0.id, body: mailbox.body(for: $0)) })
            }
        }
        report("hydrate \(Self.messageCount) bodies", hydrate)

        let inboxCount = try store.conversations(ConversationQuery(view: .inbox, limit: .max)).count
        let allCount = try store.conversations(ConversationQuery(view: .all, limit: .max)).count
        print("SS_PERF conversations: \(allCount) total, \(inboxCount) in the inbox")

        // Reads: median of several runs after one warm-up, since a list refresh is never the first read.
        let inbox = try median(runs: 7) { try store.conversations(ConversationQuery(view: .inbox)) }
        report("unified inbox, 200 rows", inbox.milliseconds)
        XCTAssertFalse(inbox.value.isEmpty)
        XCTAssertLessThan(inbox.milliseconds, 50, "inbox query budget")

        let focusedUnread = try median(runs: 7) {
            try store.conversations(ConversationQuery(accountIDs: [mailbox.accounts[0].id], view: .inbox, section: .focused, unreadOnly: true))
        }
        report("one account, focused, unread only", focusedUnread.milliseconds)
        XCTAssertLessThan(focusedUnread.milliseconds, 50, "filtered inbox budget")

        let unread = try median(runs: 7) { try store.unreadInboxCount(accountIDs: nil) }
        report("unread inbox count (\(unread.value))", unread.milliseconds)

        // Search as the user types a name, a subject phrase and a body word; the last token is a prefix.
        for text in ["nakam", "quarterly bud", "spreadsheet"] {
            let search = try median(runs: 5) { try store.conversations(ConversationQuery(view: .all, searchText: text)) }
            report("search \"\(text)\" (\(search.value.count) rows)", search.milliseconds)
            XCTAssertFalse(search.value.isEmpty, text)
            XCTAssertLessThan(search.milliseconds, 50, "search budget for \"\(text)\"")
        }

        // Writes: a poll re-upserting a page of known messages, and a page of brand-new ones.
        let known = Array(mailbox.messages.prefix(Self.batchSize))
        let reupsert = try median(runs: 5) { try store.upsertMessages(known) }
        report("re-upsert \(Self.batchSize) known messages", reupsert.milliseconds)
        XCTAssertLessThan(reupsert.milliseconds, 100, "upsert budget")

        let fresh = SyntheticMailbox(seed: 99, accountCount: 3, messageCount: Self.batchSize * 5).messages.map { original in
            var message = original
            message.id = MessageID(accountID: original.id.accountID, providerID: "new-" + original.id.providerID)
            message.conversationID = ConversationID(accountID: original.id.accountID, providerID: "new-" + original.conversationID.providerID)
            return message
        }
        var insertTimings: [Double] = []
        for batch in stride(from: 0, to: fresh.count, by: Self.batchSize).map({ Array(fresh[$0..<$0 + Self.batchSize]) }) {
            insertTimings.append(try measure { try store.upsertMessages(batch) })
        }
        let insert = insertTimings.sorted()[insertTimings.count / 2]
        report("insert \(Self.batchSize) new messages", insert)
        XCTAssertLessThan(insert, 100, "upsert budget")

        let archive = try measure {
            try store.enqueue(Operation(accountID: known[0].id.accountID, change: .archive, targets: known.prefix(8).map(\.id)))
        }
        report("archive an 8-message conversation", archive)
        XCTAssertLessThan(archive, 16, "local action budget")

        let hydration = try median(runs: 5) { try store.messageIDsMissingBodies(accountID: mailbox.accounts[0].id, limit: 50) }
        report("next 50 bodies to hydrate", hydration.milliseconds)
    }

    // MARK: Timing

    private func measure(_ work: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now()
        try work()
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private func median<T>(runs: Int, _ work: () throws -> T) throws -> (value: T, milliseconds: Double) {
        var last = try work()
        var timings: [Double] = []
        for _ in 0..<runs {
            timings.append(try measure { last = try work() })
        }
        return (last, timings.sorted()[runs / 2])
    }

    private func report(_ label: String, _ milliseconds: Double) {
        print("SS_PERF \(label): \(String(format: "%.1f", milliseconds)) ms")
    }
}
