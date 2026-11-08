import SQLite3
import XCTest
@testable import SSCore

/// The search keystroke budget (50 ms, docs/ARCHITECTURE.md) with every search operator, on the 100,000-message
/// synthetic mailbox in a real file, and how long the v12 migration takes to rebuild that mailbox's index. Loading
/// the mailbox takes a while, so it only runs with `SS_PERF=1`:
///
///     SS_PERF=1 swift test --filter SearchOperatorPerformanceTests
final class SearchOperatorPerformanceTests: XCTestCase {
    private static let messageCount = 100_000

    func testEveryOperatorStaysWithinTheKeystrokeBudget() throws {
        guard ProcessInfo.processInfo.environment["SS_PERF"] == "1" else {
            throw XCTSkip("set SS_PERF=1 to run the 100k-message search benchmark")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SearchOperatorPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("mail.sqlite").path
        var store = try SQLiteMailStore(path: path)

        let mailbox = SyntheticMailbox(seed: 7, accountCount: 3, messageCount: Self.messageCount)
        for account in mailbox.accounts { try store.upsertAccount(account) }
        for batch in mailbox.batches(of: 200) {
            try store.upsertMessages(batch)
            try store.saveBodies(batch.map { (id: $0.id, body: mailbox.body(for: $0)) })
        }

        // Every operator alone, as the user finishes typing it, then all of them at once. The fixture's mail spans
        // the two years before 2026-01-01.
        let queries = [
            "from:nakamura", "from:nakam", "to:nakamura", "to:owner", "subject:budget", "subject:\"budget review\"",
            "\"quarterly budget\"", "has:attachment", "is:unread", "is:read", "is:starred", "before:2024-06-01",
            "after:2025-06-01", "in:sent", "in:trash", "in:inbox", "in:drafts", "-invoice", "budget -spreadsheet",
            "-from:nakamura", "-the", "-is:unread", "-has:attachment",
            "from:nakamura to:owner subject:review has:attachment is:unread after:2024-06-01 before:2026-01-01 in:inbox -invoice \"budget review\"",
        ]
        // Through ShellQuery, as the field asks: an `in:` term picks the view searched.
        func query(_ text: String) -> ConversationQuery { ShellQuery.make(scope: nil, view: .inbox, searchText: text) }
        for text in queries {
            let search = try median(runs: 5) { try store.conversations(query(text)) }
            report("search \(text) (\(search.value.count) rows)", search.milliseconds)
            XCTAssertLessThan(search.milliseconds, 50, "search budget for \(text)")
        }
        // A negated word nearly every message holds takes almost everything out, so its set is as large as it gets.
        // One letter, before any operator: a prefix every word starting with it matches, so the largest merge FTS5 does.
        for text in ["t", "from:n"] {
            let search = try median(runs: 5) { try store.conversations(query(text)) }
            report("search \(text), a one-letter prefix (\(search.value.count) rows)", search.milliseconds)
        }

        // The migration on this mailbox: the index put back as v11 had it, then the file opened by this build.
        try store.close()
        try execute(FullTextVersion10.revertSQL, at: path)
        let start = DispatchTime.now()
        store = try SQLiteMailStore(path: path)
        report("v12 migration, index rebuilt for \(Self.messageCount) messages",
               Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
        XCTAssertFalse(try store.conversations(ConversationQuery(view: .all, searchText: "from:nakamura")).isEmpty)
        try store.close()
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

    private func execute(_ sql: String, at path: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
            sqlite3_close(handle)
            throw XCTSkip("could not open the SQLite file")
        }
        defer { sqlite3_close(db) }
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            XCTFail("SQL failed: \(text)")
            throw CancellationError()
        }
    }
}
