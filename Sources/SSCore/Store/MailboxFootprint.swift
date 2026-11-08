import Foundation
import SQLite3

/// The space the mailbox takes, as Settings › General shows it beside Keep mail on this Mac (spec §5.40): the database
/// file with its WAL and shared-memory files, less the pages SQLite keeps free inside the file for reuse, plus everything
/// under the attachment cache. Space allocated on disk, as Finder's "on disk" counts it. Reads the file system and the
/// database, so callers run it off the main thread.
///
/// The free pages are left out because a file created before incremental vacuum (every store from before v10) can never
/// give space back to the file system without a full VACUUM, which the app never runs (docs/DATA-MODEL.md, "The file"):
/// after a clean-up such a file keeps its size and reuses the freed pages. Counting them would show a number that never
/// goes down when the user chooses a shorter window; leaving them out shows what the mail now takes.
public enum MailboxFootprint {
    public static func bytes(databasePath: String, attachmentDirectory: URL) -> Int64 {
        var total: Int64 = 0
        for suffix in ["", "-wal", "-shm"] {
            total += size(of: URL(fileURLWithPath: databasePath + suffix))
        }
        total = max(0, total - freeBytes(databasePath: databasePath))
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
        if let walker = FileManager.default.enumerator(at: attachmentDirectory, includingPropertiesForKeys: keys) {
            for case let url as URL in walker {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
                total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
        }
        return total
    }

    /// The bytes of the database's free pages (`freelist_count` × `page_size`), read through a read-only connection of
    /// its own so the measurement never waits on the store's writer. Zero when the file is missing or unreadable.
    static func freeBytes(databasePath: String) -> Int64 {
        guard FileManager.default.fileExists(atPath: databasePath) else { return 0 }
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(databasePath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else { return 0 }
        sqlite3_busy_timeout(db, 250)
        return pragma("freelist_count", in: db) * pragma("page_size", in: db)
    }

    private static func pragma(_ name: String, in db: OpaquePointer?) -> Int64 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "PRAGMA \(name)", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int64(statement, 0)
    }

    private static func size(of url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
    }
}
