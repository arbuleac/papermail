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
    /// Sends the outbox's unsubscribe requests for every account; one-click ones run off the live cycle.
    private let unsubscriber: Unsubscriber
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
        self.unsubscriber = Unsubscriber(configuration: tuning.unsubscribeConfiguration)
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
        unsubscriber.cancelAll()
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
        await unsubscriber.waitForAll()
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

    public func addAccount(kind: ProviderKind, tenant: String?) async throws -> Account {
        let (tokens, id, profile) = try await signIn(kind: kind, loginHint: nil, tenant: tenant)
        let existing = try store.accounts()
        // A work account and a personal Microsoft account can share an address; they are different mailboxes.
        let type = MicrosoftAccountType(tenant: tokens.tenant)
        let tokenStore = tokenStore
        if let known = existing.first(where: {
            guard $0.kind == kind, $0.email.caseInsensitiveCompare(profile.email) == .orderedSame else { return false }
            guard let type, let knownType = MicrosoftAccountType(tenant: (try? tokenStore.tokens(for: $0.id))??.tenant) else { return true }
            return knownType == type
        }) {
            // Signing in to an account that is already here is how the user recovers from `needsReauth`:
            // keep the new tokens, drop the duplicate id, and let the existing syncer try again.
            try await tokenProvider.replaceTokens(for: known.id) { try tokenStore.save(tokens, for: known.id) }
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
        // Through the tenant the account was added through, so a work account is never answered by a personal one.
        let tenant = (try? tokenStore.tokens(for: account.id))??.tenant
        let (tokens, id, profile) = try await signIn(kind: account.kind, loginHint: account.email,
                                                     permissions: permissionsToAsk(for: account), tenant: tenant)
        defer { try? tokenStore.delete(for: id) }
        guard profile.email.caseInsensitiveCompare(account.email) == .orderedSame else {
            throw AuthError.wrongAccount(expected: account.email, actual: profile.email)
        }
        // Through the token provider: it may hold the old token, valid for up to an hour and without a scope this
        // sign-in added, and a refresh of the old grant may land at any moment of the save.
        let tokenStore = tokenStore
        try await tokenProvider.replaceTokens(for: account.id) { try tokenStore.save(tokens, for: account.id) }
        registry.context(for: account.id)?.syncer.wake(.poll)
        SyncLog.logger.info("engine: reconnected account \(account.id.rawValue, privacy: .public)")
        return account
    }

    /// What a reconnect asks for beyond mail: the permissions queued work waits for (an answered invitation), and those
    /// the account granted before, so signing in again never takes one away. Reading the old grant is a keychain read on
    /// the reconnect's own path, which already writes the new tokens; one that fails just leaves the old grant out.
    private func permissionsToAsk(for account: Account) -> Set<AccountPermission> {
        let waiting = statusCenter.status(for: account.id)?.permissionsNeeded ?? []
        let granted = OAuthEndpoints.permissions(grantedBy: (try? tokenStore.tokens(for: account.id))??.scope, kind: account.kind)
        return waiting.union(granted)
    }

    /// Browser sign-in plus a profile read under a provisional id, whose tokens the caller keeps or drops.
    private func signIn(kind: ProviderKind, loginHint: String?, permissions: Set<AccountPermission> = [],
                        tenant: String?) async throws -> (OAuthTokens, AccountID, AccountProfile) {
        let tokens = try await authenticator.signIn(kind: kind, loginHint: loginHint, permissions: permissions, tenant: tenant)
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

    public func setMuted(_ muted: Bool, conversations: [ConversationID], performing steps: [MailActionRecord.Step]) throws {
        let operations = Self.operations(of: steps, at: Date())
        try store.setMuted(muted, conversations: conversations, enqueueing: operations)
        wakeOutbox(for: operations)
    }

    public func setSenderRule(_ action: SenderRule.Action?, for address: String, accountID: AccountID,
                              performing steps: [MailActionRecord.Step]) throws {
        let now = Date()
        // A rule never spans accounts; a step on another account's mail is not this rule's to take.
        let operations = Self.operations(of: steps, at: now).filter { $0.accountID == accountID }
        try store.setSenderRule(action, for: address, accountID: accountID, enqueueing: operations, at: now)
        wakeOutbox(for: operations)
    }

    /// Steps a millisecond apart, as `setSnoozes` spaces them, so the outbox replays an undo's steps in their order.
    private static func operations(of steps: [MailActionRecord.Step], at now: Date) -> [Operation] {
        steps.enumerated().flatMap { index, step in
            operations(step.change, on: step.targets, at: now.addingTimeInterval(Double(index) / 1_000))
        }
    }

    private func wakeOutbox(for operations: [Operation]) {
        var woken: Set<AccountID> = []
        for operation in operations where woken.insert(operation.accountID).inserted {
            registry.context(for: operation.accountID)?.syncer.wake(.operations)
        }
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

    public func unsubscribe(_ method: UnsubscribeMethod, accountID: AccountID, archiving messages: [MessageID],
                            endingSnoozesOf snoozed: [ConversationID]) throws {
        var seen: Set<MessageID> = []
        var seenSnoozes: Set<ConversationID> = []
        // A conversation never spans accounts; anything else is not this request's to archive, or to bring out of Later.
        let targets = messages.filter { $0.accountID == accountID && seen.insert($0).inserted }
        let ended = snoozed.filter { $0.accountID == accountID && seenSnoozes.insert($0).inserted }
        let now = Date()
        var operations: [Operation] = []
        if !targets.isEmpty {
            operations.append(Operation(accountID: accountID, change: .archive, targets: targets, createdAt: now))
        }
        if method.isRequest {
            // No targets: it changes no message, so it never holds back, or waits behind, another operation on them.
            // A millisecond after the archive, so the outbox lists the two in the order the user asked for them.
            operations.append(Operation(accountID: accountID, change: .unsubscribe(method), targets: [],
                                        createdAt: now.addingTimeInterval(0.001)))
        }
        if !ended.isEmpty {
            // The snoozes end in the request's transaction, so the conversation never leaves Later without it queued.
            try store.setSnoozes(ended.map { Snooze.Change(conversationID: $0, until: nil) }, enqueueing: operations,
                                 at: tuning.snoozeClock.now())
            snoozeRunner.wake()
        } else {
            guard !operations.isEmpty else { return }
            try store.enqueue(operations)
        }
        if !operations.isEmpty { registry.context(for: accountID)?.syncer.wake(.operations) }
    }

    public func answerInvitation(_ response: InvitationResponse, to message: MessageID) throws {
        guard let metadata = try store.message(message), let invitation = try store.body(for: message)?.invitation else {
            throw StoreError.notFound
        }
        let account = try store.accounts().first { $0.id == message.accountID }
        guard let account else { throw StoreError.notFound }
        // Only the latest revision in the conversation is answered: an answer from an earlier one would repeat a SEQUENCE
        // and times the organizer replaced. The messages the reader shows, so the card never offers what this refuses.
        let shown = RenderPayloadBuilder.visibleMessages(try store.messages(in: metadata.conversationID))
        for other in shown where other.id != message {
            if let later = try store.body(for: other.id)?.invitation, later.supersedes(invitation) {
                throw StoreError.conflict("A later invitation replaces this one")
            }
        }
        guard let answer = InvitationAnswer(response, to: invitation, accountEmail: account.email,
                                            accountName: account.displayName.isEmpty ? nil : account.displayName,
                                            previous: metadata.invitationReply) else {
            throw StoreError.conflict("This invitation can't be answered")
        }
        // The same answer again changes nothing and sends nothing.
        guard metadata.invitationReply != response else { return }
        try perform(.answerInvitation(answer), on: [message])
    }

    public func send(_ message: OutgoingMessage, undoWindow: TimeInterval) throws -> String {
        try sendRunner.enqueue(message, undoWindow: undoWindow)
    }

    public func cancelSend(id: String) throws -> Bool {
        try sendRunner.cancel(id: id)
    }

    // MARK: Fetches

    /// The accounts in scope are searched two at a time (`ServerSearcher`); one the engine has not met yet gets its
    /// context now, as `ensureBody` does, so a search works before `start()`.
    public func searchServer(for text: String, accountIDs: [AccountID]?) async throws -> ServerSearchResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ServerSearchResult() }
        let stored = try store.accounts()
        let accounts = accountIDs.map { ids in ids.compactMap { id in stored.first { $0.id == id } } } ?? stored
        let signposter = SyncLog.signposter
        let interval = signposter.beginInterval("sync.serverSearch", id: signposter.makeSignpostID())
        defer { signposter.endInterval("sync.serverSearch", interval) }
        let searcher = ServerSearcher(store: store, limit: tuning.serverSearchLimit, concurrency: tuning.serverSearchConcurrency)
        let result = try await searcher.search(trimmed, in: accounts.map { context(for: $0) })
        SyncLog.logger.info("""
            server search: \(accounts.count, privacy: .public) accounts, \(result.downloaded, privacy: .public) messages new, \
            \(result.failedAccounts.count, privacy: .public) failed
            """)
        return result
    }

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
        let runner = OperationRunner(accountID: account.id, store: store, provider: provider, tuning: tuning,
                                     unsubscriber: unsubscriber)
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
