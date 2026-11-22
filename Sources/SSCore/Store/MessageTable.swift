import Foundation
import GRDB

/// SQL for the `messages` and `bodies` tables.
enum MessageTable {
    static let columns = """
        account_id, provider_id, conversation_provider_id, internet_message_id, in_reply_to, references_json, \
        subject, snippet, from_json, to_json, cc_json, bcc_json, reply_to_json, date_ms, roles, is_read, is_starred, \
        inbox_section, has_attachments, label_ids_json, folder_id, provider_version, size_bytes, \
        list_unsubscribe, list_unsubscribe_post
        """

    /// What a read selects: the provider's columns, then the local answer to an invitation (v15), which the upsert
    /// never writes, so a provider report cannot undo it.
    static let selectColumns = columns + ", invitation_reply"

    // The upsert form keeps the rowid (which the FTS index and the bodies foreign key hang off) where
    // INSERT OR REPLACE would delete and re-insert the row.
    private static let upsertSQL = """
        INSERT INTO messages (\(columns), has_body)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
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
            size_bytes = excluded.size_bytes,
            -- Headers never change, and a path that cannot carry them (a Graph listing) writes NULL: the pair already
            -- stored (from the body fetch) stays.
            list_unsubscribe_post = CASE WHEN excluded.list_unsubscribe IS NULL
                THEN list_unsubscribe_post ELSE excluded.list_unsubscribe_post END,
            list_unsubscribe = COALESCE(excluded.list_unsubscribe, list_unsubscribe)
        """

    private static let lookupSQL = """
        SELECT rowid, conversation_provider_id, subject, from_json, to_json, cc_json, bcc_json, snippet
        FROM messages WHERE account_id = ? AND provider_id = ?
        """

    /// The columns the full-text index is derived from (besides the body), compared as the stored JSON so a
    /// poll that only flips flags skips the two index writes. Every one the view reads must be here: a change the
    /// comparison missed would leave the old values indexed, and FTS5 removes an entry only with the exact values
    /// it was indexed with. The snippet is indexed in place of a body not stored yet (v13).
    struct IndexedFields: Equatable {
        var subject: String
        var fromJSON: String?
        var toJSON: String
        var ccJSON: String
        var bccJSON: String
        var snippet: String

        init(_ m: MessageMetadata) throws {
            subject = m.subject
            fromJSON = try m.from.map { try MailStoreCodec.json($0) }
            toJSON = try MailStoreCodec.json(m.to)
            ccJSON = try MailStoreCodec.json(m.cc)
            bccJSON = try MailStoreCodec.json(m.bcc)
            snippet = m.snippet
        }

        init(row: Row) {
            subject = row[2]
            fromJSON = row[3]
            toJSON = row[4]
            ccJSON = row[5]
            bccJSON = row[6]
            snippet = row[7]
        }
    }

    // MARK: Upsert and delete

