import Foundation
import GRDB

/// SQL for the `messages` and `bodies` tables.
enum MessageTable {
    static let columns = """
        account_id, provider_id, conversation_provider_id, internet_message_id, in_reply_to, references_json, \
        subject, snippet, from_json, to_json, cc_json, bcc_json, reply_to_json, date_ms, roles, is_read, is_starred, \
        inbox_section, has_attachments, label_ids_json, folder_id, provider_version, size_bytes
        """

    // The upsert form keeps the rowid (which the FTS index and the bodies foreign key hang off) where
    // INSERT OR REPLACE would delete and re-insert the row.
    private static let upsertSQL = """
        INSERT INTO messages (\(columns), has_body)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
        ON CONFLICT(account_id, provider_id) DO UPDATE SET
            conversation_provider_id = excluded.conversation_provider_id,
            internet_message_id = excluded.internet_message_id,
            in_reply_to = excluded.in_reply_to,
            references_json = excluded.references_json,
            subject = excluded.subject,
            snippet = excluded.snippet,
            from_json = excluded.from_json,
            to_json = excluded.to_json,
            cc_json = excluded.cc_json,
            bcc_json = excluded.bcc_json,
            reply_to_json = excluded.reply_to_json,
            date_ms = excluded.date_ms,
            roles = excluded.roles,
            is_read = excluded.is_read,
            is_starred = excluded.is_starred,
            inbox_section = excluded.inbox_section,
            has_attachments = excluded.has_attachments,
            label_ids_json = excluded.label_ids_json,
            folder_id = excluded.folder_id,
            provider_version = excluded.provider_version,
            size_bytes = excluded.size_bytes
        """

    private static let lookupSQL = """
        SELECT rowid, conversation_provider_id, subject, from_json, to_json, cc_json
        FROM messages WHERE account_id = ? AND provider_id = ?
        """

    /// The columns the full-text index is derived from (besides the body), compared as the stored JSON so a
    /// poll that only flips flags skips the two index writes.
    struct IndexedFields: Equatable {
        var subject: String
        var fromJSON: String?
        var toJSON: String
        var ccJSON: String

        init(_ m: MessageMetadata) throws {
            subject = m.subject
            fromJSON = try m.from.map { try MailStoreCodec.json($0) }
            toJSON = try MailStoreCodec.json(m.to)
            ccJSON = try MailStoreCodec.json(m.cc)
        }

        init(row: Row) {
            subject = row[2]
            fromJSON = row[3]
            toJSON = row[4]
            ccJSON = row[5]
        }
    }

    // MARK: Upsert and delete

    static func upsert(_ messages: [MessageMetadata], in db: Database) throws {
        guard !messages.isEmpty else { return }
        try MailSchema.ensureTouchedTable(db)
        let lookup = try db.cachedStatement(sql: lookupSQL)
        let upsert = try db.cachedStatement(sql: upsertSQL)
        // Pending operations win over provider state, but looking them up per message only pays off when the
        // account has any live operation at all, which is rare between user actions.
        let accountsWithOperations = try OperationTable.accountsWithLiveOperations(db)
        for incoming in messages {
            var metadata = incoming
            if accountsWithOperations.contains(incoming.id.accountID.rawValue) {
                for change in try OperationTable.liveChanges(for: incoming.id, in: db) {
                    metadata = applying(change, to: metadata)
                }
            }
            let accountID = incoming.id.accountID.rawValue
            let indexed = try IndexedFields(metadata)
            let existing = try Row.fetchOne(lookup, arguments: [accountID, incoming.id.providerID])
            var reindex = true
            if let existing {
                let rowid: Int64 = existing[0]
                let previousConversation: String = existing[1]
                reindex = IndexedFields(row: existing) != indexed
                if reindex {
                    try FullTextIndex.remove(rowid: rowid, in: db)
                }
                if previousConversation != metadata.conversationID.providerID {
                    try ConversationTable.touch(accountID: incoming.id.accountID, providerID: previousConversation, in: db)
                }
            }
            try upsert.execute(arguments: try arguments(for: metadata, indexed: indexed))
            let rowid: Int64 = existing.map { $0[0] } ?? db.lastInsertedRowID
            if reindex {
                try FullTextIndex.insert(rowid: rowid, in: db)
            }
            try ConversationTable.touch(metadata.conversationID, in: db)
            if existing == nil {
                try ContactTable.record(metadata, in: db)
            }
        }
        try ConversationTable.refreshTouched(db)
    }

