import Foundation
import GRDB

/// The on-disk schema from docs/DATA-MODEL.md, applied through `DatabaseMigrator` so later versions can evolve it.
enum MailSchema {
    /// Name of the per-connection scratch table that collects conversations whose summary row must be recomputed.
    static let touchedTable = "touched_conversations"

    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-mailbox") { db in
            try db.execute(sql: v1)
        }
        migrator.registerMigration("v2-body-render-facts") { db in
            // Nullable: bodies stored before have none, and the renderer derives them from the HTML.
            try db.execute(sql: """
                ALTER TABLE bodies ADD COLUMN has_quoted INTEGER;
                ALTER TABLE bodies ADD COLUMN blocked_images INTEGER;
                """)
        }
        migrator.registerMigration("v3-body-typesetting") { db in
            // Nullable: these cannot be derived without parsing the stored HTML, which opening a message must
            // never do, so earlier bodies stay NULL and render as styled until they are fetched again.
            try db.execute(sql: """
                ALTER TABLE bodies ADD COLUMN typesetting INTEGER;
                ALTER TABLE bodies ADD COLUMN declares_colors INTEGER;
                ALTER TABLE bodies ADD COLUMN covered_by_new_york INTEGER;
                """)
        }
        migrator.registerMigration("v4-account-ink") { db in
            // Existing accounts take slots in creation order. Handing out the lowest unused slot to each in
            // turn, starting from none taken, is the creation index modulo the palette size, so the backfill
            // is that number; it is spelled out here rather than calling AccountInkSlot so a later change to
            // the engine's rule cannot change what this migration did.
            try db.execute(sql: """
                ALTER TABLE accounts ADD COLUMN ink_slot INTEGER NOT NULL DEFAULT 0;
                ALTER TABLE accounts ADD COLUMN monogram TEXT;
                UPDATE accounts SET ink_slot = (
                    SELECT COUNT(*) FROM accounts earlier
                    WHERE earlier.added_at < accounts.added_at
                       OR (earlier.added_at = accounts.added_at AND earlier.id < accounts.id)
                ) % 10;
                """)
        }
        migrator.registerMigration("v5-failed-operation-mark") { db in
            try db.execute(sql: "ALTER TABLE conversations ADD COLUMN failed_op_kind TEXT")
        }
        return migrator
    }

    /// Scratch table for the summary refresh. It lives in the temp schema so it never reaches the file and never
    /// shows up in observations; it is created lazily on the writer connection.
    static func ensureTouchedTable(_ db: Database) throws {
        try db.execute(sql: """
            CREATE TEMP TABLE IF NOT EXISTS \(touchedTable) (
                account_id TEXT NOT NULL,
                provider_id TEXT NOT NULL,
                PRIMARY KEY (account_id, provider_id)
            ) WITHOUT ROWID
            """)
    }

    // Plain DDL rather than GRDB's table builder: the document is the contract and reading the two side by side
    // should need no translation. Internal so the migration tests can build a v1 file without the migrator.
    static let v1 = """
    CREATE TABLE accounts (
        id TEXT PRIMARY KEY NOT NULL,
        kind TEXT NOT NULL,
        email TEXT NOT NULL,
        display_name TEXT NOT NULL,
        color_hex TEXT NOT NULL,
        added_at INTEGER NOT NULL,
        sync_cursor TEXT,
        bootstrap_json TEXT
    );

    CREATE TABLE messages (
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        provider_id TEXT NOT NULL,
        conversation_provider_id TEXT NOT NULL,
        internet_message_id TEXT,
        in_reply_to TEXT,
        references_json TEXT NOT NULL,
        subject TEXT NOT NULL,
        snippet TEXT NOT NULL,
        from_json TEXT,
        to_json TEXT NOT NULL,
        cc_json TEXT NOT NULL,
        bcc_json TEXT NOT NULL,
        reply_to_json TEXT NOT NULL,
        date_ms INTEGER NOT NULL,
        roles INTEGER NOT NULL,
        is_read INTEGER NOT NULL,
        is_starred INTEGER NOT NULL,
        inbox_section TEXT NOT NULL,
        has_attachments INTEGER NOT NULL,
        label_ids_json TEXT NOT NULL,
        folder_id TEXT,
        provider_version TEXT,
        size_bytes INTEGER,
        has_body INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (account_id, provider_id)
    );
    CREATE INDEX messages_by_conversation ON messages(account_id, conversation_provider_id);
    CREATE INDEX messages_hydration_order ON messages(account_id, has_body, date_ms DESC);
    CREATE INDEX messages_by_date ON messages(date_ms DESC);

    CREATE TABLE bodies (
        account_id TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        html BLOB,
        text BLOB,
        rendered_html BLOB NOT NULL,
        plain_text TEXT NOT NULL,
        attachments_json TEXT NOT NULL,
        PRIMARY KEY (account_id, provider_id),
        FOREIGN KEY (account_id, provider_id) REFERENCES messages(account_id, provider_id) ON DELETE CASCADE
    );

    CREATE TABLE conversations (
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        provider_id TEXT NOT NULL,
        subject TEXT NOT NULL,
        snippet TEXT NOT NULL,
        participants_json TEXT NOT NULL,
        latest_date_ms INTEGER NOT NULL,
        latest_provider_id TEXT NOT NULL,
        message_count INTEGER NOT NULL,
        unread_count INTEGER NOT NULL,
        is_starred INTEGER NOT NULL,
        has_attachments INTEGER NOT NULL,
        in_inbox INTEGER NOT NULL,
        in_sent INTEGER NOT NULL,
        in_drafts INTEGER NOT NULL,
        in_trash INTEGER NOT NULL,
        inbox_section TEXT NOT NULL,
        has_pending_ops INTEGER NOT NULL,
        PRIMARY KEY (account_id, provider_id)
    );
    CREATE INDEX conversations_inbox ON conversations(in_inbox, latest_date_ms DESC);
    CREATE INDEX conversations_starred ON conversations(is_starred, latest_date_ms DESC);
    CREATE INDEX conversations_sent ON conversations(in_sent, latest_date_ms DESC);
    CREATE INDEX conversations_latest ON conversations(latest_date_ms DESC);
    CREATE INDEX conversations_by_account ON conversations(account_id, latest_date_ms DESC);

    -- Recipients are flattened with a recursive CTE rather than json_each because FTS5 prepares its own reads
    -- of the content table with virtual tables disallowed, and json_each is one; with it in the view, rebuild,
    -- the strict integrity check and column reads from message_fts all fail with "SQL logic error".
    CREATE VIEW message_fts_content AS
    SELECT m.rowid AS id,
           m.account_id AS account_id,
           m.provider_id AS provider_id,
           m.subject AS subject,
           trim(COALESCE(json_extract(m.from_json, '$.name'), '') || ' '
                || COALESCE(json_extract(m.from_json, '$.address'), '') || ' '
                || COALESCE((WITH RECURSIVE i(n) AS (
                                 SELECT 0 WHERE json_array_length(m.to_json) > 0
                                 UNION ALL SELECT n + 1 FROM i WHERE n + 1 < json_array_length(m.to_json))
                             SELECT group_concat(COALESCE(json_extract(m.to_json, '$[' || n || '].name'), '') || ' '
                                                 || COALESCE(json_extract(m.to_json, '$[' || n || '].address'), ''), ' ')
                             FROM i), '') || ' '
                || COALESCE((WITH RECURSIVE i(n) AS (
                                 SELECT 0 WHERE json_array_length(m.cc_json) > 0
                                 UNION ALL SELECT n + 1 FROM i WHERE n + 1 < json_array_length(m.cc_json))
                             SELECT group_concat(COALESCE(json_extract(m.cc_json, '$[' || n || '].name'), '') || ' '
                                                 || COALESCE(json_extract(m.cc_json, '$[' || n || '].address'), ''), ' ')
                             FROM i), '')) AS participants,
           COALESCE(b.plain_text, '') AS body
    FROM messages m
    LEFT JOIN bodies b ON b.account_id = m.account_id AND b.provider_id = m.provider_id;

    CREATE VIRTUAL TABLE message_fts USING fts5(
        subject, participants, body,
        content='message_fts_content', content_rowid='id',
        tokenize='unicode61 remove_diacritics 2'
    );

    CREATE TABLE operations (
        id TEXT PRIMARY KEY NOT NULL,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        change_json TEXT NOT NULL,
        targets_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        status TEXT NOT NULL,
        attempts INTEGER NOT NULL,
        last_error TEXT,
        next_attempt_at INTEGER
    );
    CREATE INDEX operations_by_account_status ON operations(account_id, status, created_at);

    CREATE TABLE operation_targets (
        operation_id TEXT NOT NULL REFERENCES operations(id) ON DELETE CASCADE,
        account_id TEXT NOT NULL,
        provider_id TEXT NOT NULL,
        PRIMARY KEY (operation_id, account_id, provider_id)
    ) WITHOUT ROWID;
    CREATE INDEX operation_targets_by_message ON operation_targets(account_id, provider_id);

    CREATE TABLE pending_sends (
        id TEXT PRIMARY KEY NOT NULL,
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        message_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        send_after INTEGER NOT NULL,
        status TEXT NOT NULL,
        attempts INTEGER NOT NULL,
        last_error TEXT
    );

    CREATE TABLE contacts (
        account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
        address TEXT NOT NULL,
        name TEXT,
        seen_count INTEGER NOT NULL,
        last_seen_ms INTEGER NOT NULL,
        PRIMARY KEY (account_id, address)
    ) WITHOUT ROWID;
    """
}
