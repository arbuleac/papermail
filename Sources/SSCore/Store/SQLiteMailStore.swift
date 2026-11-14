import Foundation
import GRDB
import os

/// The production `MailStoring`: one SQLite file in WAL mode behind a GRDB `DatabasePool`, with the schema from
/// docs/DATA-MODEL.md and the semantics of `InMemoryMailStore`.
///
/// Every mutating call is one transaction, and every call that touches messages or operations recomputes the
/// summary rows of the affected conversations with aggregate SQL before it commits, so the list queries are
/// single indexed selects over `conversations` and observers see each transaction exactly once.
public final class SQLiteMailStore: MailStoring, MailStoreMaintenance, Sendable {
    private let database: any StoreDatabase
    private static let log = Logger(subsystem: "io.3it.supersparrow", category: "SQLiteMailStore")

    /// Opens (creating as needed) the database at `path`. The containing directory is created with mode 0700
    /// and the database files are restricted to 0600, since they hold the user's mail.
    public init(path: String) throws {
        let fileManager = FileManager.default
        let fileURL = URL(fileURLWithPath: path)
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // SQLite gives the -wal and -shm files the permissions of the main file, and an empty file is a valid
        // empty database, so creating it private before the first open keeps every file private from the start
        // instead of tightening them after SQLite has already created them with the umask.
        if !fileManager.fileExists(atPath: path) {
            _ = fileManager.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        var configuration = Self.configuration()
        // Readers never wait on the writer in WAL mode; the timeout only matters if another process holds the file.
        configuration.busyMode = .timeout(5)
        let pool = try DatabasePool(path: path, configuration: configuration)
        try Self.restrictPermissions(of: path)
        try MailSchema.migrator().migrate(pool)
        database = pool
    }

    /// A private in-memory database with the same schema and semantics, for tests and previews.
    public static func inMemory() throws -> SQLiteMailStore {
        let queue = try DatabaseQueue(path: ":memory:", configuration: configuration())
        try MailSchema.migrator().migrate(queue)
        return SQLiteMailStore(database: queue)
    }

    /// Where the app keeps its mailbox: `~/Library/Application Support/SuperSparrow/mail.sqlite`.
    public static var defaultPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SuperSparrow/mail.sqlite").path
    }

    private init(database: any StoreDatabase) {
        self.database = database
    }

