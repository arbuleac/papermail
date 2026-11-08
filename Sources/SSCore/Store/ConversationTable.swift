import Foundation
import GRDB
import os

/// SQL for the denormalized `conversations` summary rows: the aggregate refresh and the list queries.
enum ConversationTable {
    private static let touched = "temp.\(MailSchema.touchedTable)"

    // MARK: Touched set

    static func touch(_ id: ConversationID, in db: Database) throws {
        try touch(accountID: id.accountID, providerID: id.providerID, in: db)
    }

    static func touch(accountID: AccountID, providerID: String, in db: Database) throws {
        try db.cachedStatement(sql: "INSERT OR IGNORE INTO \(touched) (account_id, provider_id) VALUES (?, ?)")
            .execute(arguments: [accountID.rawValue, providerID])
    }

    /// Recomputes the summary row of every touched conversation in one aggregate statement, deletes the rows of
    /// conversations that lost their last message, and clears the touched set.
    static func refreshTouched(_ db: Database) throws {
        try db.cachedStatement(sql: refreshSQL).execute()
        try db.cachedStatement(sql: pruneSQL).execute()
        // A snooze ends once its conversation is back in the Inbox, in the Trash or gone, whatever put it there.
        try SnoozeTable.endForTouched(in: db)
        try db.cachedStatement(sql: "DELETE FROM \(touched)").execute()
    }

    // The rules mirror InMemoryMailStore.summarize: spam never counts; "visible" messages are the ones not in
    // trash; a conversation whose every message is trashed is summarized from the trashed messages instead so
    // the Trash view can show it; subject and participants look at every non-spam message, oldest first.
    //
    // The CROSS JOINs are join-order hints: the temp table has no statistics, and without them SQLite scans
    // every message of the mailbox probing the handful of touched keys instead of the other way round.
    private static let refreshSQL = """
        WITH msgs AS (
            SELECT m.account_id, m.conversation_provider_id AS cid, m.provider_id, m.subject, m.snippet,
                   m.from_json, m.date_ms, m.roles, m.is_read, m.is_starred, m.inbox_section, m.has_attachments,
                   (m.roles & \(MailStoreCodec.trashBit)) != 0 AS trashed
            FROM \(touched) t
            CROSS JOIN messages m ON m.account_id = t.account_id AND m.conversation_provider_id = t.provider_id
            WHERE (m.roles & \(MailStoreCodec.spamBit)) = 0
        ),
        counts AS (
            SELECT account_id, cid, SUM(trashed = 0) AS visible_count FROM msgs GROUP BY account_id, cid
        ),
        basis AS (
            SELECT msgs.*, counts.visible_count
            FROM msgs JOIN counts ON counts.account_id = msgs.account_id AND counts.cid = msgs.cid
            WHERE msgs.trashed = 0 OR counts.visible_count = 0
        ),
        latest AS (
            SELECT account_id, cid, provider_id, snippet, date_ms
            FROM (SELECT b.*, ROW_NUMBER() OVER (PARTITION BY account_id, cid ORDER BY date_ms DESC, provider_id DESC) AS rn
                  FROM basis b)
            WHERE rn = 1
        )
        INSERT OR REPLACE INTO conversations (
            account_id, provider_id, subject, snippet, participants_json, latest_date_ms, latest_provider_id,
            message_count, unread_count, is_starred, has_attachments, in_inbox, in_sent, in_drafts, in_trash,
            inbox_section, has_pending_ops, failed_op_kind, returned_at
        )
        SELECT b.account_id, b.cid,
            COALESCE((SELECT s.subject FROM msgs s
                      WHERE s.account_id = b.account_id AND s.cid = b.cid AND trim(s.subject, ' \t\r\n') != ''
                      ORDER BY s.date_ms, s.provider_id LIMIT 1), ''),
            l.snippet,
            COALESCE((SELECT json_group_array(json(from_json)) FROM (
                SELECT from_json, date_ms, provider_id FROM (
                    SELECT s.from_json, s.date_ms, s.provider_id,
                           ROW_NUMBER() OVER (PARTITION BY lower(json_extract(s.from_json, '$.address'))
                                              ORDER BY s.date_ms, s.provider_id) AS rn
                    FROM msgs s
                    WHERE s.account_id = b.account_id AND s.cid = b.cid AND s.from_json IS NOT NULL)
                WHERE rn = 1 ORDER BY date_ms, provider_id)), '[]'),
            l.date_ms,
            l.provider_id,
            b.visible_count,
            SUM(b.trashed = 0 AND b.is_read = 0),
            MAX(b.is_starred),
            MAX(b.has_attachments),
            MAX((b.roles & \(MailStoreCodec.inboxBit)) != 0 AND b.trashed = 0),
            MAX((b.roles & \(MailStoreCodec.sentBit)) != 0),
            MAX((b.roles & \(MailStoreCodec.draftsBit)) != 0),
            b.visible_count = 0,
            CASE WHEN MAX((b.roles & \(MailStoreCodec.inboxBit)) != 0 AND b.trashed = 0 AND b.inbox_section = 'focused') THEN 'focused'
                 WHEN MAX((b.roles & \(MailStoreCodec.inboxBit)) != 0 AND b.trashed = 0 AND b.inbox_section = 'other') THEN 'other'
                 ELSE 'unknown' END,
            EXISTS (SELECT 1 FROM messages mm
                    CROSS JOIN operation_targets ot ON ot.account_id = mm.account_id AND ot.provider_id = mm.provider_id
                    CROSS JOIN operations o ON o.id = ot.operation_id
                    WHERE mm.account_id = b.account_id AND mm.conversation_provider_id = b.cid
                      AND o.status IN \(OperationTable.liveStatusList)),
            -- The failed mark is not derived from the messages; it is kept by the operation writes
            -- (FailedOperationMarks), and REPLACE would otherwise reset it on every refresh.
            (SELECT c.failed_op_kind FROM conversations c WHERE c.account_id = b.account_id AND c.provider_id = b.cid),
            -- So is the return mark (SnoozeTable.returnDue). It stays while the conversation is in the Inbox and its
            -- newest mail is older, so reading it moves no row; leaving the Inbox or newer mail ends it.
            CASE WHEN MAX((b.roles & \(MailStoreCodec.inboxBit)) != 0 AND b.trashed = 0) THEN
                (SELECT c.returned_at FROM conversations c
                 WHERE c.account_id = b.account_id AND c.provider_id = b.cid AND c.returned_at > l.date_ms)
            END
        FROM basis b
        JOIN latest l ON l.account_id = b.account_id AND l.cid = b.cid
        GROUP BY b.account_id, b.cid
        """

