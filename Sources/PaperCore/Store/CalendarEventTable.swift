import Foundation
import GRDB

/// SQL for `calendar_events` (v20, docs/DATA-MODEL.md "Calendar events"), and the rules a write follows, as pure functions
/// both stores apply, so `InMemoryMailStore` cannot drift from this one.
enum CalendarEventTable {
    /// A row as stored: the event, and when it last became `creating` or `deleting` (`queued_ms`, nil otherwise), which
    /// orders what the engine replays.
    struct Stored: Hashable {
        var event: CalendarEvent
        var queuedAt: Int64?
    }

    private static let columnNames = [
        "id", "account_id", "provider_id", "title", "location", "start_ms", "end_ms", "is_all_day", "response", "is_free",
        "join_url", "web_url", "organizer", "invitation_uid", "source_account_id", "source_provider_id", "client_key", "sync",
        "updated_ms", "queued_ms", "series_id", "original_start_ms", "time_zone", "kind", "call_service", "version",
    ]
    private static let columns = columnNames.joined(separator: ", ")

    /// The overlap test of `CalendarEvent.overlaps`, as the time index answers it: a range on `start_ms`, the rest checked
    /// in the index. Takes the interval's start twice, after its end.
    private static let overlapsWindow = "start_ms < ? AND (end_ms > ? OR (end_ms = start_ms AND start_ms = ?))"

    // MARK: Rules (both stores)

    /// An event as the store keeps it: its times to the millisecond, as SQLite reads them back, and no thread id (it
    /// lives only on the copy handed to a create).
    static func normalized(_ event: CalendarEvent) -> CalendarEvent {
        var event = event
        event.sourceThreadID = nil
        event.start = MailStoreCodec.date(MailStoreCodec.milliseconds(event.start))
        event.end = MailStoreCodec.date(MailStoreCodec.milliseconds(event.end))
        event.updatedAt = event.updatedAt.map { MailStoreCodec.date(MailStoreCodec.milliseconds($0)) }
        event.originalStart = event.originalStart.map { MailStoreCodec.date(MailStoreCodec.milliseconds($0)) }
        return event
    }

    /// `CalendarEvent.overlaps` in stored milliseconds, so the in-memory store answers exactly what the SQL does for an
    /// interval that is not millisecond-aligned.
    static func overlaps(_ event: CalendarEvent, _ interval: DateInterval) -> Bool {
        let start = MailStoreCodec.milliseconds(event.start), end = MailStoreCodec.milliseconds(event.end)
        let from = MailStoreCodec.milliseconds(interval.start), to = MailStoreCodec.milliseconds(interval.end)
        return start < to && (end > from || (end == start && start == from))
    }

    /// The order every read returns: start, then end, then id.
    static func precedes(_ lhs: CalendarEvent, _ rhs: CalendarEvent) -> Bool {
        (MailStoreCodec.milliseconds(lhs.start), MailStoreCodec.milliseconds(lhs.end), lhs.id)
            < (MailStoreCodec.milliseconds(rhs.start), MailStoreCodec.milliseconds(rhs.end), rhs.id)
    }

    /// The order `pendingCalendarEvents` returns: the oldest change first, then id.
    static func queuedBefore(_ lhs: Stored, _ rhs: Stored) -> Bool {
        (lhs.queuedAt ?? .min, lhs.event.id) < (rhs.queuedAt ?? .min, rhs.event.id)
    }

    /// What `addCalendarEvent` inserts: always `creating` with no provider id, and a client key, so the engine's create is
    /// idempotent even when the caller made none.
    static func adding(_ event: CalendarEvent, now: Int64) -> Stored {
        var event = normalized(event)
        event.providerID = nil
        event.sync = .creating
        if event.clientKey == nil { event.clientKey = CalendarEvent.newClientKey() }
        return Stored(event: event, queuedAt: now)
    }

