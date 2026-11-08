import Foundation

/// The `MailClient` the app talks to: one `AccountSyncer` (a live lane and a backfill lane) and one
/// `QuotaBudget` per account, a shared `SendRunner` and `SnoozeRunner`, the attachment cache, the storage sweeper and the status feed,
/// wired over the ports. Every command writes the store first and only then nudges
/// the network side, so the UI never waits on a provider.
public final class MailEngine: MailClient, @unchecked Sendable {
    public let store: MailStoring

    private let tokenStore: TokenStore
    private let tokenProvider: AccessTokenProvider
    private let authenticator: AccountAuthenticator
    private let sanitizer: BodySanitizing
    private let providerFactory: @Sendable (Account) -> MailProvider
    private let tuning: SyncTuning
    private let registry = AccountRegistry()
    private let statusCenter = SyncStatusCenter()
    private let attachmentCache: AttachmentCache
    private let sendClaimLock = NSLock()
    private let sendRunner: SendRunner
    private let snoozeRunner: SnoozeRunner
    /// Wakes the snooze runner when the wall clock is set, which a wait slept on the continuous clock cannot see.
    private var clockObserver: NSObjectProtocol?
    private let sweeper: StorageSweeper
    private let storageFeed = StorageChangeFeed()
    /// The Keep mail window and the bodies kept whole for this run, read by the sweeper and the hydrators.
    private let keepMail = KeepMailState()
    private let stateLock = NSLock()
    private var running = false
    private var appActive = true

    public convenience init(
        store: MailStoring,
        tokenStore: TokenStore,
        tokenProvider: AccessTokenProvider,
        authenticator: AccountAuthenticator,
        sanitizer: BodySanitizing,
        providerFactory: @escaping @Sendable (Account) -> MailProvider,
        pollInterval: TimeInterval = 30,
        attachmentCacheDirectory: URL
    ) {
        self.init(
            store: store,
            tokenStore: tokenStore,
            tokenProvider: tokenProvider,
            authenticator: authenticator,
            sanitizer: sanitizer,
            providerFactory: providerFactory,
            tuning: SyncTuning(pollInterval: pollInterval),
            attachmentCacheDirectory: attachmentCacheDirectory
        )
    }

    init(
        store: MailStoring,
        tokenStore: TokenStore,
        tokenProvider: AccessTokenProvider,
        authenticator: AccountAuthenticator,
        sanitizer: BodySanitizing,
        providerFactory: @escaping @Sendable (Account) -> MailProvider,
        tuning: SyncTuning,
        attachmentCacheDirectory: URL,
        attachmentCacheCapacity: Int64 = AttachmentCache.capacityBytes,
        maintenance: MailStoreMaintenance? = nil
    ) {
        self.store = store
        self.tokenStore = tokenStore
        self.tokenProvider = tokenProvider
        self.authenticator = authenticator
        self.sanitizer = sanitizer
        self.providerFactory = providerFactory
        self.tuning = tuning
        self.attachmentCache = AttachmentCache(root: attachmentCacheDirectory, capacity: attachmentCacheCapacity)
        self.sendRunner = SendRunner(store: store, registry: registry, claimLock: sendClaimLock, tuning: tuning)
        // The runner reaches the lanes through the registry, not through `self`, so it keeps no engine alive. A due
        // snooze asks its account to check (`.check`, which leaves an account parked for sign-in parked) and returns
        // once that check has caught up.
        let registry = registry
        self.snoozeRunner = SnoozeRunner(store: store, clock: tuning.snoozeClock, onReturn: { accounts in
            for account in accounts { registry.context(for: account)?.syncer.wake(.operations) }
        }, requestCheck: { accounts in
            for account in accounts { registry.context(for: account)?.syncer.wake(.check) }
        })
        // The sweeper reads the window through the shared state, not through `self`, so it keeps no engine alive.
        let keepMail = keepMail
        let feed = storageFeed
        self.sweeper = StorageSweeper(store: store, maintenance: maintenance ?? (store as? MailStoreMaintenance), tuning: tuning,
                                      retention: { keepMail.retention }, kept: { keepMail.kept }, changed: { feed.publish() })
    }

    deinit {
        stop()
    }

    // MARK: Lifecycle

