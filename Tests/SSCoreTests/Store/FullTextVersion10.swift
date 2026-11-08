import Foundation
@testable import SSCore

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

    /// Turns a migrated file's index back into v11's, rebuilt from the stored rows, and forgets that v12 ran, so the
    /// next open migrates it again.
    static var revertSQL: String {
        """
        DROP TABLE message_fts;
        DROP VIEW message_fts_content;
        \(ddl)
        INSERT INTO message_fts(message_fts) VALUES ('rebuild');
        DELETE FROM grdb_migrations WHERE identifier = 'v12-search-columns';
        """
    }
}