    /// What a read event of `accountID` becomes, merged into the stored rows: nil when the stored row stays as it is.
    ///
    /// - Parameters:
    ///   - keyed: the account's stored row carrying the read event's client key: the provider's copy of time set aside
    ///     here, which keeps that row's local id and mail (`creating` becomes `synced`, even when the reply to the create
    ///     was lost; `deleting` stays so, with the provider's id, for the engine to delete).
    ///   - sameID: when no row carries its key, the stored row with its id. A `creating` one is kept as it is; a
    ///     `deleting` one keeps `deleting`.
    static func merged(_ read: CalendarEvent, accountID: AccountID, keyed: Stored?, sameID: Stored?) -> Stored? {
        var event = normalized(read)
        event.accountID = accountID
        if let keyed {
            event.id = keyed.event.id
            event.sourceMessage = keyed.event.sourceMessage
            event.clientKey = keyed.event.clientKey
            return keyed.event.sync == .deleting
                ? Stored(event: withSync(event, .deleting), queuedAt: keyed.queuedAt)
                : Stored(event: withSync(event, .synced), queuedAt: nil)
        }
        guard let sameID else { return Stored(event: withSync(event, .synced), queuedAt: nil) }
        if sameID.event.sync == .creating { return nil }
        event.sourceMessage = event.sourceMessage ?? sameID.event.sourceMessage
        event.clientKey = event.clientKey ?? sameID.event.clientKey
        return sameID.event.sync == .deleting
            ? Stored(event: withSync(event, .deleting), queuedAt: sameID.queuedAt)
            : Stored(event: withSync(event, .synced), queuedAt: nil)
    }

    /// The read events as a replace merges them: a client key claims at most one stored row per read, so the first
    /// event listed with a key keeps it, and any later one with that key (an occurrence of a block made repeating
    /// elsewhere, a copy of it) loses it and is stored under its own provider id as any event is, never over the first.
    static func claimingKeys(_ events: [CalendarEvent]) -> [CalendarEvent] {
        var claimed: Set<String> = []
        return events.map { read in
            guard let key = read.clientKey, !claimed.insert(key).inserted else { return read }
            var unkeyed = read
            unkeyed.clientKey = nil
            return unkeyed
        }
    }

    /// How long a `synced` event that has ended stays behind the window a read keeps: a read deletes the account's ones
    /// that ended earlier, so the table, the range reads and every refresh's sweep stay the size of the window rather
    /// than of all the history ever read.
    static let keptBehindWindow: TimeInterval = 30 * 86_400

    /// The end before which a replace of `window` at `now` deletes the account's `synced` events: `keptBehindWindow`
    /// before the start of the window kept around now, or of `window` when that starts earlier (days behind the kept
    /// window the app asked to see, whose events stay until a read of the kept window).
    static func pruneLine(window: DateInterval, now: Int64) -> Int64 {
        let kept = CalendarWindow.around(MailStoreCodec.date(now))
        return MailStoreCodec.milliseconds(min(window.start, kept.start).addingTimeInterval(-keptBehindWindow))
    }

    /// Whether a replace deletes the row as history (`pruneLine`): only a `synced` one, never one still waiting for the
    /// provider (`creating`, `deleting`) or marked `failed`. Its start is checked too, as the time index answers it.
    static func isPruned(_ row: CalendarEvent, accountID: AccountID, before line: Int64) -> Bool {
        row.accountID == accountID && row.sync == .synced && MailStoreCodec.milliseconds(row.start) < line
            && MailStoreCodec.milliseconds(row.end) < line
    }

    /// Whether a replace of `window` deletes the row: one of the account the provider has had (`synced` or
    /// `deleting`) that overlaps the window and that the read did not list. A row outside the window is the read's
    /// business no more. A `failed` row stays: the provider never had it, and its failed mark shows until the user
    /// removes it.
    static func isSwept(_ row: CalendarEvent, accountID: AccountID, window: DateInterval, listed: Set<String>) -> Bool {
        row.accountID == accountID && (row.sync == .synced || row.sync == .deleting) && overlaps(row, window)
            && !listed.contains(row.id)
    }

