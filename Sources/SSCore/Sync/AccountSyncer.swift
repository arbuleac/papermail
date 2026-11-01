import Foundation

/// Drives one account: bootstrap once, then replay the outbox, poll for changes and hydrate bodies, forever.
///
/// The loop sleeps between cycles on a `SyncWaker`, so `syncNow` and user actions wake it at once. A user
/// action runs the outbox alone; the change poll keeps its own deadline, which only a full cycle moves.
/// Provider errors set policy here: throttling and network failures back off exponentially (capped at five
/// minutes), an invalid token parks the account in `needsReauth` until the next `syncNow`, and a stale cursor
/// wipes the account's local mail and bootstraps again.
actor AccountSyncer {
    private enum CycleOutcome {
        case completed(nextAttemptAt: Date?)
        case throttled(retryAfter: TimeInterval?)
        case failed
        case needsReauth
        case reset
        case cancelled
    }

    let accountID: AccountID
    private let store: MailStoring
    private let provider: MailProvider
    private let hydrator: Hydrator
    private let runner: OperationRunner
    private let statusCenter: SyncStatusCenter
    private let tokenProvider: AccessTokenProvider
    private let tuning: SyncTuning
    private let waker = SyncWaker()
    private let loop = LoopHandle()
    private var phase: AccountSyncPhase = .idle
    private var consecutiveFailures = 0
    private var consecutiveResets = 0
    /// When the next full cycle is due; nil means "as soon as the loop runs". Outbox-only cycles leave it alone.
    private var nextPollAt: Date?
    /// The wait timer and `Date()` can disagree by a hair when the timer fires exactly at the deadline.
    private static let pollDueTolerance: TimeInterval = 0.01

    init(
        accountID: AccountID,
        store: MailStoring,
        provider: MailProvider,
        hydrator: Hydrator,
        runner: OperationRunner,
        statusCenter: SyncStatusCenter,
        tokenProvider: AccessTokenProvider,
        tuning: SyncTuning
    ) {
        self.accountID = accountID
        self.store = store
        self.provider = provider
        self.hydrator = hydrator
        self.runner = runner
        self.statusCenter = statusCenter
        self.tokenProvider = tokenProvider
        self.tuning = tuning
    }

    nonisolated var isRunning: Bool { loop.isRunning }

    nonisolated func start() {
        loop.start { [self] in await self.runLoop() }
    }

    nonisolated func stop() {
        loop.cancel()
    }

    nonisolated func stopAndWait() async {
        await loop.cancelAndWait()
    }

    nonisolated func wake(_ reason: WakeReason) {
        waker.signal(reason)
    }

    // MARK: Loop

    private func runLoop() async {
        let id = accountID.rawValue
        SyncLog.logger.info("syncer started for \(id, privacy: .public)")
        var reasons: Set<WakeReason> = [.poll]
        cycles: while !Task.isCancelled {
            if phase == .needsReauth {
                // Nothing moves until the user signs in again or explicitly asks for a sync.
                guard reasons.contains(.poll) else {
                    reasons = await waker.wait(timeout: nil)
                    continue
                }
                await tokenProvider.invalidateAccessToken(for: accountID)
            }
            // A user action only needs the outbox. The poll keeps its deadline, so a stream of actions cannot
            // push it back forever, and an outbox cycle during a failure backoff leaves that backoff in place.
            let full = reasons.contains(.poll) || pollIsDue
            let outcome = await runCycle(full: full)
            if Task.isCancelled { break }
            let timeout: TimeInterval?
            switch outcome {
            case .completed(let nextAttemptAt):
                if full {
                    consecutiveFailures = 0
                    consecutiveResets = 0
                    nextPollAt = Date().addingTimeInterval(tuning.pollInterval)
                }
                var delay = nextPollAt.map(Self.seconds(until:)) ?? tuning.pollInterval
                if let nextAttemptAt { delay = min(delay, Self.seconds(until: nextAttemptAt)) }
                timeout = delay
            case .throttled(let retryAfter):
                consecutiveFailures += 1
                timeout = schedulePoll(after: Backoff.throttleDelay(
                    retryAfter: retryAfter, attempt: consecutiveFailures, base: tuning.backoffBase, cap: tuning.backoffCap
                ))
            case .failed:
                consecutiveFailures += 1
                timeout = schedulePoll(after: backoffDelay(consecutiveFailures))
            case .needsReauth:
                nextPollAt = nil
                timeout = nil
            case .reset:
                consecutiveResets += 1
                // One reset is routine (expired history); repeated ones mean the provider keeps rejecting us.
                if consecutiveResets == 1 {
                    reasons = [.poll]
                    continue cycles
                }
                timeout = schedulePoll(after: backoffDelay(consecutiveResets))
            case .cancelled:
                break cycles
            }
            reasons = await waker.wait(timeout: timeout)
        }
        setPhase(.paused, force: true)
        SyncLog.logger.info("syncer stopped for \(id, privacy: .public)")
    }

    private var pollIsDue: Bool {
        guard let nextPollAt else { return true }
        return nextPollAt.timeIntervalSinceNow <= Self.pollDueTolerance
    }

    /// Books the next full cycle `delay` seconds out and returns that delay for the wait.
    private func schedulePoll(after delay: TimeInterval) -> TimeInterval {
        nextPollAt = Date().addingTimeInterval(delay)
        return delay
    }

    private static func seconds(until date: Date) -> TimeInterval {
        max(0, date.timeIntervalSinceNow)
    }

    private func runCycle(full: Bool) async -> CycleOutcome {
        do {
            if try store.syncCursor(for: accountID) == nil {
                try await bootstrap()
            }
            let nextAttemptAt = try await drainOutbox()
            if full {
                try await poll()
                try await hydrate(phase: .hydrating)
            }
            setPhase(.idle, markSuccess: full)
            return .completed(nextAttemptAt: nextAttemptAt)
        } catch is CancellationError {
            return .cancelled
        } catch let error as ProviderError {
            return handle(error)
        } catch {
            let description = SyncErrorDescription.describe(error)
            setPhase(.error, message: description)
            SyncLog.logger.error("sync failed for \(self.accountID.rawValue, privacy: .public): \(description, privacy: .private)")
            return .failed
        }
    }

    private func handle(_ error: ProviderError) -> CycleOutcome {
        let id = accountID.rawValue
        switch error {
        case .unauthorized:
            setPhase(.needsReauth, message: "Sign in again to keep syncing")
            SyncLog.logger.error("provider rejected the token for \(id, privacy: .public)")
            return .needsReauth
        case .throttled(let retryAfter):
            setPhase(.paused, message: "Rate limited; retrying shortly")
            SyncLog.logger.notice("throttled for \(id, privacy: .public), retry after \(retryAfter ?? -1, privacy: .public)")
            return .throttled(retryAfter: retryAfter)
        case .resetRequired:
            do {
                try store.wipeMailData(for: accountID)
            } catch {
                setPhase(.error, message: SyncErrorDescription.describe(error))
                return .failed
            }
            setPhase(.bootstrapping, progress: 0)
            SyncLog.logger.notice("cursor rejected for \(id, privacy: .public); local mail wiped, bootstrapping again")
            return .reset
        case .cancelled:
            return .cancelled
        default:
            let description = SyncErrorDescription.describe(error)
            setPhase(.error, message: description)
            SyncLog.logger.error("sync failed for \(id, privacy: .public): \(description, privacy: .private)")
            return .failed
        }
    }

    // MARK: Phases

    private func bootstrap() async throws {
        var state = try store.bootstrapState(for: accountID) ?? BootstrapState(startedAt: Date())
        var checkpoint = state.checkpoint
        if state.isComplete || (checkpoint.providerPage != nil && checkpoint.changeCursor == nil) {
            // "Complete" while the account has no cursor cannot be trusted, and a resume point without the
            // cursor captured on the first page could never yield a gap-free poll; both start over.
            state = BootstrapState(startedAt: Date())
            checkpoint = BootstrapCheckpoint()
        }
        setPhase(.bootstrapping, progress: state.messagesSeen)
        let id = accountID.rawValue
        let resuming = checkpoint.providerPage != nil
        SyncLog.logger.info("bootstrap \(resuming ? "resuming" : "starting", privacy: .public) for \(id, privacy: .public) after \(state.pagesDone, privacy: .public) pages")
        while true {
            try Task.checkCancellation()
            let page = try await provider.bootstrap(page: checkpoint.providerPage, limit: tuning.bootstrapPageSize)
            try Task.checkCancellation()
            if checkpoint.providerPage == nil {
                guard let cursor = page.changeCursor, !cursor.isEmpty else {
                    throw ProviderError.decoding("bootstrap returned no change cursor")
                }
                checkpoint.changeCursor = cursor
            }
            try store.upsertMessages(page.messages)
            state.pagesDone += 1
            state.messagesSeen += page.messages.count
            checkpoint.providerPage = page.nextPage
            if page.nextPage == nil {
                // The cursor goes first: once it is in place a crash cannot leave the account without one, and
                // the next cycle simply polls from a point that predates the enumeration.
                try store.setSyncCursor(checkpoint.changeCursor, for: accountID)
                state.isComplete = true
                state.checkpoint = BootstrapCheckpoint()
                try store.setBootstrapState(state, for: accountID)
                setPhase(.bootstrapping, progress: state.messagesSeen)
                SyncLog.logger.info("bootstrap complete for \(id, privacy: .public): \(state.messagesSeen, privacy: .public) messages in \(state.pagesDone, privacy: .public) pages")
                break
            }
            state.checkpoint = checkpoint
            try store.setBootstrapState(state, for: accountID)
            setPhase(.bootstrapping, progress: state.messagesSeen)
            // User actions and the newest bodies do not wait for a 100,000-message enumeration to finish.
            _ = try await drainOutbox()
            try await hydrate(phase: .bootstrapping)
        }
        try await hydrate(phase: .bootstrapping)
    }

    private func drainOutbox() async throws -> Date? {
        let outcome = await runner.drain()
        if outcome.needsReauth { throw ProviderError.unauthorized }
        return outcome.nextAttemptAt
    }

    private func poll() async throws {
        guard var cursor = try store.syncCursor(for: accountID) else { return }
        setPhase(.syncing)
        var upserted = 0
        var deleted = 0
        while true {
            try Task.checkCancellation()
            let page = try await provider.changes(since: cursor, limit: tuning.changesPageSize)
            try Task.checkCancellation()
            let deletedIDs = page.deletedIDs.map { MessageID(accountID: accountID, providerID: $0) }
            // Settled before the page lands: an operation the provider has now reported on must not be
            // re-applied on top of that report (pending operations win) on its way out.
            settleUncertainOperations(observed: Set(page.upserts.map(\.id)).union(deletedIDs))
            if !page.upserts.isEmpty { try store.upsertMessages(page.upserts) }
            if !deletedIDs.isEmpty { try store.deleteMessages(deletedIDs) }
            upserted += page.upserts.count
            deleted += deletedIDs.count
            cursor = page.cursor
            try store.setSyncCursor(cursor, for: accountID)
            if !page.hasMore { break }
        }
        SyncLog.logger.debug("poll for \(self.accountID.rawValue, privacy: .public): \(upserted, privacy: .public) upserts, \(deleted, privacy: .public) deletes")
    }

    /// An uncertain operation is kept so local state wins until the provider's view of its targets is known.
    /// Once a poll has reported those targets and the operation is old enough for any in-flight request to
    /// have landed, the provider's state is the truth: the row goes before that state is written.
    private func settleUncertainOperations(observed: Set<MessageID>) {
        guard !observed.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-tuning.uncertainSettleAge)
        let operations = (try? store.pendingOperations(accountID: accountID, limit: tuning.pendingOperationsFetchLimit)) ?? []
        for operation in operations where operation.status == .uncertain && operation.createdAt < cutoff {
            guard operation.targets.contains(where: observed.contains) else { continue }
            try? store.deleteOperation(id: operation.id)
        }
    }

    private func hydrate(phase: AccountSyncPhase) async throws {
        setPhase(phase)
        let outcome = await hydrator.hydrateBatch()
        if let blocking = outcome.blocking { throw blocking }
    }

    private func backoffDelay(_ attempt: Int) -> TimeInterval {
        Backoff.delay(attempt: attempt, base: tuning.backoffBase, cap: tuning.backoffCap)
    }

    private func setPhase(
        _ newPhase: AccountSyncPhase,
        message: String? = nil,
        progress: Int? = nil,
        markSuccess: Bool = false,
        force: Bool = false
    ) {
        // A loop that was just cancelled must not overwrite the "paused" the engine reports on stop.
        guard force || !Task.isCancelled else { return }
        phase = newPhase
        statusCenter.update(accountID) { status in
            status.phase = newPhase
            status.message = message
            if let progress {
                status.bootstrapProgress = progress
            } else if newPhase != .bootstrapping {
                status.bootstrapProgress = nil
            }
            if markSuccess { status.lastSuccessfulSyncAt = Date() }
        }
    }
}