    static func delete(_ ids: [MessageID], in db: Database) throws {
        guard !ids.isEmpty else { return }
        try MailSchema.ensureTouchedTable(db)
        let lookup = try db.cachedStatement(sql: lookupSQL)
        let delete = try db.cachedStatement(sql: "DELETE FROM messages WHERE rowid = ?")
        for id in ids {
            guard let row = try Row.fetchOne(lookup, arguments: [id.accountID.rawValue, id.providerID]) else { continue }
            let rowid: Int64 = row[0]
            let conversation: String = row[1]
            try FullTextIndex.remove(rowid: rowid, in: db)
            try ConversationTable.touch(accountID: id.accountID, providerID: conversation, in: db)
            try delete.execute(arguments: [rowid])
        }
        try ConversationTable.refreshTouched(db)
    }

    /// Writes only the fields `applying(_:to:)` can change, for local operations.
    static func updateFlags(_ metadata: MessageMetadata, in db: Database) throws {
        try db.cachedStatement(sql: """
            UPDATE messages SET roles = ?, is_read = ?, is_starred = ? WHERE account_id = ? AND provider_id = ?
            """).execute(arguments: [
                MailStoreCodec.roleBits(metadata.roles), metadata.isRead, metadata.isStarred,
                metadata.id.accountID.rawValue, metadata.id.providerID,
            ])
    }

    // MARK: Reads

    static func fetch(_ id: MessageID, in db: Database) throws -> MessageMetadata? {
        let statement = try db.cachedStatement(sql: "SELECT \(columns) FROM messages WHERE account_id = ? AND provider_id = ?")
        return try Row.fetchOne(statement, arguments: [id.accountID.rawValue, id.providerID]).map(metadata(from:))
    }

    static func fetch(in conversation: ConversationID, db: Database) throws -> [MessageMetadata] {
        let statement = try db.cachedStatement(sql: """
            SELECT \(columns) FROM messages WHERE account_id = ? AND conversation_provider_id = ?
            ORDER BY date_ms, provider_id
            """)
        return try Row.fetchAll(statement, arguments: [conversation.accountID.rawValue, conversation.providerID])
            .map(metadata(from:))
    }

    /// Inbox first, newest first, so hydration follows what the user will open. Two indexed scans that each stop
    /// at the limit beat one query that has to sort every body-less message of a fresh account.
    static func missingBodies(accountID: AccountID, limit: Int, in db: Database) throws -> [MessageID] {
        guard limit > 0 else { return [] }
        let inInbox = "(roles & \(MailStoreCodec.inboxBit)) != 0 AND (roles & \(MailStoreCodec.trashBit)) = 0"
        let notSpam = "(roles & \(MailStoreCodec.spamBit)) = 0"
        var ids = try String.fetchAll(db, sql: """
            SELECT provider_id FROM messages
            WHERE account_id = ? AND has_body = 0 AND \(notSpam) AND \(inInbox)
            ORDER BY date_ms DESC LIMIT ?
            """, arguments: [accountID.rawValue, limit])
        if ids.count < limit {
            ids += try String.fetchAll(db, sql: """
                SELECT provider_id FROM messages
                WHERE account_id = ? AND has_body = 0 AND \(notSpam) AND NOT (\(inInbox))
                ORDER BY date_ms DESC LIMIT ?
                """, arguments: [accountID.rawValue, limit - ids.count])
        }
        return ids.map { MessageID(accountID: accountID, providerID: $0) }
    }

    // MARK: Bodies

    /// Returns false when the message is unknown, which happens when a poll deleted it while its body was in flight.
    static func saveBody(_ body: StoredBody, for id: MessageID, in db: Database) throws -> Bool {
        guard let rowid = try Int64.fetchOne(
            db,
            sql: "SELECT rowid FROM messages WHERE account_id = ? AND provider_id = ?",
            arguments: [id.accountID.rawValue, id.providerID]
        ) else { return false }
        try FullTextIndex.remove(rowid: rowid, in: db)
        try db.cachedStatement(sql: """
            INSERT INTO bodies (account_id, provider_id, html, text, rendered_html, plain_text, attachments_json,
                                has_quoted, blocked_images, typesetting, declares_colors, covered_by_new_york)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, provider_id) DO UPDATE SET
                html = excluded.html, text = excluded.text, rendered_html = excluded.rendered_html,
                plain_text = excluded.plain_text, attachments_json = excluded.attachments_json,
                has_quoted = excluded.has_quoted, blocked_images = excluded.blocked_images,
                typesetting = excluded.typesetting, declares_colors = excluded.declares_colors,
                covered_by_new_york = excluded.covered_by_new_york
            """).execute(arguments: [
                id.accountID.rawValue, id.providerID,
                try body.body.html.map(MailStoreCodec.compress),
                try body.body.text.map(MailStoreCodec.compress),
                try MailStoreCodec.compress(body.renderedHTML),
                body.plainText,
                try MailStoreCodec.json(body.body.attachments),
                body.hasQuotedContent,
                body.blockedRemoteImageCount,
                body.typesetting.map(MailStoreCodec.typesettingCode),
                body.declaresColors,
                body.coveredByNewYork,
            ])
        try db.cachedStatement(sql: "UPDATE messages SET has_body = 1 WHERE rowid = ?").execute(arguments: [rowid])
        try FullTextIndex.insert(rowid: rowid, in: db)
        return true
    }