    /// What `removeCalendarEvent` leaves: nil when the row goes at once (the provider never had it), the row as
    /// `deleting` when the engine must delete it there, the row unchanged when that is already so.
    ///
    /// A `creating` row is kept as a hidden `deleting` tombstone with no provider id, under the same id and client key:
    /// its create may have reached the provider with its reply lost, and only the key finds that copy. A read that
    /// lists the copy fills in its provider id (merged by key), so the engine deletes it; one that does not sweeps the
    /// tombstone; a create on its way when it was removed settles its copy into it, which the engine then deletes.
    static func removing(_ row: Stored, now: Int64) -> Stored? {
        switch row.event.sync {
        case .creating:
            return Stored(event: withSync(row.event, .deleting), queuedAt: now)
        case .failed:
            // The provider refused the create: it made nothing.
            return nil
        case .synced:
            // A synced row always has the provider's id; one without could never be deleted there, so it just goes.
            guard row.event.providerID != nil else { return nil }
            return Stored(event: withSync(row.event, .deleting), queuedAt: now)
        case .deleting:
            return row
        }
    }

    /// What `restoreCalendarEvent` leaves, given the row now stored with the event's id.
    static func restoring(_ event: CalendarEvent, current: Stored?, now: Int64) -> Stored {
        if let current {
            guard current.event.sync == .deleting else { return current }
            // A tombstone of a block still being created: `creating` again under the same key, so a create sent again
            // finds any copy the first one made rather than making a second.
            if current.event.providerID == nil { return Stored(event: withSync(current.event, .creating), queuedAt: now) }
            return Stored(event: withSync(current.event, .synced), queuedAt: nil)
        }
        var event = normalized(event)
        if event.providerID != nil {
            // The provider had it and has deleted it: it is made again as new. Google keeps a deleted event's id
            // reserved, so neither the local id nor the client key (Google's id for it) can be used again, and what the
            // provider gave the old copy (its links, its UID, its time of change) does not belong to the new one.
            event.id = CalendarEvent.newLocalID(accountID: event.accountID)
            event.clientKey = CalendarEvent.newClientKey()
            event.providerID = nil
            event.webURL = nil
            event.joinURL = nil
            event.invitationUID = nil
            event.updatedAt = nil
            event.seriesID = nil
            event.originalStart = nil
            event.timeZone = nil
            event.kind = nil
            event.callService = nil
            event.version = nil
        } else {
            // Removed while it was still `creating`, and its tombstone gone since: the engine deleted the copy a create
            // made, which reserves the key at Google, or the read found none. A new key keeps the new create from
            // meeting that reserved id.
            event.clientKey = CalendarEvent.newClientKey()
        }
        return Stored(event: withSync(event, .creating), queuedAt: now)
    }

    /// What `settleCalendarEvent` does with the row stored under the id.
    enum Settlement: Equatable {
        /// The row is gone or no longer waits for this: nothing changes, and the engine undoes what it just did.
        case refused
        /// The provider's copy replaces the `creating` row, or fills in the provider id of a tombstone (a block removed
        /// while its create was on its way), which the engine then deletes.
        case replace(Stored)
        /// A read already put this very copy in the row (by its client key): nothing changes, and the copy stays.
        case alreadySettled
        /// The provider deleted it: the `deleting` row goes.
        case delete
    }

