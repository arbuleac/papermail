import Foundation
@testable import PaperCore

/// The full-text index as v1 created it and v10 and v11 still had it (one `participants` column: the sender, To and
/// Cc), for tests that need a file from before v12.
enum FullTextVersion10 {
    /// The view and the table, exactly as `MailSchema.v1` creates them.
    static var ddl: String {
        let v1 = MailSchema.v1
        let start = v1.range(of: "CREATE VIEW message_fts_content")!.lowerBound
        let table = v1.range(of: "CREATE VIRTUAL TABLE message_fts", range: start..<v1.endIndex)!.upperBound
        let end = v1.range(of: ");", range: table..<v1.endIndex)!.upperBound
        return String(v1[start..<end])
    }

    /// Turns a migrated file's index back into v11's, rebuilt from the stored rows, and forgets that v12 and v13 ran,
    /// so the next open migrates it again. The index is renamed aside before the view is dropped: since v13 the view
    /// follows the index in the schema, so SQLite reads its name as one of the index's shadow tables and, in the
    /// defensive mode the system's SQLite opens with, refuses to drop it (`MailSchema.v13`).
    static var revertSQL: String {
        """
        ALTER TABLE message_fts RENAME TO reverted_message_fts;
        DROP VIEW message_fts_content;
        DROP TABLE reverted_message_fts;
        \(ddl)
        INSERT INTO message_fts(message_fts) VALUES ('rebuild');
        DELETE FROM grdb_migrations WHERE identifier = 'v12-search-columns';
        DELETE FROM grdb_migrations WHERE identifier = 'v13-server-search';
        """
    }
}