    /// `senderRules` says whether this is mail arriving (a poll, a head page), which sender rules apply to; the backfill
    /// and a search of the server pass false (`ArrivalRules`).
    static func upsert(_ messages: [MessageMetadata], senderRules: Bool, in db: Database) throws {
        guard !messages.isEmpty else { return }
        try MailSchema.ensureTouchedTable(db)
        let lookup = try db.cachedStatement(sql: lookupSQL)
        let upsert = try db.cachedStatement(sql: upsertSQL)
        // Pending operations win over provider state, but looking them up per message only pays off when the
        // account has any live operation at all, which is rare between user actions.
        let accountsWithOperations = try OperationTable.accountsWithLiveOperations(db)
        // The same for the mute and the sender rules: decided per account once, so a burst of mail into a mailbox with
        // none costs nothing more per message.
        var arrivals = try ArrivalRules(in: db, senderRules: senderRules)
        for incoming in messages {
            var metadata = incoming
            if accountsWithOperations.contains(incoming.id.accountID.rawValue) {
                metadata = try OperationTable.replayLive(on: incoming, in: db)
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
                    try MailTimeTable.messageMoved(incoming.id, to: metadata.conversationID.providerID, in: db)
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
                // The rules first: mail a mute or a sender rule covers leaves the snooze for the refresh to judge.
                if try !arrivals.consider(metadata, in: db) {
                    try SnoozeTable.endForArrival(of: metadata, in: db)
                }
            }
        }
        // Stored as the provider reported them first, so each change records that as its prior, then changed and queued
        // here, in this transaction: no observer ever sees the row in the Inbox.
        try arrivals.enqueue(at: Date(), in: db)
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
            UPDATE messages SET roles = ?, is_read = ?, is_starred = ?, invitation_reply = ?
            WHERE account_id = ? AND provider_id = ?
            """).execute(arguments: [
                MailStoreCodec.roleBits(metadata.roles), metadata.isRead, metadata.isStarred, metadata.invitationReply?.rawValue,
                metadata.id.accountID.rawValue, metadata.id.providerID,
            ])
    }

    // MARK: Reads

    static func fetch(_ id: MessageID, in db: Database) throws -> MessageMetadata? {
        let statement = try db.cachedStatement(sql: "SELECT \(selectColumns) FROM messages WHERE account_id = ? AND provider_id = ?")
        return try Row.fetchOne(statement, arguments: [id.accountID.rawValue, id.providerID]).map(metadata(from:))
    }

    static func fetch(in conversation: ConversationID, db: Database) throws -> [MessageMetadata] {
        let statement = try db.cachedStatement(sql: """
            SELECT \(selectColumns) FROM messages WHERE account_id = ? AND conversation_provider_id = ?
            ORDER BY date_ms, provider_id
            """)
        return try Row.fetchAll(statement, arguments: [conversation.accountID.rawValue, conversation.providerID])
            .map(metadata(from:))
    }

    /// Inbox first, newest first, so hydration follows what the user will open. Two indexed scans that each stop
    /// at the limit beat one query that has to sort every body-less message of a fresh account. An evicted body keeps
    /// its row and `has_body`, so neither lane fetches it back.
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

    /// Bodies whose `typesetting` is NULL, through the partial index of v7, so an upgraded file costs a lookup
    /// and a finished backfill costs nothing.
    static func missingDesignFacts(accountID: AccountID, limit: Int, in db: Database) throws -> [MessageID] {
        guard limit > 0 else { return [] }
        // An evicted body has no source left to work them out from; it gets them when it is fetched again.
        let ids = try String.fetchAll(db, sql: """
            SELECT provider_id FROM bodies INDEXED BY bodies_missing_design_facts
            WHERE account_id = ? AND typesetting IS NULL AND evicted = 0 LIMIT ?
            """, arguments: [accountID.rawValue, limit])
        return ids.map { MessageID(accountID: accountID, providerID: $0) }
    }

    static func saveDesignFacts(_ facts: BodyDesignFacts, for id: MessageID, in db: Database) throws {
        try db.cachedStatement(sql: """
            UPDATE bodies SET typesetting = ?, declares_colors = ?, covered_by_new_york = ?
            WHERE account_id = ? AND provider_id = ?
            """).execute(arguments: [
                MailStoreCodec.typesettingCode(facts.typesetting), facts.declaresColors, facts.coveredByNewYork,
                id.accountID.rawValue, id.providerID,
            ])
    }

    // MARK: Bodies

    /// Returns false when the message is unknown, which happens when a poll deleted it while its body was in flight.
    /// `evicted` stores it as an eviction leaves a body (`BodyEviction`): no source, an empty rendered HTML, the rest
    /// kept, so its source is never written only to be cleared again.
    static func saveBody(_ body: StoredBody, for id: MessageID, evicted: Bool = false, in db: Database) throws -> Bool {
        guard let rowid = try Int64.fetchOne(
            db,
            sql: "SELECT rowid FROM messages WHERE account_id = ? AND provider_id = ?",
            arguments: [id.accountID.rawValue, id.providerID]
        ) else { return false }
        try FullTextIndex.remove(rowid: rowid, in: db)
        try db.cachedStatement(sql: """
            INSERT INTO bodies (account_id, provider_id, html, text, rendered_html, plain_text, attachments_json,
                                has_quoted, blocked_images, typesetting, declares_colors, covered_by_new_york, evicted,
                                invitation_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(account_id, provider_id) DO UPDATE SET
                html = excluded.html, text = excluded.text, rendered_html = excluded.rendered_html,
                plain_text = excluded.plain_text, attachments_json = excluded.attachments_json,
                has_quoted = excluded.has_quoted, blocked_images = excluded.blocked_images,
                typesetting = excluded.typesetting, declares_colors = excluded.declares_colors,
                covered_by_new_york = excluded.covered_by_new_york, evicted = excluded.evicted,
                invitation_json = excluded.invitation_json
            """).execute(arguments: [
                id.accountID.rawValue, id.providerID,
                try evicted ? nil : body.body.html.map(MailStoreCodec.compress),
                try evicted ? nil : body.body.text.map(MailStoreCodec.compress),
                try evicted ? Data() : MailStoreCodec.compress(body.renderedHTML),
                body.plainText,
                try MailStoreCodec.json(body.body.attachments),
                body.hasQuotedContent,
                body.blockedRemoteImageCount,
                body.typesetting.map(MailStoreCodec.typesettingCode),
                body.declaresColors,
                body.coveredByNewYork,
                evicted,
                // Its calendar text is source, which an evicted body keeps none of; fetching it again reads it again.
                try evicted ? nil : body.invitation.map { try MailStoreCodec.json($0) },
            ])
        try db.cachedStatement(sql: "UPDATE messages SET has_body = 1 WHERE rowid = ?").execute(arguments: [rowid])
        // The headers a body fetch carries (Graph's only way to them) go on the message, not in `bodies`.
        if let list = body.body.listUnsubscribe {
            try db.cachedStatement(sql: "UPDATE messages SET list_unsubscribe = ?, list_unsubscribe_post = ? WHERE rowid = ?")
                .execute(arguments: [list, body.body.listUnsubscribePost, rowid])
        }
        try FullTextIndex.insert(rowid: rowid, in: db)
        return true
    }

    /// The attachment list of the stored body, which an eviction keeps; nil when there is no body.
    static func attachments(of id: MessageID, in db: Database) throws -> [AttachmentInfo]? {
        let statement = try db.cachedStatement(sql: "SELECT attachments_json FROM bodies WHERE account_id = ? AND provider_id = ?")
        guard let json = try String.fetchOne(statement, arguments: [id.accountID.rawValue, id.providerID]) else { return nil }
        return try MailStoreCodec.decode([AttachmentInfo].self, from: json)
    }

    /// Nil for an evicted body as for a missing one: either way the reader fetches it (`MailClient.ensureBody`).
    /// `evictedToo` reads an evicted row as it is kept (`keptBody(for:)`): its NULL source and empty rendered HTML read
    /// as none.
    static func body(for id: MessageID, evictedToo: Bool = false, in db: Database) throws -> StoredBody? {
        let statement = try db.cachedStatement(sql: evictedToo ? keptBodySQL : bodySQL)
        guard let row = try Row.fetchOne(statement, arguments: [id.accountID.rawValue, id.providerID]) else { return nil }
        let html: Data? = row[0]
        let text: Data? = row[1]
        let rendered: Data = row[2]
        let evicted: Bool = row[11]
        let attachmentsJSON: String = row[4]
        let invitationJSON: String? = row[10]
        return StoredBody(
            body: MessageBody(
                html: try html.map(MailStoreCodec.decompress),
                text: try text.map(MailStoreCodec.decompress),
                attachments: try MailStoreCodec.decode([AttachmentInfo].self, from: attachmentsJSON)
            ),
            renderedHTML: evicted ? "" : try MailStoreCodec.decompress(rendered),
            plainText: row[3],
            hasQuotedContent: row[5],
            blockedRemoteImageCount: row[6],
            typesetting: MailStoreCodec.typesetting(row[7]),
            declaresColors: row[8],
            coveredByNewYork: row[9],
            // An invitation that no longer decodes (a later build changed its shape) shows no card rather than failing
            // the whole body.
            invitation: invitationJSON.flatMap { try? MailStoreCodec.decode(CalendarInvitation.self, from: $0) }
        )
    }

    private static let bodySQL = """
        SELECT html, text, rendered_html, plain_text, attachments_json, has_quoted, blocked_images,
               typesetting, declares_colors, covered_by_new_york, invitation_json, evicted FROM bodies
        WHERE account_id = ? AND provider_id = ? AND evicted = 0
        """
    private static let keptBodySQL = """
        SELECT html, text, rendered_html, plain_text, attachments_json, has_quoted, blocked_images,
               typesetting, declares_colors, covered_by_new_york, invitation_json, evicted FROM bodies
        WHERE account_id = ? AND provider_id = ?
        """

    /// `body(for:in:)`'s invitation alone, as it reads it (nil for an evicted body, nothing for one that no longer
    /// decodes): one short text column, none of the compressed ones.
    static func invitation(for id: MessageID, in db: Database) throws -> CalendarInvitation? {
        let statement = try db.cachedStatement(sql: """
            SELECT invitation_json FROM bodies WHERE account_id = ? AND provider_id = ? AND evicted = 0
            """)
        guard let json = try String.fetchOne(statement, arguments: [id.accountID.rawValue, id.providerID]) else { return nil }
        return try? MailStoreCodec.decode(CalendarInvitation.self, from: json)
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
            indexed.snippet,
            indexed.fromJSON,
            indexed.toJSON,
            indexed.ccJSON,
            indexed.bccJSON,
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
            m.listUnsubscribe,
            m.listUnsubscribe == nil ? nil : m.listUnsubscribePost,
        ]
    }

    /// Expects the column order of `selectColumns`.
    static func metadata(from row: Row) throws -> MessageMetadata {
        let accountID = AccountID(row[0])
        let fromJSON: String? = row[8]
        let reply: String? = row[25]
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
            sizeBytes: row[22],
            listUnsubscribe: row[23],
            listUnsubscribePost: row[24],
            invitationReply: reply.flatMap(InvitationResponse.init(rawValue:))
        )
    }
}
