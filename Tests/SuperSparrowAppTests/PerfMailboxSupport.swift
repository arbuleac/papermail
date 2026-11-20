import Foundation
import SQLite3
import SSCore

/// The mailbox the app's `SS_PERF=1` benchmarks measure the budgets of docs/ARCHITECTURE.md on: `ListTestSupport`'s two
/// accounts, two threads of one to three messages an hour back from now, 300,000 messages since roadmap Q4.3, every
/// message with a stored body as a finished backfill leaves them.
///
/// - `SS_PERF_MESSAGES` sets another size (`SS_LIST_PERF_MESSAGES`, the older name, still does).
/// - `SS_PERF_RETENTION=1year` measures with Keep mail on this Mac at 1 year: the bodies of mail older than a year are
///   evicted by a sweep, as the launch sweep leaves them. Everything (no eviction) by default.
/// - `SS_PERF_CACHE=1` keeps the built file in the temporary directory and copies it for each run, so a second run of
///   any benchmark skips the minute a 300,000-message mailbox takes to build. Delete
///   `$TMPDIR/SuperSparrowPerfMailbox` after changing how the store writes rows without a migration.
@MainActor
enum PerfMailboxSupport {
    static let defaultMessageCount = 300_000
    /// Bump when the mailbox's content changes, so a cached file from before is built again.
    private static let fixtureVersion = 2

    static var messageCount: Int {
        let environment = ProcessInfo.processInfo.environment
        return Int(environment["SS_PERF_MESSAGES"] ?? environment["SS_LIST_PERF_MESSAGES"] ?? "") ?? defaultMessageCount
    }

    static var retention: MailRetention {
        ProcessInfo.processInfo.environment["SS_PERF_RETENTION"] == "1year" ? .oneYear : .everything
    }

    static var label: String {
        "\(messageCount) messages, Keep mail \(retention == .oneYear ? "1 year" : "Everything")"
    }

    /// Writes the mailbox to `path` (a file that must not exist yet), from the cache when `SS_PERF_CACHE=1` holds one.
    static func install(at path: String) throws {
        let fileManager = FileManager.default
        let useCache = ProcessInfo.processInfo.environment["SS_PERF_CACHE"] == "1"
        guard useCache else {
            try build(at: path)
            return
        }
        let folder = fileManager.temporaryDirectory.appendingPathComponent("SuperSparrowPerfMailbox", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let name = "list-v\(fixtureVersion)-\(messageCount)-\(retention.rawValue).sqlite"
        let cached = folder.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: cached.path) {
            let building = folder.appendingPathComponent("building-\(UUID().uuidString).sqlite")
            try build(at: building.path)
            try fileManager.moveItem(at: building, to: cached)
            print("SS_PERF mailbox: kept at \(cached.path)")
        }
        // APFS clones the file, so the copy is instant and the cached file stays as built.
        try fileManager.copyItem(at: cached, to: URL(fileURLWithPath: path))
    }

    /// Builds the mailbox as the sync engine leaves it: metadata pages, then every body, then, at 1 year, the sweep.
    /// The file is checkpointed and closed, a single file with no WAL beside it.
    private static func build(at path: String) throws {
        let started = Date()
        let store = try SQLiteMailStore(path: path)
        try store.upsertAccount(ListTestSupport.accountA)
        try store.upsertAccount(ListTestSupport.accountB)
        let messages = ListTestSupport.messages(threads: messageCount / 2, now: Date(), spacing: 1_800)
        var index = 0
        while index < messages.count {
            let page = messages[index..<min(index + 2_000, messages.count)]
            try store.upsertMessages(Array(page))
            try store.saveBodies(page.map { (id: $0.id, body: body(for: $0)) })
            index += page.count
        }
        if let cutoff = retention.cutoff(now: Date()) {
            var start: Date?
            var evicted = 0
            while true {
                // 200 a batch, as the sweeper takes them (`SyncTuning.evictionBatchSize`).
                let batch = try store.evictBodies(from: start, limit: 200) { (cutoff, []) }
                evicted += batch.evicted
                guard let next = batch.next, batch.evicted > 0 || next != start else { break }
                start = next
            }
            print("SS_PERF mailbox: \(evicted) bodies evicted outside a year")
        }
        try store.close()
        try checkpointAndClear(path)
        print("SS_PERF mailbox: \(label) built in \(String(format: "%.0f", Date().timeIntervalSince(started))) s")
    }

    /// Copies whatever the WAL still holds into the file and removes the WAL and shared-memory files, so the file alone
    /// is the whole mailbox: macOS's SQLite can keep a WAL file after the last connection closes, and the cache moves and
    /// copies the database file alone.
    private static func checkpointAndClear(_ path: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CocoaError(.fileReadUnknown)
        }
        let checkpointed = sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_TRUNCATE, nil, nil) == SQLITE_OK
        sqlite3_close(db)
        guard checkpointed else { throw CocoaError(.fileWriteUnknown) }
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) }
    }

    /// A short body of two paragraphs, render-ready, that names the message, as a reply in a thread reads.
    static func body(for message: MessageMetadata) -> StoredBody {
        let text = "Just following up on the thread from last week (\(message.id.providerID)). "
            + "Let me know if Tuesday works for the review; the planning document is attached, with the numbers from the quarter."
        let html = "<p>Just following up on the thread from last week.</p><p>Let me know if Tuesday works for the review; "
            + "the planning document is attached, with the numbers from the quarter.</p>"
        // With the design facts the sanitizer works out at sync time for plain mail, as every stored body has them:
        // without, the reader would take each for styled HTML that may declare its colours.
        return StoredBody(body: MessageBody(html: html, text: text), renderedHTML: html, plainText: text, hasQuotedContent: false,
                          blockedRemoteImageCount: 0, typesetting: .unstyled, declaresColors: false, coveredByNewYork: true)
    }
}
