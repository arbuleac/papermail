import Foundation
import GRDB
import os

/// The production `MailStoring`: one SQLite file in WAL mode behind a GRDB `DatabasePool`, with the schema from
/// docs/DATA-MODEL.md and the semantics of `InMemoryMailStore`.
///
/// Every mutating call is one transaction, and every call that touches messages or operations recomputes the
/// summary rows of the affected conversations with aggregate SQL before it commits, so the list queries are
/// single indexed selects over `conversations` and observers see each transaction exactly once.
public final class SQLiteMailStore: MailStoring, Sendable {
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
        var configuration = Configuration()
        // Readers never wait on the writer in WAL mode; the timeout only matters if another process holds the file.
        configuration.busyMode = .timeout(5)
        let pool = try DatabasePool(path: path, configuration: configuration)
        try Self.restrictPermissions(of: path)
        try MailSchema.migrator().migrate(pool)
        database = pool
    }

    /// A private in-memory database with the same schema and semantics, for tests and previews.
    public static func inMemory() throws -> SQLiteMailStore {
        let queue = try DatabaseQueue(path: ":memory:")
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

    // MARK: Conversations

    public func conversations(_ query: ConversationQuery) throws -> [ConversationSummary] {
        try read { try ConversationTable.fetch(query, in: $0) }
    }

    public func observeConversations(
        _ query: ConversationQuery,
        onChange: @escaping @Sendable ([ConversationSummary]) -> Void
    ) -> StoreObservation {
        // Identical rows are not delivered again: hydration rewrites a message's full-text row with every
        // body it saves, which invalidates a search without changing a single result.
        let observation = ValueObservation.tracking { db in try ConversationTable.fetch(query, in: db) }.removeDuplicates()
        // A full-text query over a large mailbox can take tens of milliseconds for a one-letter prefix, so a
        // search fetches its first page on a reader; the list keeps the rows it shows until it arrives.
        let isSearch = !(query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let cancellable = database.startObservation(
            observation,
            firstValueOnCallingThread: !isSearch,
            onError: Self.reportObservationFailure,
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

    // GRDB error descriptions carry SQL with placeholders, never bound values, so nothing from a message can leak.
    private static let reportObservationFailure: @Sendable (Error) -> Void = { error in
        log.error("observation stopped: \(String(describing: error))")
    }

    // MARK: Operations

    public func enqueue(_ operation: Operation) throws {
        try write { try OperationTable.enqueue(operation, in: $0) }
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

    public func updateSend(_ send: PendingSend) throws {
        try write { try PendingSendTable.save(send, in: $0) }
    }

    public func deleteSend(id: String) throws {
        try write { try PendingSendTable.delete(id: id, in: $0) }
    }

    // MARK: Contacts

    public func suggestAddresses(prefix: String, limit: Int) throws -> [EmailAddress] {
        try read { try ContactTable.suggest(prefix: prefix, limit: limit, now: Date(), in: $0) }
    }

    // MARK: Diagnostics

    /// Checks the full-text index against the messages and bodies it was built from, throwing when they
    /// disagree. It walks the whole index, so it is for tests, not for the app's launch path.
    func verifyFullTextIndex() throws {
        try write { try FullTextIndex.verify($0) }
    }

    /// SQLite's plan for a list query, one line per step, so tests can pin the inbox to its index.
    func queryPlan(for query: ConversationQuery) throws -> [String] {
        try read { try ConversationTable.explain(query, in: $0) }
    }
}