    // Phrased as a key lookup driven by the touched set, so pruning never scans the conversations table.
    private static let pruneSQL = """
        DELETE FROM conversations
        WHERE (account_id, provider_id) IN (
            SELECT t.account_id, t.provider_id FROM \(touched) t
            WHERE NOT EXISTS (SELECT 1 FROM messages m
                              WHERE m.account_id = t.account_id AND m.conversation_provider_id = t.provider_id
                                AND (m.roles & \(MailStoreCodec.spamBit)) = 0))
        """

    // MARK: Queries

    private static let summaryColumns = """
        c.account_id, c.provider_id, c.subject, c.snippet, c.participants_json, c.latest_date_ms, \
        c.latest_provider_id, c.message_count, c.unread_count, c.is_starred, c.has_attachments, c.in_inbox, \
        c.inbox_section, c.has_pending_ops, c.failed_op_kind, c.returned_at
        """

    /// The Inbox's sort key, `ConversationSummary.inboxDate`: the refresh keeps `returned_at` only while it is later
    /// than the newest mail, so this is the later of the two. Spelled as `conversations_inbox` spells it (v11), which
    /// is what lets SQLite read the Inbox in index order.
    static let inboxDate = "COALESCE(c.returned_at, c.latest_date_ms)"

    /// The date column a view sorts and pages by.
    private static func sortKey(_ view: MailboxView) -> String {
        view == .inbox ? inboxDate : "c.latest_date_ms"
    }

    static func fetch(_ query: ConversationQuery, in db: Database) throws -> [ConversationSummary] {
        let (sql, arguments, isSearch) = statement(for: query)
        // Only a full-text read is worth an interval: the other views are one indexed select. The search's first
        // page is read off the main thread by the observation, but paging reads it on the caller's thread.
        let signposter = StoreSignposts.signposter
        let interval = isSearch ? signposter.beginInterval(StoreSignposts.search, id: signposter.makeSignpostID()) : nil
        defer { if let interval { signposter.endInterval(StoreSignposts.search, interval) } }
        let statement = try db.cachedStatement(sql: sql)
        return try Row.fetchAll(statement, arguments: StatementArguments(arguments)).map(summary(from:))
    }