    static func settlement(of row: Stored?, created: CalendarEvent?) -> Settlement {
        guard let row else { return .refused }
        guard let created else { return row.event.sync == .deleting ? .delete : .refused }
        switch row.event.sync {
        case .creating:
            var event = normalized(created)
            event.id = row.event.id
            event.accountID = row.event.accountID
            event.sourceMessage = event.sourceMessage ?? row.event.sourceMessage
            event.clientKey = event.clientKey ?? row.event.clientKey
            return .replace(Stored(event: withSync(event, .synced), queuedAt: nil))
        case .synced where created.providerID != nil && row.event.providerID == created.providerID:
            return .alreadySettled
        case .deleting where row.event.providerID == nil && created.providerID != nil:
            // Removed while the create was on its way: the tombstone keeps the copy's id, so its delete survives a
            // failure or a quit.
            var event = row.event
            event.providerID = created.providerID
            return .replace(Stored(event: event, queuedAt: row.queuedAt))
        default:
            return .refused
        }
    }

    /// What `failCalendarEvent` leaves: only a `creating` row becomes `failed`.
    static func failing(_ row: Stored) -> Stored {
        guard row.event.sync == .creating else { return row }
        return Stored(event: withSync(row.event, .failed), queuedAt: nil)
    }

    private static func withSync(_ event: CalendarEvent, _ sync: CalendarEvent.Sync) -> CalendarEvent {
        var event = event
        event.sync = sync
        return event
    }

    // MARK: Reads

    static func events(in interval: DateInterval, accountIDs: [AccountID]?, in db: Database) throws -> [CalendarEvent] {
        let (sql, arguments) = rangeQuery(interval, accountIDs: accountIDs)
        guard let sql else { return [] }
        return try Row.fetchAll(db.cachedStatement(sql: sql), arguments: arguments).compactMap { stored(from: $0)?.event }
    }

    /// SQLite's plan for the range read, one line per step, so a test can pin it to the time index.
    static func explainEvents(in interval: DateInterval, accountIDs: [AccountID]?, in db: Database) throws -> [String] {
        let (sql, arguments) = rangeQuery(interval, accountIDs: accountIDs)
        guard let sql else { return [] }
        return try Row.fetchAll(db, sql: "EXPLAIN QUERY PLAN " + sql, arguments: arguments).map { $0["detail"] }
    }

    /// Nil SQL when no account is asked for. Always through the time index: left to itself, SQLite answers one account's
    /// read from `calendar_events_by_sync`, which visits every row the account ever stored and then sorts them, where the
    /// time index visits only entries that start before the interval ends, checks their end in the index, and returns them
    /// in order.
    private static func rangeQuery(_ interval: DateInterval, accountIDs: [AccountID]?) -> (sql: String?, arguments: StatementArguments) {
        let start = MailStoreCodec.milliseconds(interval.start)
        var sql = "SELECT \(columns) FROM calendar_events INDEXED BY calendar_events_by_time WHERE \(overlapsWindow)"
        var arguments: [(any DatabaseValueConvertible)?] = [MailStoreCodec.milliseconds(interval.end), start, start]
        if let accountIDs {
            let ids = Array(Set(accountIDs.map(\.rawValue))).sorted()
            guard !ids.isEmpty else { return (nil, []) }
            sql += " AND account_id IN (\(databaseQuestionMarks(count: ids.count)))"
            for id in ids { arguments.append(id) }
        }
        return (sql + " ORDER BY start_ms, end_ms, id", StatementArguments(arguments))
    }

    static func stored(id: String, in db: Database) throws -> Stored? {
        try Row.fetchOne(db.cachedStatement(sql: "SELECT \(columns) FROM calendar_events WHERE id = ?"), arguments: [id])
            .flatMap(stored(from:))
    }

    static func events(seriesID: String, accountID: AccountID, in db: Database) throws -> [Stored] {
        try Row.fetchAll(db.cachedStatement(sql: """
            SELECT \(columns) FROM calendar_events INDEXED BY calendar_events_by_series
            WHERE account_id = ? AND series_id = ? ORDER BY start_ms, end_ms, id
            """), arguments: [accountID.rawValue, seriesID]).compactMap(stored(from:))
    }