    static func body(for id: MessageID, in db: Database) throws -> StoredBody? {
        let statement = try db.cachedStatement(sql: """
            SELECT html, text, rendered_html, plain_text, attachments_json, has_quoted, blocked_images,
                   typesetting, declares_colors, covered_by_new_york FROM bodies
            WHERE account_id = ? AND provider_id = ?
            """)
        guard let row = try Row.fetchOne(statement, arguments: [id.accountID.rawValue, id.providerID]) else { return nil }
        let html: Data? = row[0]
        let text: Data? = row[1]
        let rendered: Data = row[2]
        let attachmentsJSON: String = row[4]
        return StoredBody(
            body: MessageBody(
                html: try html.map(MailStoreCodec.decompress),
                text: try text.map(MailStoreCodec.decompress),
                attachments: try MailStoreCodec.decode([AttachmentInfo].self, from: attachmentsJSON)
            ),
            renderedHTML: try MailStoreCodec.decompress(rendered),
            plainText: row[3],
            hasQuotedContent: row[5],
            blockedRemoteImageCount: row[6],
            typesetting: MailStoreCodec.typesetting(row[7]),
            declaresColors: row[8],
            coveredByNewYork: row[9]
        )
    }

    // MARK: Row mapping

    static func arguments(for m: MessageMetadata, indexed: IndexedFields) throws -> StatementArguments {
        [
            m.id.accountID.rawValue,
            m.id.providerID,
            m.conversationID.providerID,
            m.internetMessageID,
            m.inReplyTo,
            try MailStoreCodec.json(m.references),
            indexed.subject,
            m.snippet,
            indexed.fromJSON,
            indexed.toJSON,
            indexed.ccJSON,
            try MailStoreCodec.json(m.bcc),
            try MailStoreCodec.json(m.replyTo),
            MailStoreCodec.milliseconds(m.date),
            MailStoreCodec.roleBits(m.roles),
            m.isRead,
            m.isStarred,
            m.inboxSection.rawValue,
            m.hasAttachments,
            try MailStoreCodec.json(m.labelIDs),
            m.folderID,
            m.providerVersion,
            m.sizeBytes,
        ]
    }

    /// Expects the column order of `columns`.
    static func metadata(from row: Row) throws -> MessageMetadata {
        let accountID = AccountID(row[0])
        let fromJSON: String? = row[8]
        return MessageMetadata(
            id: MessageID(accountID: accountID, providerID: row[1]),
            conversationID: ConversationID(accountID: accountID, providerID: row[2]),
            internetMessageID: row[3],
            inReplyTo: row[4],
            references: try MailStoreCodec.decode([String].self, from: row[5]),
            subject: row[6],
            snippet: row[7],
            from: try fromJSON.map { try MailStoreCodec.decode(EmailAddress.self, from: $0) },
            to: try MailStoreCodec.decode([EmailAddress].self, from: row[9]),
            cc: try MailStoreCodec.decode([EmailAddress].self, from: row[10]),
            bcc: try MailStoreCodec.decode([EmailAddress].self, from: row[11]),
            replyTo: try MailStoreCodec.decode([EmailAddress].self, from: row[12]),
            date: MailStoreCodec.date(row[13]),
            roles: MailStoreCodec.roles(row[14]),
            isRead: row[15],
            isStarred: row[16],
            inboxSection: InboxSection(rawValue: row[17]) ?? .unknown,
            hasAttachments: row[18],
            labelIDs: try MailStoreCodec.decode([String].self, from: row[19]),
            folderID: row[20],
            providerVersion: row[21],
            sizeBytes: row[22]
        )
    }
}