    public var isRunning: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return running
    }

    /// Loads the accounts from the store and starts each account's two lanes plus the send runner.
    public func start() {
        stateLock.lock()
        guard !running else { stateLock.unlock(); return }
        running = true
        stateLock.unlock()
        var accounts: [Account] = []
        do {
            accounts = try store.accounts()
        } catch {
            SyncLog.logger.error("engine: could not load accounts: \(String(describing: error), privacy: .private)")
        }
        for account in accounts {
            context(for: account).syncer.start()
        }
        sendRunner.start()
        // At launch it returns whatever fell due while the app was closed, as each account's first check catches up.
        snoozeRunner.start()
        let snoozeRunner = snoozeRunner
        let observer = NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: nil) { _ in
            snoozeRunner.wake()
        }
        stateLock.withLock { clockObserver = observer }
        // The attachment cache's size is unknown until measured; measured and trimmed now, off the main thread, a
        // download later only adds what it wrote.
        let cache = attachmentCache
        let feed = storageFeed
        Task(priority: .utility) {
            if await cache.trim() > 0 { feed.publish() }
        }
        SyncLog.logger.info("engine started with \(accounts.count, privacy: .public) accounts")
    }

    /// Cancels every loop. In-flight provider calls finish on their own; use `stopAndWait` to wait for them.
    public func stop() {
        stateLock.lock()
        guard running else { stateLock.unlock(); return }
        running = false
        stateLock.unlock()
        for context in registry.all() {
            context.syncer.stop()
            statusCenter.update(context.account.id) { status in
                status.phase = .paused
                status.message = nil
            }
        }
        sendRunner.stop()
        snoozeRunner.stop()
        if let observer = stateLock.withLock({ () -> NSObjectProtocol? in defer { clockObserver = nil }; return clockObserver }) {
            NotificationCenter.default.removeObserver(observer)
        }
        let sweeper = sweeper
        Task { await sweeper.stopAndWait() }
        SyncLog.logger.info("engine stopped")
    }

    /// Stops and returns once every loop has finished, so another engine can safely take over the same store.
    public func stopAndWait() async {
        stop()
        for context in registry.all() {
            await context.syncer.stopAndWait()
        }
        await sendRunner.stopAndWait()
        await snoozeRunner.stopAndWait()
        // After the lanes, which may have asked for a sweep on their way out; a step under way finishes first.
        await sweeper.stopAndWait()
    }

    // MARK: Storage

    /// Settings › General › Keep mail on this Mac (docs/ARCHITECTURE.md, "Storage bounds"). Narrowing the window
    /// sweeps at once while the engine runs (otherwise the launch sweep after the first live cycle does). Widening it,
    /// back to Everything included, evicts nothing more (a sweep under way reads the window before each batch, so it
    /// goes on to the new cutoff or stops) and fetches nothing back: those bodies return as their messages are opened.
    public func setMailRetention(_ retention: MailRetention) {
        stateLock.lock()
        let previous = keepMail.setRetention(retention)
        let isRunning = running
        stateLock.unlock()
        guard isRunning, retention.isNarrower(than: previous) else { return }
        let sweeper = sweeper
        Task { await sweeper.request([.evict, .reclaim]) }
    }

    /// The Keep mail window the engine sweeps to.
    public var mailRetention: MailRetention {
        keepMail.retention
    }

    /// Called on the main thread after a sweep evicted bodies, merged the full-text index or gave pages back, and after
    /// the attachment cache deleted files to stay under its cap: the moments the mailbox's size on disk changes by more
    /// than mail arriving. Settings measures the size again then.
    public func observeStorageChanges(onChange: @escaping @Sendable () -> Void) -> StoreObservation {
        storageFeed.observe(onChange)
    }

    /// Returns once no sweep is under way, for tests.
    func waitForStorageWork() async {
        await sweeper.waitUntilIdle()
    }

    /// The messages whose bodies stay whole for this run, for tests.
    var keptBodies: Set<MessageID> {
        keepMail.kept
    }

    // MARK: Accounts

    public func accounts() throws -> [Account] {
        try store.accounts()
    }

    public func addAccount(kind: ProviderKind) async throws -> Account {
        let (tokens, id, profile) = try await signIn(kind: kind, loginHint: nil)
        let existing = try store.accounts()
        if let known = existing.first(where: {
            $0.kind == kind && $0.email.caseInsensitiveCompare(profile.email) == .orderedSame
        }) {
            // Signing in to an account that is already here is how the user recovers from `needsReauth`:
            // keep the new tokens, drop the duplicate id, and let the existing syncer try again.
            try tokenStore.save(tokens, for: known.id)
            try? tokenStore.delete(for: id)
            registry.context(for: known.id)?.syncer.wake(.poll)
            SyncLog.logger.info("engine: refreshed tokens for existing account \(known.id.rawValue, privacy: .public)")
            return known
        }
        let account = Account(
            id: id,
            kind: kind,
            email: profile.email,
            displayName: profile.displayName,
            addedAt: Date(),
            inkSlot: AccountInkSlot.next(taken: existing.map(\.inkSlot))
        )
        try store.upsertAccount(account)
        let context = context(for: account)
        if isRunning { context.syncer.start() }
        SyncLog.logger.info("engine: added account \(id.rawValue, privacy: .public) (\(kind.rawValue, privacy: .public))")
        return account
    }

    public func reconnect(_ account: Account) async throws -> Account {
        let (tokens, id, profile) = try await signIn(kind: account.kind, loginHint: account.email)
        defer { try? tokenStore.delete(for: id) }
        guard profile.email.caseInsensitiveCompare(account.email) == .orderedSame else {
            throw AuthError.wrongAccount(expected: account.email, actual: profile.email)
        }
        try tokenStore.save(tokens, for: account.id)
        registry.context(for: account.id)?.syncer.wake(.poll)
        SyncLog.logger.info("engine: reconnected account \(account.id.rawValue, privacy: .public)")
        return account
    }

    /// Browser sign-in plus a profile read under a provisional id, whose tokens the caller keeps or drops.
    private func signIn(kind: ProviderKind, loginHint: String?) async throws -> (OAuthTokens, AccountID, AccountProfile) {
        let tokens = try await authenticator.signIn(kind: kind, loginHint: loginHint)
        let id = AccountID(UUID().uuidString)
        try tokenStore.save(tokens, for: id)
        let provisional = Account(id: id, kind: kind, email: "", displayName: "", addedAt: Date())
        do {
            return (tokens, id, try await providerFactory(provisional).profile())
        } catch {
            try? tokenStore.delete(for: id)
            throw error
        }
    }

    public func removeAccount(_ id: AccountID) async throws {
        if let context = registry.remove(id) {
            await context.syncer.stopAndWait()
            await context.hydrator.cancelAll()
        }
        statusCenter.remove(id)
        try tokenStore.delete(for: id)
        try store.deleteAccount(id)
        await attachmentCache.removeAll(for: id)
        SyncLog.logger.info("engine: removed account \(id.rawValue, privacy: .public)")
    }

    public func syncNow(accountID: AccountID?) {
        let targets: [AccountContext]
        if let accountID {
            targets = registry.context(for: accountID).map { [$0] } ?? []
        } else {
            targets = registry.all()
        }
        for context in targets {
            context.syncer.wake(.poll)
        }
    }

    /// Every live lane checks now; one parked for sign-in stays parked (`WakeReason.check`). The send runner looks at
    /// the outbox too: after the Mac slept, a send that fell due meanwhile goes now, whether or not its timer has fired;
    /// so does the snooze runner at the snoozes, which come back once their account's check has caught up.
    public func checkForMail() {
        for context in registry.all() {
            context.syncer.wake(.check)
        }
        sendRunner.wake()
        // And a snooze that fell due while the Mac slept returns now, whether or not its timer has fired.
        snoozeRunner.wake()
    }

    /// Recorded for the live lanes' poll interval; the lanes read it when they schedule their next check. Coming
    /// to the front also checks every account, so a wait booked at the background interval does not outlast it.
    public func setAppActive(_ isActive: Bool) {
        stateLock.lock()
        let wasActive = appActive
        appActive = isActive
        stateLock.unlock()
        guard isActive, !wasActive else { return }
        checkForMail()
    }

    /// Whether the app is frontmost, as last reported by `setAppActive`. Starts true: the engine starts with the app.
    var isAppActive: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return appActive
    }

    // MARK: Actions

    public func perform(_ change: MetadataChange, on conversation: ConversationID) throws {
        let ids = try store.messages(in: conversation).map(\.id)
        try perform(change, on: ids)
    }

    public func perform(_ change: MetadataChange, on messages: [MessageID]) throws {
        for operation in Self.operations(change, on: messages, at: Date()) {
            try store.enqueue(operation)
            registry.context(for: operation.accountID)?.syncer.wake(.operations)
        }
    }

    public func setSnoozes(_ changes: [Snooze.Change], performing steps: [MailActionRecord.Step]) throws {
        let now = tuning.snoozeClock.now()
        // A millisecond apart: the outbox replays by creation time, and an undo's steps (out of the Trash, then back to
        // the archive) must reach the provider in the order they were applied here.
        let operations = steps.enumerated().flatMap { index, step in
            Self.operations(step.change, on: step.targets, at: now.addingTimeInterval(Double(index) / 1_000))
        }
        try store.setSnoozes(changes, enqueueing: operations, at: now)
        var woken: Set<AccountID> = []
        for operation in operations where woken.insert(operation.accountID).inserted {
            registry.context(for: operation.accountID)?.syncer.wake(.operations)
        }
        snoozeRunner.wake()
    }

    /// One operation per account, in the order the accounts first appear: an operation targets one account's messages.
    private static func operations(_ change: MetadataChange, on messages: [MessageID], at now: Date) -> [Operation] {
        var byAccount: [AccountID: [MessageID]] = [:]
        var order: [AccountID] = []
        var seen: Set<MessageID> = []
        for id in messages where seen.insert(id).inserted {
            if byAccount[id.accountID] == nil { order.append(id.accountID) }
            byAccount[id.accountID, default: []].append(id)
        }
        return order.map { Operation(accountID: $0, change: change, targets: byAccount[$0] ?? [], createdAt: now) }
    }

    public func send(_ message: OutgoingMessage, undoWindow: TimeInterval) throws -> String {
        try sendRunner.enqueue(message, undoWindow: undoWindow)
    }

    public func cancelSend(id: String) throws -> Bool {
        try sendRunner.cancel(id: id)
    }

    // MARK: Fetches

    public func ensureBody(for message: MessageID) async throws -> StoredBody {
        if let stored = try store.body(for: message) { return stored }
        // Someone is opening it (the reader, a reply's quote). Fetched now, perhaps from outside the Keep mail window
        // after an eviction, it is kept whole until a later launch's sweep, so opening old mail never thrashes. Marked
        // before the fetch, so a backfill fetch this joins stores it whole too (one that read the window before the
        // mark is saved whole again by `Hydrator.ensureBody`).
        keepMail.keep([message])
        let context = try context(forAccountID: message.accountID)
        return try await context.hydrator.ensureBody(for: message)
    }

    public func keepBodies(of messages: [MessageID]) {
        keepMail.keep(messages)
    }

    public func attachmentData(for message: MessageID, attachmentID: String, expectedSize: Int,
                               progress: (@Sendable (Double) -> Void)?) async throws -> Data {
        let context = try context(forAccountID: message.accountID)
        let fetched = try await attachmentCache.data(for: message, attachmentID: attachmentID, expectedSize: expectedSize,
                                                     provider: context.provider, budget: context.budget, progress: progress)
        if fetched.trimmed { storageFeed.publish() }
        return fetched.data
    }

    public func observeStatus(onChange: @escaping @Sendable ([AccountSyncStatus]) -> Void) -> StoreObservation {
        statusCenter.observe(onChange: onChange)
    }

    // MARK: Contexts

    private func context(for account: Account) -> AccountContext {
        if let existing = registry.context(for: account.id) { return existing }
        let provider = providerFactory(account)
        // One budget per account, shared by both lanes and the on-demand body and attachment fetches, which count as
        // live spend.
        let budget = tuning.makeBudget(tuning.quota(provider))
        let keepMail = keepMail
        let hydrator = Hydrator(accountID: account.id, store: store, provider: provider, sanitizer: sanitizer, tuning: tuning,
                                budget: budget, evictionCutoff: { keepMail.evictionCutoff(for: $0) })
        let runner = OperationRunner(accountID: account.id, store: store, provider: provider, tuning: tuning)
        let sweeper = sweeper
        let snoozeRunner = snoozeRunner
        let id = account.id
        let syncer = AccountSyncer(
            accountID: account.id,
            store: store,
            provider: provider,
            hydrator: hydrator,
            runner: runner,
            statusCenter: statusCenter,
            tokenProvider: tokenProvider,
            tuning: tuning,
            budget: budget,
            isAppActive: { [weak self] in self?.isAppActive ?? true },
            firstLiveCycleEnded: { Task { await sweeper.liveCycleEnded() } },
            backfillEnded: { Task { await sweeper.backfillEnded() } },
            liveCheckStarted: { snoozeRunner.liveCheckStarted(id) },
            liveCheckCaughtUp: { snoozeRunner.liveCheckCaughtUp(id) }
        )
        let context = AccountContext(account: account, provider: provider, hydrator: hydrator, syncer: syncer, budget: budget)
        let registered = registry.insertIfAbsent(context)
        statusCenter.register(account.id)
        return registered
    }

    /// The context for an account id, built from the store when the engine has not met the account yet.
    private func context(forAccountID id: AccountID) throws -> AccountContext {
        if let existing = registry.context(for: id) { return existing }
        guard let account = try store.accounts().first(where: { $0.id == id }) else {
            throw StoreError.notFound
        }
        return context(for: account)
    }
}