    /// The rows an answer's scope may cover, before `CalendarAnswers.covered` picks them.
    static func candidates(for scope: CalendarCopies.Scope, accountID: AccountID, in db: Database) throws -> [Stored] {
        switch scope {
        case .invitation:
            return try Row.fetchAll(db.cachedStatement(sql: """
                SELECT \(columns) FROM calendar_events WHERE account_id = ? AND invitation_uid IS NOT NULL ORDER BY id
                """), arguments: [accountID.rawValue]).compactMap(stored(from:))
        case .event(let id):
            return try stored(id: id, in: db).map { [$0] } ?? []
        case .series(let id):
            return try events(seriesID: id, accountID: accountID, in: db)
        }
    }

    /// The account's live answers that have a calendar part, oldest first. A row this build cannot decode (a later
    /// build's change) is skipped, never thrown: the read must not fail over it.
    static func liveAnswers(accountID: AccountID, in db: Database) throws -> [InvitationAnswer] {
        try Row.fetchAll(db.cachedStatement(sql: """
            SELECT change_json FROM operations
            WHERE account_id = ? AND status IN \(OperationTable.liveStatusList) AND substr(change_json, 1, 20) = '{"answerInvitation":'
            ORDER BY created_at, rowid
            """), arguments: [accountID.rawValue])
            .compactMap { row in
                (try? MailStoreCodec.decode(MetadataChange.self, from: row[0] as String)).flatMap(CalendarAnswers.answer(of:))
            }
    }

    /// The account's answers with a calendar part that are live or failed, oldest first: what an event's card reads.
    static func cardAnswers(accountID: AccountID, in db: Database) throws -> [(status: OperationStatus, answer: InvitationAnswer)] {
        try Row.fetchAll(db.cachedStatement(sql: """
            SELECT status, change_json FROM operations
            WHERE account_id = ? AND status IN ('pending', 'inFlight', 'uncertain', 'failed')
              AND substr(change_json, 1, 20) = '{"answerInvitation":'
            ORDER BY created_at, rowid
            """), arguments: [accountID.rawValue])
            .compactMap { row in
                guard let status = OperationStatus(rawValue: row[0]),
                      let change = try? MailStoreCodec.decode(MetadataChange.self, from: row[1] as String),
                      let answer = CalendarAnswers.answer(of: change) else { return nil }
                return (status, answer)
            }
    }

    static func pending(accountID: AccountID, in db: Database) throws -> [CalendarEvent] {
        try Row.fetchAll(db.cachedStatement(sql: """
            SELECT \(columns) FROM calendar_events WHERE account_id = ? AND sync IN ('creating', 'deleting')
            """), arguments: [accountID.rawValue])
            .compactMap(stored(from:))
            .sorted(by: queuedBefore)
            .map(\.event)
    }

    /// The account's rows that carry a client key, by key (through the partial index); the lowest id wins a key two rows
    /// share, which nothing writes.
    private static func keyed(accountID: AccountID, in db: Database) throws -> [String: Stored] {
        var keyed: [String: Stored] = [:]
        let rows = try Row.fetchAll(db.cachedStatement(sql: """
            SELECT \(columns) FROM calendar_events WHERE account_id = ? AND client_key IS NOT NULL ORDER BY id
            """), arguments: [accountID.rawValue])
        for row in rows {
            guard let stored = stored(from: row), let key = stored.event.clientKey, keyed[key] == nil else { continue }
            keyed[key] = stored
        }
        return keyed
    }

    static func accountExists(_ accountID: AccountID, in db: Database) throws -> Bool {
        try Bool.fetchOne(db.cachedStatement(sql: "SELECT EXISTS (SELECT 1 FROM accounts WHERE id = ?)"),
                          arguments: [accountID.rawValue]) ?? false
    }

