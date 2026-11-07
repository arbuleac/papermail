import Foundation

/// The `MailClient` the app talks to: one `AccountSyncer` (a live lane and a backfill lane) and one
/// `QuotaBudget` per account, a shared `SendRunner`, the attachment cache and the status feed, wired over the
/// ports. Every command writes the store first and only then nudges
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
        attachmentCacheDirectory: URL
    ) {
        self.store = store
        self.tokenStore = tokenStore
        self.tokenProvider = tokenProvider
        self.authenticator = authenticator
        self.sanitizer = sanitizer
        self.providerFactory = providerFactory
        self.tuning = tuning
        self.attachmentCache = AttachmentCache(root: attachmentCacheDirectory)
        self.sendRunner = SendRunner(store: store, registry: registry, claimLock: sendClaimLock, tuning: tuning)
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
        SyncLog.logger.info("engine stopped")
    }

    /// Stops and returns once every loop has finished, so another engine can safely take over the same store.
    public func stopAndWait() async {
        stop()
        for context in registry.all() {
            await context.syncer.stopAndWait()
        }
        await sendRunner.stopAndWait()
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

    /// Every live lane checks now; one parked for sign-in stays parked (`WakeReason.check`).
    public func checkForMail() {
        for context in registry.all() {
            context.syncer.wake(.check)
        }
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
        var byAccount: [AccountID: [MessageID]] = [:]
        var order: [AccountID] = []
        var seen: Set<MessageID> = []
        for id in messages where seen.insert(id).inserted {
            if byAccount[id.accountID] == nil { order.append(id.accountID) }
            byAccount[id.accountID, default: []].append(id)
        }
        for accountID in order {
            let operation = Operation(accountID: accountID, change: change, targets: byAccount[accountID] ?? [])
            try store.enqueue(operation)
            registry.context(for: accountID)?.syncer.wake(.operations)
        }
    }

    public func send(_ message: OutgoingMessage, undoWindow: TimeInterval) throws -> String {
        let pending = PendingSend(message: message, sendAfter: Date().addingTimeInterval(max(0, undoWindow)))
        try store.enqueueSend(pending)
        sendRunner.wake()
        return pending.id
    }

    public func cancelSend(id: String) throws -> Bool {
        try sendRunner.cancel(id: id)
    }

    // MARK: Fetches

    public func ensureBody(for message: MessageID) async throws -> StoredBody {
        if let stored = try store.body(for: message) { return stored }
        let context = try context(forAccountID: message.accountID)
        return try await context.hydrator.ensureBody(for: message)
    }

    public func attachmentData(for message: MessageID, attachmentID: String, expectedSize: Int,
                               progress: (@Sendable (Double) -> Void)?) async throws -> Data {
        let context = try context(forAccountID: message.accountID)
        return try await attachmentCache.data(for: message, attachmentID: attachmentID, expectedSize: expectedSize,
                                              provider: context.provider, budget: context.budget, progress: progress)
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
        let hydrator = Hydrator(accountID: account.id, store: store, provider: provider, sanitizer: sanitizer, tuning: tuning,
                                budget: budget)
        let runner = OperationRunner(accountID: account.id, store: store, provider: provider, tuning: tuning)
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
            isAppActive: { [weak self] in self?.isAppActive ?? true }
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
