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
            inbox_section, has_pending_ops, failed_op_kind, returned_at, muted
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
            END,
            -- And the mute, the user's choice (MuteTable): it lasts as long as the summary row does.
            COALESCE((SELECT c.muted FROM conversations c WHERE c.account_id = b.account_id AND c.provider_id = b.cid), 0)
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
        c.inbox_section, c.has_pending_ops, c.failed_op_kind, c.returned_at, c.muted
        """

    /// The Inbox's sort key, `ConversationSummary.inboxDate`: the refresh keeps `returned_at` only while it is later
    /// than the newest mail, so this is the later of the two. Spelled as `conversations_inbox` spells it (v11), which
    /// is what lets SQLite read the Inbox in index order.
    static let inboxDate = "COALESCE(c.returned_at, c.latest_date_ms)"

    /// The date column a query sorts and pages by: the Inbox's own, except in a search (an `in:inbox` one too), whose
    /// rows sort and show their latest message's date in every view, as the list pages them.
    private static func sortKey(_ query: ConversationQuery) -> String {
        query.view == .inbox && query.search == nil ? inboxDate : "c.latest_date_ms"
    }

    static func fetch(_ query: ConversationQuery, in db: Database) throws -> [ConversationSummary] {
        // The Outbox's rows are the outbox's (spec §5.53), never a conversation: nothing is read, so an observation of
        // it tracks no table and never wakes again.
        guard query.view != .outbox else { return [] }
        // Only a search is worth an interval: the other views are one indexed select. The search's first page is
        // read off the main thread by the observation, but paging reads it on the caller's thread.
        let signposter = StoreSignposts.signposter
        let interval = query.search != nil ? signposter.beginInterval(StoreSignposts.search, id: signposter.makeSignpostID()) : nil
        defer { if let interval { signposter.endInterval(StoreSignposts.search, interval) } }
        return try fetch(query, plan: searchPlan(for: query, in: db), walkLimit: walkLimit, in: db)
    }

    /// `fetch` with the plan and the walk's length given, so tests can hold every plan to the same rows.
    static func fetch(_ query: ConversationQuery, plan: SearchPlan?, walkLimit: Int, in db: Database) throws -> [ConversationSummary] {
        guard query.view != .outbox else { return [] }
        guard plan == .newestThenHits, let bound = try walkBound(before: query.before, limit: walkLimit, in: db) else {
            return try rows(statement(for: query, plan: plan), in: db)
        }
        // The newest conversations walked, then, when they hold fewer results than the page, the older rest from the hits.
        var found = try rows(statement(for: query, plan: .newestFirst, from: bound), in: db)
        if found.count < query.limit {
            var rest = query
            rest.limit = query.limit - found.count
            found += try rows(statement(for: rest, plan: .hitsFirst, below: bound), in: db)
        }
        return found
    }

    private static func rows(_ statement: (sql: String, arguments: [(any DatabaseValueConvertible)?]),
                             in db: Database) throws -> [ConversationSummary] {
        try Row.fetchAll(db.cachedStatement(sql: statement.sql), arguments: StatementArguments(statement.arguments)).map(summary(from:))
    }

    /// The plan `fetch` runs (its walk, for `newestThenHits`), or `plan` where a test chooses it.
    static func explain(_ query: ConversationQuery, plan: SearchPlan? = nil, in db: Database) throws -> [String] {
        let chosen = try plan ?? searchPlan(for: query, in: db)
        let (sql, arguments) = statement(for: query, plan: chosen == .newestThenHits ? .newestFirst : chosen)
        return try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: StatementArguments(arguments))
            .map { $0["detail"] }
    }

    /// How a search with full-text terms reaches its conversations (docs/ARCHITECTURE.md, "Search"). The match runs
    /// once a statement; what differs is what the cost follows, so each query takes the plan whose cost stays small.
    enum SearchPlan: Equatable, Sendable {
        /// Each matching message is looked up by its rowid and its conversation key kept, and those conversations are
        /// sorted: the cost follows the number of hits, so a rare word answers in a few milliseconds in any mailbox.
        case hitsFirst
        /// The conversations are walked newest first on `conversations_latest`, which carries every flag a search tests,
        /// and each is asked whether one of its messages is in the set the match produced (or, inverted, outside it),
        /// until the page is full: the cost follows how far down the page's last row lies, so a word in many messages
        /// is answered from the first few hundred conversations however many hold it.
        case newestFirst
        /// `newestFirst` over the newest `walkLimit` conversations, then `hitsFirst` for the older rest when they hold
        /// fewer results than the page: for a prefix whose count would cost as much as the match (`searchPlan`).
        case newestThenHits
    }

    /// The hits below which a search looks each one up (`SearchPlan.hitsFirst`). Measured on the 300,000-message
    /// fixture, the two plans cost the same at about 6,000 hits (10.5 ms); below 5,000, looking the hits up takes under
    /// 7 ms, and above it walking takes under 20 ms unless the views and operators leave few conversations to find.
    static let hitsFirstLimit = 5_000

    /// The conversations `newestThenHits` walks before it turns to the hits: their index entries alone, about 8 ms.
    static let walkLimit = 10_000

    /// The plan for the query's full-text terms, nil without any. Counting stops at `hitsFirstLimit`, so the count costs
    /// a millisecond or two; a match whose terms are all negated describes what is left outside its hits, which only a
    /// walk can test.
    ///
    /// The last term typed is a prefix, and FTS5 merges every word that starts with a prefix before it gives the first
    /// hit, so counting the match costs what running it does, and a walk would pay it again: `to:own` merged nine words
    /// of 219,000 messages twice, 74 ms in all. The words without the prefix mark are counted instead: their hits are
    /// among the match's, so as many as the limit settle it without a merge (`to:owner`). A prefix of one or two letters
    /// starts words in most messages of any mailbox, so it walks. Any other prefix walks the newest conversations and
    /// looks up the hits of the older rest only when the walk did not fill the page (`newestThenHits`), so a prefix of
    /// many words merges once and one of few walks a bounded stretch and looks its few hits up.
    static func searchPlan(for query: ConversationQuery, in db: Database) throws -> SearchPlan? {
        guard let search = query.search, let match = FullTextIndex.matchExpression(for: search) else { return nil }
        guard !match.inverted else { return .newestFirst }
        // Later sorts by the snooze's time, which a split by date would not keep.
        if query.view != .later, let prefix = search.terms.first(where: { $0.isPrefix && $0.isIndexed }) {
            var words = search
            words.terms = search.terms.map { term in
                var term = term
                term.isPrefix = false
                return term
            }
            if let exact = FullTextIndex.matchExpression(for: words), try hits(exact.expression, in: db) >= hitsFirstLimit {
                return .newestFirst
            }
            return prefixLength(of: prefix) <= 2 ? .newestFirst : .newestThenHits
        }
        return try hits(match.expression, in: db) < hitsFirstLimit ? .hitsFirst : .newestFirst
    }

    /// The date of the `walkLimit`th conversation below `before`, newest first: the walk takes it and everything newer,
    /// the hits everything older. Nil when fewer are left, which the walk takes whole.
    private static func walkBound(before: Date?, limit: Int, in db: Database) throws -> Int64? {
        let sql = "SELECT latest_date_ms FROM conversations INDEXED BY conversations_latest"
            + (before == nil ? "" : " WHERE latest_date_ms < ?") + " ORDER BY latest_date_ms DESC LIMIT 1 OFFSET ?"
        let arguments: [(any DatabaseValueConvertible)?] = (before.map { [MailStoreCodec.milliseconds($0)] } ?? []) + [limit]
        return try Int64.fetchOne(db.cachedStatement(sql: sql), arguments: StatementArguments(arguments))
    }

    /// The messages matching `expression`, counted up to `hitsFirstLimit`.
    private static func hits(_ expression: String, in db: Database) throws -> Int {
        let count = try db.cachedStatement(sql: "SELECT count(*) FROM (SELECT 1 FROM message_fts WHERE message_fts MATCH ? LIMIT ?)")
        return try Int.fetchOne(count, arguments: [expression, hitsFirstLimit]) ?? 0
    }

    /// The letters of the word a prefix term ends on, the one matched as a prefix.
    private static func prefixLength(of term: SearchTerm) -> Int {
        let value: String
        switch term.kind {
        case .text(let text), .phrase(let text), .from(let text), .to(let text), .subject(let text): value = text
        case .unread, .read, .starred, .attachment, .before, .after, .mailbox: return .max
        }
        let words = value.split { !$0.isLetter && !$0.isNumber }
        return words.last?.count ?? 0
    }

    /// `from` and `below` narrow a search to the conversations whose latest message is at or after one date, or before
    /// another, in milliseconds: the two halves of `newestThenHits`.
    private static func statement(for query: ConversationQuery, plan: SearchPlan?, from: Int64? = nil, below: Int64? = nil)
        -> (sql: String, arguments: [(any DatabaseValueConvertible)?]) {
        let isLater = query.view == .later
        let match = FullTextIndex.matchExpression(for: query.search)
        // Hits first finds what matches, so a match with every term negated, which describes what does not, walks.
        let plan = match.map { plan == .hitsFirst && !$0.inverted ? SearchPlan.hitsFirst : .newestFirst }
        // A search's rows sort by their latest message's date. Walking `conversations_latest` keeps that order and stops
        // at the page, and its flags answer the view and the operators without reading the row; the Inbox's own index
        // would read and sort every conversation in the Inbox (40 ms for `in:inbox` in 300,000 messages). Hits first
        // starts from its hits instead.
        let walks = query.search != nil && !isLater && plan != .hitsFirst
        // Later reads the snooze with each row, for its “Back Tue 09:00”; every other view has none to read.
        var sql = "SELECT \(summaryColumns), \(isLater ? "s.due_at" : "NULL") FROM "
        var arguments: [(any DatabaseValueConvertible)?] = []
        // What a search of the server found stands in for the match (`ConversationQuery.serverMatches`): its keys (a few
        // dozen at most) join the hits, so the order, the paging, the view and the operators apply to them alike.
        let found = query.serverMatches.sorted { ($0.accountID.rawValue, $0.providerID) < ($1.accountID.rawValue, $1.providerID) }
        let foundValues = "VALUES " + Array(repeating: "(?, ?)", count: found.count).joined(separator: ", ")
        let foundArguments = found.flatMap { [$0.accountID.rawValue, $0.providerID] as [(any DatabaseValueConvertible)?] }
        var matchPredicate: (sql: String, arguments: [(any DatabaseValueConvertible)?])?
        if let match {
            switch plan {
            case .hitsFirst:
                // CROSS JOIN keeps the hits the outer loop: given the choice, SQLite may walk the view's index and probe
                // the hits instead, which costs every conversation in the view.
                sql += """
                    (SELECT DISTINCT m.account_id, m.conversation_provider_id AS provider_id FROM messages m
                     WHERE m.rowid IN (SELECT rowid FROM message_fts WHERE message_fts MATCH ?)\(found.isEmpty ? "" : " UNION " + foundValues)) hits
                    CROSS JOIN conversations c ON c.account_id = hits.account_id AND c.provider_id = hits.provider_id
                    """
                arguments.append(match.expression)
                arguments += foundArguments
            case .newestFirst, .newestThenHits, nil:
                // The unary plus keeps the set a test: without it SQLite drives the subquery from the set, running the
                // match again for every conversation it walks.
                let exists = """
                    EXISTS (SELECT 1 FROM messages m
                            WHERE m.account_id = c.account_id AND m.conversation_provider_id = c.provider_id
                              AND +m.rowid \(match.inverted ? "NOT IN" : "IN") (SELECT rowid FROM message_fts WHERE message_fts MATCH ?))
                    """
                matchPredicate = found.isEmpty
                    ? (exists, [match.expression])
                    : ("(\(exists) OR (c.account_id, c.provider_id) IN (\(foundValues)))", [match.expression] + foundArguments)
            }
        }
        if plan != .hitsFirst {
            sql += "conversations c" + (walks ? " INDEXED BY conversations_latest" : "")
        }
        if isLater {
            sql += " JOIN snoozes s ON s.account_id = c.account_id AND s.provider_id = c.provider_id"
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
        for term in query.search?.terms ?? [] {
            if let predicate = predicate(for: term, open: query.openConversationID, arguments: &arguments) {
                predicates.append(predicate)
            }
        }
        if let before = query.before, !isLater {
            predicates.append("\(sortKey(query)) < ?")
            arguments.append(MailStoreCodec.milliseconds(before))
        }
        if let from {
            predicates.append("c.latest_date_ms >= ?")
            arguments.append(from)
        }
        if let below {
            predicates.append("c.latest_date_ms < ?")
            arguments.append(below)
        }
        // Last, so the flags the index carries turn a conversation away before its messages are asked.
        if let matchPredicate {
            predicates.append(matchPredicate.sql)
            arguments += matchPredicate.arguments
        }
        sql += " WHERE " + predicates.joined(separator: " AND ")
        if isLater {
            sql += " ORDER BY s.due_at, c.account_id, c.provider_id LIMIT ?"
        } else {
            sql += " ORDER BY \(sortKey(query)) DESC, c.provider_id DESC LIMIT ?"
        }
        arguments.append(query.limit)
        return (sql, arguments)
    }

    /// An operator as a predicate on the summary row: what the row shows (its unread dot, star, attachment, date)
    /// and the view it is in. Nil for the index terms, which the MATCH expressions carry.
    private static func predicate(for term: SearchTerm, open: ConversationID?,
                                  arguments: inout [(any DatabaseValueConvertible)?]) -> String? {
        let negated = term.negated
        switch term.kind {
        case .text, .phrase, .from, .to, .subject:
            return nil
        case .unread, .read:
            let condition = (term.kind == .unread) != negated ? "c.unread_count > 0" : "c.unread_count = 0"
            guard let open else { return condition }
            arguments += [open.accountID.rawValue, open.providerID]
            return "(\(condition) OR (c.account_id = ? AND c.provider_id = ?))"
        case .starred:
            return negated ? "c.is_starred = 0" : "c.is_starred = 1"
        case .attachment:
            return negated ? "c.has_attachments = 0" : "c.has_attachments = 1"
        case .before(let day):
            arguments.append(MailStoreCodec.milliseconds(day))
            return negated ? "c.latest_date_ms >= ?" : "c.latest_date_ms < ?"
        case .after(let day):
            arguments.append(MailStoreCodec.milliseconds(day))
            return negated ? "c.latest_date_ms < ?" : "c.latest_date_ms >= ?"
        case .mailbox(let view):
            // Later's own predicate leans on the Later view's join to `snoozes`, which no other view has.
            let inView = view == .later ? snoozedPredicate : viewPredicate(view)
            return negated ? "NOT (\(inView))" : "(\(inView))"
        }
    }

    /// Read from `conversations_latest` alone, which carries the flag, the count and the account: the Inbox's own index
    /// would look each row up for its count, 52 ms for the 55,000 Inbox conversations of 300,000 messages, where the
    /// covering index is read in 2. The badge counts every account after every change, off the main thread.
    static func unreadInboxCount(accountIDs: [AccountID]?, in db: Database) throws -> Int {
        var sql = "SELECT COALESCE(SUM(c.unread_count), 0) FROM conversations c INDEXED BY conversations_latest WHERE c.in_inbox = 1"
        var arguments: [(any DatabaseValueConvertible)?] = []
        if let accountIDs {
            sql += " AND " + accountFilter(accountIDs, arguments: &arguments)
        }
        return try Int.fetchOne(db, sql: sql, arguments: StatementArguments(arguments)) ?? 0
    }

    /// The conversation is snoozed, without the Later view's join.
    private static let snoozedPredicate =
        "EXISTS (SELECT 1 FROM snoozes sn WHERE sn.account_id = c.account_id AND sn.provider_id = c.provider_id)"

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
        // No conversation is in the Outbox; `fetch` never asks.
        case .outbox: return "0"
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
        let muted: Bool = row[16]
        let snoozedUntil: Int64? = row[17]
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
            snoozedUntil: snoozedUntil.map(MailStoreCodec.date),
            isMuted: muted
        )
    }
}