    /// A row with a response or a state this build does not know (a later build wrote it) is left out of every read rather
    /// than guessed at. The sweep selects only the states it knows, so it leaves such a row alone unless a read lists its id.
    private static func stored(from row: Row) -> Stored? {
        let responseValue: String = row[8], syncValue: String = row[17]
        guard let response = CalendarEvent.Response(rawValue: responseValue), let sync = CalendarEvent.Sync(rawValue: syncValue) else {
            return nil
        }
        let id: String = row[0], accountID: String = row[1], providerID: String? = row[2], title: String = row[3]
        let location: String? = row[4], start: Int64 = row[5], end: Int64 = row[6], isAllDay: Bool = row[7]
        let isFree: Bool = row[9], joinURL: String? = row[10], webURL: String? = row[11], organizer: String? = row[12]
        let invitationUID: String? = row[13], sourceAccount: String? = row[14], sourceProvider: String? = row[15]
        let clientKey: String? = row[16], updated: Int64? = row[18], queued: Int64? = row[19]
        let seriesID: String? = row[20], originalStart: Int64? = row[21], timeZone: String? = row[22]
        let kindValue: String? = row[23], serviceValue: String? = row[24], version: String? = row[25]
        var source: MessageID?
        if let sourceAccount, let sourceProvider { source = MessageID(accountID: AccountID(sourceAccount), providerID: sourceProvider) }
        // A kind or a service a later build wrote reads as none and keeps the row: unlike a response or a state, nothing
        // this build does with the row depends on it.
        let event = CalendarEvent(
            id: id, accountID: AccountID(accountID), providerID: providerID, title: title, location: location,
            start: MailStoreCodec.date(start), end: MailStoreCodec.date(end), isAllDay: isAllDay, response: response,
            isFree: isFree, joinURL: joinURL, webURL: webURL, organizer: organizer, invitationUID: invitationUID,
            sourceMessage: source, clientKey: clientKey, sync: sync, updatedAt: updated.map(MailStoreCodec.date),
            seriesID: seriesID, originalStart: originalStart.map(MailStoreCodec.date), timeZone: timeZone,
            kind: kindValue.flatMap(CalendarEvent.Kind.init(rawValue:)),
            callService: serviceValue.flatMap(CallService.init(rawValue:)), version: version
        )
        return Stored(event: event, queuedAt: queued)
    }

    // MARK: Writes

    /// Inserts the row or replaces the one with its id, keeping its rowid.
    static func save(_ stored: Stored, in db: Database) throws {
        try db.cachedStatement(sql: """
            INSERT INTO calendar_events (\(columns)) VALUES (\(databaseQuestionMarks(count: columnNames.count)))
            ON CONFLICT(id) DO UPDATE SET \(columnNames.dropFirst().map { "\($0) = excluded.\($0)" }.joined(separator: ", "))
            """).execute(arguments: arguments(of: stored))
    }

    static func delete(id: String, in db: Database) throws {
        try db.cachedStatement(sql: "DELETE FROM calendar_events WHERE id = ?").execute(arguments: [id])
    }

    /// Written out rather than left to the foreign key, so the calendar's observation sees the account's rows go.
    static func removeAll(_ accountID: AccountID, in db: Database) throws {
        try db.execute(sql: "DELETE FROM calendar_events WHERE account_id = ?", arguments: [accountID.rawValue])
    }

    static func add(_ event: CalendarEvent, now: Int64, in db: Database) throws {
        guard try accountExists(event.accountID, in: db) else { throw StoreError.notFound }
        // The row itself, not its decoded form, which leaves out a row a later build wrote.
        let taken = try Bool.fetchOne(db.cachedStatement(sql: "SELECT EXISTS (SELECT 1 FROM calendar_events WHERE id = ?)"),
                                      arguments: [event.id]) ?? false
        guard !taken else { throw StoreError.conflict("a calendar event already has this id") }
        try save(adding(event, now: now), in: db)
    }