    /// What every connection shares. GRDB prepares the writer before it switches the file to WAL, which writes the
    /// first page, so a new file is still empty here and takes incremental vacuum (`MailSchema.prepareAutoVacuum`).
    private static func configuration() -> Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in try MailSchema.prepareAutoVacuum(db) }
        return configuration
    }

    /// Closes the underlying connections. Every later call throws; observations stop.
    public func close() throws {
        try database.close()
    }

    private static func restrictPermissions(of path: String) throws {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] where fileManager.fileExists(atPath: path + suffix) {
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path + suffix)
        }
    }

    // MARK: Access

    private func read<T>(_ work: (Database) throws -> T) throws -> T {
        do {
            return try database.read(work)
        } catch let error as DatabaseError {
            throw StoreError.underlying(error.description)
        }
    }

    private func write<T>(_ work: (Database) throws -> T) throws -> T {
        do {
            return try database.write(work)
        } catch let error as DatabaseError {
            throw StoreError.underlying(error.description)
        }
    }

    // MARK: Accounts

    public func accounts() throws -> [Account] {
        try read { try AccountTable.all($0) }
    }

    public func upsertAccount(_ account: Account) throws {
        try write { try AccountTable.upsert(account, in: $0) }
    }

    public func deleteAccount(_ id: AccountID) throws {
        try write { try AccountTable.delete(id, in: $0) }
    }

    public func setInkSlot(_ slot: Int, for accountID: AccountID) throws {
        try write { try AccountTable.setInkSlot(slot, for: accountID, in: $0) }
    }

    public func setMonogram(_ monogram: String?, for accountID: AccountID) throws {
        try write { try AccountTable.setMonogram(monogram, for: accountID, in: $0) }
    }

    public func setSignature(_ signature: String?, for accountID: AccountID) throws {
        try write { try AccountTable.setSignature(signature, for: accountID, in: $0) }
    }

    // MARK: Sync state

    public func syncCursor(for accountID: AccountID) throws -> String? {
        try read { try AccountTable.syncCursor(for: accountID, in: $0) }
    }

    public func setSyncCursor(_ cursor: String?, for accountID: AccountID) throws {
        try write { try AccountTable.setSyncCursor(cursor, for: accountID, in: $0) }
    }

    public func bootstrapState(for accountID: AccountID) throws -> BootstrapState? {
        try read { try AccountTable.bootstrapState(for: accountID, in: $0) }
    }

    public func setBootstrapState(_ state: BootstrapState?, for accountID: AccountID) throws {
        try write { try AccountTable.setBootstrapState(state, for: accountID, in: $0) }
    }

    public func wipeMailData(for accountID: AccountID) throws {
        try write { try AccountTable.wipe(accountID, in: $0) }
    }

    // MARK: Messages

    public func upsertMessages(_ messages: [MessageMetadata]) throws {
        guard !messages.isEmpty else { return }
        try write { try MessageTable.upsert(messages, in: $0) }
    }

    public func deleteMessages(_ ids: [MessageID]) throws {
        guard !ids.isEmpty else { return }
        try write { try MessageTable.delete(ids, in: $0) }
    }

    public func message(_ id: MessageID) throws -> MessageMetadata? {
        try read { try MessageTable.fetch(id, in: $0) }
    }

    public func messages(in conversation: ConversationID) throws -> [MessageMetadata] {
        try read { try MessageTable.fetch(in: conversation, db: $0) }
    }

    /// Stores a body for a known message. A body for a message that no longer exists is dropped silently: the
    /// hydrator may have fetched it just before a poll deleted the message.
    public func saveBody(_ body: StoredBody, for id: MessageID) throws {
        try write { _ = try MessageTable.saveBody(body, for: id, in: $0) }
    }

    @discardableResult
    public func saveBody(_ body: StoredBody, for id: MessageID, evictingIfReceivedBefore cutoff: Date) throws -> Bool {
        try write { db in
            let evicted = try BodyEviction.isEligible(id, receivedBefore: cutoff, in: db)
            return try MessageTable.saveBody(body, for: id, evicted: evicted, in: db) && evicted
        }
    }

    /// Stores several bodies in one transaction, so a hydration round costs one WAL commit instead of one per message.
    public func saveBodies(_ entries: [(id: MessageID, body: StoredBody)]) throws {
        guard !entries.isEmpty else { return }
        try write { db in
            for entry in entries {
                _ = try MessageTable.saveBody(entry.body, for: entry.id, in: db)
            }
        }
    }

    public func body(for id: MessageID) throws -> StoredBody? {
        try read { try MessageTable.body(for: id, in: $0) }
    }

    public func messageIDsMissingBodies(accountID: AccountID, limit: Int) throws -> [MessageID] {
        try read { try MessageTable.missingBodies(accountID: accountID, limit: limit, in: $0) }
    }

    public func attachments(of id: MessageID) throws -> [AttachmentInfo]? {
        try read { try MessageTable.attachments(of: id, in: $0) }
    }

    @discardableResult
    public func evictBodies(from start: Date?, limit: Int,
                            rules: () -> (cutoff: Date, excluding: Set<MessageID>)?) throws -> (evicted: Int, next: Date?) {
        guard limit > 0, let looking = rules() else { return (0, nil) }
        // Candidates come from a reader, so once the window is reached a sweep costs a read and never takes the
        // writer. Excluded messages (often thousands by late in a run, mostly recent) take no place in the batch: a page
        // of them is read past only when they fill it, so the usual batch reads `limit` rows, not that many more.
        let found = try read { db -> (chosen: [(rowid: Int64, id: MessageID)], reached: Int64?, isLast: Bool) in
            var chosen: [(rowid: Int64, id: MessageID)] = []
            var reached: Int64?
            var offset = 0
            while true {
                let page = try BodyEviction.candidates(receivedBefore: looking.cutoff, from: start, limit: limit,
                                                       offset: offset, in: db)
                for candidate in page where chosen.count < limit {
                    reached = candidate.dateMS
                    if !looking.excluding.contains(candidate.id) { chosen.append((candidate.rowid, candidate.id)) }
                }
                if chosen.count == limit { return (chosen, reached, false) }
                // A short page, every row of it looked at, reached the cutoff: nothing is left after this batch.
                if page.count < limit { return (chosen, reached, true) }
                offset += page.count
            }
        }
        let chosen = found.chosen
        let next = found.isLast ? nil : found.reached.map(MailStoreCodec.date)
        guard !chosen.isEmpty else { return (0, next) }
        let evicted = try write { db -> Int in
            // Asked again here, holding the writer: a message the reader marked kept while the candidates were read, or
            // a window widened (Everything: nil) meanwhile, is left alone. The write checks every store rule again too,
            // so a body saved or an operation queued in between is left alone.
            guard let now = rules() else { return 0 }
            let rowids = chosen.filter { !now.excluding.contains($0.id) }.map(\.rowid)
            return try BodyEviction.evict(rowids, receivedBefore: now.cutoff, in: db)
        }
        return (evicted, next)
    }

    public func messageIDsMissingDesignFacts(accountID: AccountID, limit: Int) throws -> [MessageID] {
        try read { try MessageTable.missingDesignFacts(accountID: accountID, limit: limit, in: $0) }
    }

    public func saveDesignFacts(_ facts: [MessageID: BodyDesignFacts]) throws {
        guard !facts.isEmpty else { return }
        try write { db in
            for (id, fact) in facts { try MessageTable.saveDesignFacts(fact, for: id, in: db) }
        }
    }

    // MARK: Backfill

    public func backfillSkippableIDs(accountID: AccountID, providerIDs: [String], includeStored: Bool) throws -> Set<String> {
        guard !providerIDs.isEmpty else { return [] }
        return try read {
            try BackfillMarks.skippable(accountID: accountID, providerIDs: providerIDs, includeStored: includeStored, in: $0)
        }
    }

    @discardableResult
    public func writeBackfillMessages(_ messages: [MessageMetadata], refreshExisting: Bool) throws -> Int {
        guard !messages.isEmpty else { return 0 }
        return try write { try BackfillMarks.writeMessages(messages, refreshExisting: refreshExisting, in: $0) }
    }

    public func markLiveChanges(accountID: AccountID, upserted: [String], deleted: [String]) throws {
        guard !upserted.isEmpty || !deleted.isEmpty else { return }
        try write { try BackfillMarks.markLive(accountID: accountID, upserted: upserted, deleted: deleted, in: $0) }
    }

    public func markBackfillSeen(accountID: AccountID, providerIDs: [String]) throws {
        guard !providerIDs.isEmpty else { return }
        try write { try BackfillMarks.markSeen(accountID: accountID, providerIDs: providerIDs, in: $0) }
    }

    @discardableResult
    public func finishBackfill(accountID: AccountID, sweepUnseen: Bool) throws -> Int {
        try write { try BackfillMarks.finish(accountID: accountID, sweepUnseen: sweepUnseen, in: $0) }
    }

    // MARK: Conversations

    public func conversations(_ query: ConversationQuery) throws -> [ConversationSummary] {
        try read { try ConversationTable.fetch(query, in: $0) }
    }

    public func observeConversations(
        _ query: ConversationQuery,
        onChange: @escaping @Sendable ([ConversationSummary]) -> Void
    ) -> StoreObservation {
        observeConversations(query, onChange: onChange, onError: { _ in })
    }

    public func observeConversations(
        _ query: ConversationQuery,
        onChange: @escaping @Sendable ([ConversationSummary]) -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) -> StoreObservation {
        // Identical rows are not delivered again: hydration rewrites a message's full-text row with every
        // body it saves, which invalidates a search without changing a single result.
        let observation = ValueObservation.tracking { db in try ConversationTable.fetch(query, in: db) }.removeDuplicates()
        // A full-text query over a large mailbox can take tens of milliseconds for a one-letter prefix, so a
        // search fetches its first page on a reader; the list keeps the rows it shows until it arrives.
        let isSearch = query.search != nil
        let cancellable = database.startObservation(
            observation,
            firstValueOnCallingThread: !isSearch,
            onError: { error in
                Self.reportObservationFailure(error)
                onError(error)
            },
            onChange: onChange
        )
        return StoreObservation { cancellable.cancel() }
    }

    public func observeConversation(
        _ id: ConversationID,
        onChange: @escaping @Sendable ([MessageMetadata]) -> Void
    ) -> StoreObservation {
        let observation = ValueObservation.tracking { db in try MessageTable.fetch(in: id, db: db) }
        let cancellable = database.startObservation(observation, firstValueOnCallingThread: true, onError: Self.reportObservationFailure, onChange: onChange)
        return StoreObservation { cancellable.cancel() }
    }

    public func unreadInboxCount(accountIDs: [AccountID]?) throws -> Int {
        try read { try ConversationTable.unreadInboxCount(accountIDs: accountIDs, in: $0) }
    }

    // MARK: Snoozes

    public func snoozes() throws -> [Snooze] {
        try read { try SnoozeTable.all($0) }
    }

    public func setSnoozes(_ changes: [Snooze.Change], enqueueing operations: [Operation], at now: Date) throws {
        guard !changes.isEmpty || !operations.isEmpty else { return }
        try write { db in
            for operation in operations { try OperationTable.enqueue(operation, in: db) }
            try SnoozeTable.set(changes, now: now, in: db)
        }
    }

    @discardableResult
    public func returnDueSnoozes(at now: Date, dueBy: [AccountID: Date], limit: Int,
                                 operations: (ConversationID, [MessageMetadata]) -> [Operation]) throws -> [ConversationID] {
        // The timer looks whenever the Mac wakes or the app comes forward, nearly always with nothing due; a read keeps
        // that from queueing behind a sync batch for the writer.
        guard limit > 0, try read({ try SnoozeTable.hasDue(at: now, in: $0) }) else { return [] }
        return try write { try SnoozeTable.returnDue(at: now, dueBy: dueBy, limit: limit, operations: operations, in: $0) }
    }

    public func observeSnoozes(onChange: @escaping @Sendable ([Snooze]) -> Void) -> StoreObservation {
        // It reads the summary rows too, which every sync batch writes; the snoozes are a handful of key lookups, and
        // only a changed list is delivered.
        let observation = ValueObservation.tracking { db in try SnoozeTable.all(db) }.removeDuplicates()
        let cancellable = database.startObservation(observation, firstValueOnCallingThread: true, onError: Self.reportObservationFailure,
                                                    onChange: onChange)
        return StoreObservation { cancellable.cancel() }
    }

    // GRDB error descriptions carry SQL with placeholders, never bound values, so nothing from a message can leak.
    private static let reportObservationFailure: @Sendable (Error) -> Void = { error in
        log.error("observation stopped: \(String(describing: error))")
    }

    // MARK: Operations

    public func enqueue(_ operation: Operation) throws {
        try write { try OperationTable.enqueue(operation, in: $0) }
    }

    public func enqueue(_ operations: [Operation]) throws {
        try write { db in
            for operation in operations { try OperationTable.enqueue(operation, in: db) }
        }
    }

    public func pendingOperations(accountID: AccountID, limit: Int) throws -> [Operation] {
        try read { try OperationTable.pending(accountID: accountID, limit: limit, in: $0) }
    }

    public func updateOperation(_ operation: Operation) throws {
        try write { try OperationTable.update(operation, in: $0) }
    }

    public func confirmOperation(id: String) throws {
        try write { try OperationTable.confirm(id: id, in: $0) }
    }

    public func deleteOperation(id: String) throws {
        try write { try OperationTable.delete(id: id, in: $0) }
    }

    public func acknowledgeFailedOperation(conversationID: ConversationID) throws {
        // The app calls this for nearly every conversation it opens and nearly none carry a mark. A WAL read
        // never waits behind a sync batch, so only a real mark takes the writer.
        guard try read({ try FailedOperationMarks.hasMark(conversationID, in: $0) }) else { return }
        try write { try FailedOperationMarks.acknowledge(conversationID, in: $0) }
    }

    @discardableResult
    public func pruneFailedOperations(accountID: AccountID, now: Date) throws -> Int {
        // Runs at the start of every outbox drain and nearly always finds nothing; the read keeps that case
        // from queueing behind a hydration batch for the writer.
        guard try read({ try OperationTable.hasExpiredFailures(accountID: accountID, now: now, in: $0) }) else { return 0 }
        return try write { try OperationTable.pruneFailed(accountID: accountID, now: now, in: $0) }
    }

    public func enqueueSend(_ send: PendingSend) throws {
        try write { try PendingSendTable.save(send, in: $0) }
    }

    public func pendingSends() throws -> [PendingSend] {
        try read { try PendingSendTable.all($0) }
    }

    public func pendingSendSummaries() throws -> [PendingSendSummary] {
        try read { try PendingSendTable.summaries($0) }
    }

    public func pendingSend(id: String) throws -> PendingSend? {
        try read { try PendingSendTable.send(id: id, in: $0) }
    }

    public func updateSend(_ send: PendingSendSummary) throws {
        try write { try PendingSendTable.updateState(send, in: $0) }
    }

    public func deleteSend(id: String) throws {
        try write { try PendingSendTable.delete(id: id, in: $0) }
    }

    public func observePendingSends(onChange: @escaping @Sendable ([PendingSendSummary]) -> Void) -> StoreObservation {
        let observation = ValueObservation.tracking { db in try PendingSendTable.summaries(db) }
        let cancellable = database.startObservation(observation, firstValueOnCallingThread: false, onError: Self.reportObservationFailure, onChange: onChange)
        return StoreObservation { cancellable.cancel() }
    }

    // MARK: Contacts

    public func suggestAddresses(prefix: String, limit: Int) throws -> [EmailAddress] {
        try read { try ContactTable.suggest(prefix: prefix, limit: limit, now: Date(), in: $0) }
    }

    // MARK: Maintenance

    public func optimize() throws {
        try write { try $0.execute(sql: "PRAGMA optimize") }
    }

    public func mergeFullTextIndex(pages: Int, startingOver: Bool) throws -> Bool {
        // FTS5's own 'optimize' rewrites the whole index in one statement, holding the writer for as long as that takes
        // on a large mailbox. 'merge' does the same work a bounded number of pages at a time: the first step, negative,
        // starts a merge of every b-tree; the later ones, positive, carry that merge on even when live writes add new
        // b-trees meanwhile. A step that changes fewer than two rows found nothing to merge (FTS5's documented test).
        let pages = max(1, pages)
        return try write { db in
            let before = db.totalChangesCount
            try db.execute(sql: "INSERT INTO message_fts(message_fts, rank) VALUES ('merge', ?)",
                           arguments: [startingOver ? -pages : pages])
            return db.totalChangesCount - before >= 2
        }
    }

    public func reclaimFreePages(upTo pages: Int) throws -> Int? {
        guard try autoVacuumMode() == 2 else { return nil }
        // A read first, so an idle moment with nothing free never takes the writer.
        guard pages > 0, try read({ try Self.freePages($0) }) > 0 else { return 0 }
        return try write { db in
            let before = try Self.freePages(db)
            try db.execute(sql: "PRAGMA incremental_vacuum(\(pages))")
            return before - (try Self.freePages(db))
        }
    }

    private static func freePages(_ db: Database) throws -> Int {
        try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
    }

    /// The file's `auto_vacuum`: 0 none, 1 full, 2 incremental. Fixed when the file was created.
    func autoVacuumMode() throws -> Int {
        try read { try Int.fetchOne($0, sql: "PRAGMA auto_vacuum") } ?? 0
    }

    // MARK: Diagnostics

    /// The file's pages and how many of them are free, for tests.
    func pageCounts() throws -> (pages: Int, free: Int) {
        try read { db in
            (pages: try Int.fetchOne(db, sql: "PRAGMA page_count") ?? 0, free: try Self.freePages(db))
        }
    }

    /// Calls `onCommit` after every committed transaction that changed `bodies`, for tests that count transactions.
    func observeBodyCommits(_ onCommit: @escaping @Sendable () -> Void) throws -> AnyDatabaseCancellable {
        guard let writer = database as? any DatabaseWriter else { throw StoreError.underlying("no database writer") }
        return DatabaseRegionObservation(tracking: Table("bodies")).start(in: writer, onError: { _ in }, onChange: { _ in onCommit() })
    }

    /// What an evicted body row still holds, for tests: whether it is marked, which source columns are left, the size
    /// of its rendered HTML and its plain text. Nil when the message has no body row.
    func bodyRowState(for id: MessageID) throws -> (evicted: Bool, hasHTML: Bool, hasText: Bool, renderedBytes: Int, plainText: String)? {
        try read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT evicted, html IS NOT NULL, text IS NOT NULL, length(rendered_html), plain_text FROM bodies
                WHERE account_id = ? AND provider_id = ?
                """, arguments: [id.accountID.rawValue, id.providerID]) else { return nil }
            return (evicted: row[0], hasHTML: row[1], hasText: row[2], renderedBytes: row[3], plainText: row[4])
        }
    }

    /// Checks the full-text index against the messages and bodies it was built from, throwing when they
    /// disagree. It walks the whole index, so it is for tests, not for the app's launch path.
    func verifyFullTextIndex() throws {
        try write { try FullTextIndex.verify($0) }
    }

    /// SQLite's plan for a sweep's candidate read, one line per step, so tests can pin it to its range.
    func evictionCandidatesPlan() throws -> [String] {
        try read { try BodyEviction.explainCandidates(in: $0) }
    }

    /// SQLite's plan for a list query, one line per step, so tests can pin the inbox to its index.
    func queryPlan(for query: ConversationQuery) throws -> [String] {
        try read { try ConversationTable.explain(query, in: $0) }
    }
}