    static func explain(_ query: ConversationQuery, in db: Database) throws -> [String] {
        let (sql, arguments, _) = statement(for: query)
        return try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: StatementArguments(arguments))
            .map { $0["detail"] }
    }

    /// `isSearch` says whether the statement reads the full-text index, which only a query with indexable text does.
    private static func statement(for query: ConversationQuery)
        -> (sql: String, arguments: [(any DatabaseValueConvertible)?], isSearch: Bool) {
        let isLater = query.view == .later
        // Later reads the snooze with each row, for its “Back Tue 09:00”; every other view has none to read.
        var sql = "SELECT \(summaryColumns), \(isLater ? "s.due_at" : "NULL") FROM conversations c"
        if isLater {
            sql += " JOIN snoozes s ON s.account_id = c.account_id AND s.provider_id = c.provider_id"
        }
        var arguments: [(any DatabaseValueConvertible)?] = []
        let match = FullTextIndex.matchExpression(for: query.searchText)
        if let match {
            // Hits are collapsed to conversation keys once, then joined to the summary rows the list needs,
            // so the result carries the same denormalized columns as every other view.
            sql += """
                 JOIN (SELECT DISTINCT m.account_id, m.conversation_provider_id AS provider_id
                       FROM message_fts f JOIN messages m ON m.rowid = f.rowid
                       WHERE message_fts MATCH ?) hits
                   ON hits.account_id = c.account_id AND hits.provider_id = c.provider_id
                """
            arguments.append(match)
        }
        var predicates = [viewPredicate(query.view)]
        if let accountIDs = query.accountIDs {
            predicates.append(accountFilter(accountIDs, arguments: &arguments))
        }
        if let section = query.section {
            predicates.append("c.inbox_section = ?")
            arguments.append(section.rawValue)
        }
        if query.unreadOnly {
            predicates.append("c.unread_count > 0")
        }
        if let before = query.before, !isLater {
            predicates.append("\(sortKey(query.view)) < ?")
            arguments.append(MailStoreCodec.milliseconds(before))
        }
        sql += " WHERE " + predicates.joined(separator: " AND ")
        if isLater {
            sql += " ORDER BY s.due_at, c.account_id, c.provider_id LIMIT ?"
        } else {
            sql += " ORDER BY \(sortKey(query.view)) DESC, c.provider_id DESC LIMIT ?"
        }
        arguments.append(query.limit)
        return (sql, arguments, match != nil)
    }

    static func unreadInboxCount(accountIDs: [AccountID]?, in db: Database) throws -> Int {
        var sql = "SELECT COALESCE(SUM(c.unread_count), 0) FROM conversations c WHERE c.in_inbox = 1"
        var arguments: [(any DatabaseValueConvertible)?] = []
        if let accountIDs {
            sql += " AND " + accountFilter(accountIDs, arguments: &arguments)
        }
        return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) ?? 0
    }

    private static func viewPredicate(_ view: MailboxView) -> String {
        switch view {
        case .inbox: return "c.in_inbox = 1"
        case .starred: return "c.is_starred = 1 AND c.in_trash = 0"
        case .sent: return "c.in_sent = 1 AND c.in_trash = 0"
        case .drafts: return "c.in_drafts = 1 AND c.in_trash = 0"
        case .trash: return "c.in_trash = 1"
        case .all: return "c.message_count > 0 AND c.in_trash = 0"
        // The join to `snoozes` is the filter: a snoozed conversation is never in the Inbox or the Trash.
        case .later: return "1"
        }
    }

    private static func accountFilter(_ ids: [AccountID], arguments: inout [(any DatabaseValueConvertible)?]) -> String {
        guard !ids.isEmpty else { return "0" }
        arguments += ids.map { $0.rawValue }
        return "c.account_id IN (" + Array(repeating: "?", count: ids.count).joined(separator: ", ") + ")"
    }

    /// Expects the column order of `summaryColumns`, then the snooze's due time (NULL outside Later).
    private static func summary(from row: Row) throws -> ConversationSummary {
        let accountID = AccountID(row[0])
        let failedKind: String? = row[14]
        let returnedAt: Int64? = row[15]
        let snoozedUntil: Int64? = row[16]
        return ConversationSummary(
            id: ConversationID(accountID: accountID, providerID: row[1]),
            subject: row[2],
            snippet: row[3],
            participants: try MailStoreCodec.decode([EmailAddress].self, from: row[4]),
            latestDate: MailStoreCodec.date(row[5]),
            messageCount: row[7],
            unreadCount: row[8],
            isStarred: row[9],
            hasAttachments: row[10],
            inInbox: row[11],
            inboxSection: InboxSection(rawValue: row[12]) ?? .unknown,
            latestMessageID: MessageID(accountID: accountID, providerID: row[6]),
            hasPendingOperations: row[13],
            failedOperation: failedKind.flatMap(OperationKind.init(rawValue:)),
            returnedAt: returnedAt.map(MailStoreCodec.date),
            snoozedUntil: snoozedUntil.map(MailStoreCodec.date)
        )
    }
}