    static func replace(_ events: [CalendarEvent], accountID: AccountID, window: DateInterval, now: Int64,
                        in db: Database) throws {
        // The account was removed while its calendar was being read: there is nothing to write it into.
        guard try accountExists(accountID, in: db) else { return }
        let keyed = try keyed(accountID: accountID, in: db)
        // Pending answers win: an answer the provider has not been sent yet keeps its word on the rows it covers.
        let live = try liveAnswers(accountID: accountID, in: db)
        var listed: Set<String> = []
        for read in claimingKeys(events) {
            let byKey = read.clientKey.flatMap { keyed[$0] }
            let id = byKey?.event.id ?? read.id
            listed.insert(id)
            let current = try byKey ?? stored(id: id, in: db)
            guard var merged = merged(read, accountID: accountID, keyed: byKey, sameID: byKey == nil ? current : nil) else { continue }
            if !live.isEmpty { merged = CalendarAnswers.winning(merged, live: live) }
            // A refresh that changes nothing writes nothing: a read every two minutes would otherwise rewrite every row.
            if merged != current { try save(merged, in: db) }
        }
        let start = MailStoreCodec.milliseconds(window.start)
        let candidates = try String.fetchAll(db.cachedStatement(sql: """
            SELECT id FROM calendar_events
            WHERE account_id = ? AND sync IN ('synced', 'deleting') AND \(overlapsWindow)
            """), arguments: [accountID.rawValue, MailStoreCodec.milliseconds(window.end), start, start])
        for id in candidates where !listed.contains(id) { try delete(id: id, in: db) }
        // Through the time index: only the entries that start before the line are visited, and a read that finds no
        // history deletes nothing.
        let line = pruneLine(window: window, now: now)
        try db.cachedStatement(sql: """
            DELETE FROM calendar_events WHERE id IN (
                SELECT id FROM calendar_events INDEXED BY calendar_events_by_time
                WHERE start_ms < ? AND end_ms < ? AND account_id = ? AND sync = 'synced')
            """).execute(arguments: [line, line, accountID.rawValue])
    }

    @discardableResult
    static func remove(id: String, now: Int64, in db: Database) throws -> CalendarEvent? {
        guard let current = try stored(id: id, in: db) else { return nil }
        if let left = removing(current, now: now) {
            if left != current { try save(left, in: db) }
        } else {
            try delete(id: id, in: db)
        }
        return current.event
    }

    static func restore(_ event: CalendarEvent, now: Int64, in db: Database) throws -> CalendarEvent {
        let current = try stored(id: event.id, in: db)
        if current == nil, try !accountExists(event.accountID, in: db) { throw StoreError.notFound }
        let restored = restoring(event, current: current, now: now)
        if restored != current { try save(restored, in: db) }
        return restored.event
    }

    static func settle(id: String, created: CalendarEvent?, in db: Database) throws -> Bool {
        switch settlement(of: try stored(id: id, in: db), created: created) {
        case .refused:
            return false
        case .replace(let row):
            try save(row, in: db)
        case .alreadySettled:
            break
        case .delete:
            try delete(id: id, in: db)
        }
        return true
    }

    static func fail(id: String, in db: Database) throws {
        guard let current = try stored(id: id, in: db) else { return }
        let failed = failing(current)
        if failed != current { try save(failed, in: db) }
    }

    private static func arguments(of stored: Stored) -> StatementArguments {
        let event = stored.event
        let values: [(any DatabaseValueConvertible)?] = [
            event.id, event.accountID.rawValue, event.providerID, event.title, event.location,
            MailStoreCodec.milliseconds(event.start), MailStoreCodec.milliseconds(event.end), event.isAllDay,
            event.response.rawValue, event.isFree, event.joinURL, event.webURL, event.organizer, event.invitationUID,
            event.sourceMessage?.accountID.rawValue, event.sourceMessage?.providerID, event.clientKey, event.sync.rawValue,
            event.updatedAt.map(MailStoreCodec.milliseconds), stored.queuedAt, event.seriesID,
            event.originalStart.map(MailStoreCodec.milliseconds), event.timeZone, event.kind?.rawValue,
            event.callService?.rawValue, event.version,
        ]
        return StatementArguments(values)
    }
}
