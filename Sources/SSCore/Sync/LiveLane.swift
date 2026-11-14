import Foundation

/// The live lane of one account: owns the change cursor, replays the outbox, and polls for changes every few
/// seconds while the app is frontmost (`activePollInterval`) and every `pollInterval` otherwise.
///
/// It never waits for the backfill lane or its units. An account without a cursor gets one from the
/// newest page (the head) and the older mail is left to the backfill lane, so new mail arrives within one
/// interval of the first page, however large the mailbox. A rejected cursor is replaced the same way and the
/// backfill lane reconciles the stored mail behind it; nothing is wiped.
///
/// The lane sleeps between cycles on its `SyncWaker`, so `syncNow` and user actions wake it at once. A user
/// action runs the outbox alone; the change poll keeps its own deadline, which only a full cycle moves.
/// Throttling and network failures back off exponentially, and neither that schedule nor a provider's retry time
/// keeps it waiting past `liveBackoffCap`. A throttle on any of its requests (a page, the outbox, a body) also pauses
/// the backfill through the budget (`QuotaBudget.liveThrottled`), since both lanes spend one per-user quota; this lane
/// never waits on that pause. What it can put off, it fits to its own share of the quota
/// (`QuotaBudget.liveHeadroom`): after a page that left more to fetch or was heavy, the next page (of the same poll
/// or the next) waits until that share covers what the last one cost, and bodies after a poll are prefetched only
/// while it has room, so neither a large catch-up nor a busy mailbox whose every poll brings a heavy page spends
/// past the provider's limit and gets the user's own requests refused with it. What new mail needs at once does
/// not wait on the share: the first page of a poll after a light one, and the newest bodies after a head page.
/// An invalid token or a denied keychain parks the account, both lanes, in `needsReauth` until the next
/// `syncNow` (an automatic check, `.check`, leaves it parked); at launch the backfill lane waits for this lane's
/// first cycle, so the token is tried once before both lanes use it.
actor LiveLane {
    private enum CycleOutcome {
        /// `pollAfter`: the poll stopped short to stay within the live share and goes on after that long.
        case completed(nextAttemptAt: Date?, pollAfter: TimeInterval?)
        case throttled(retryAfter: TimeInterval?)
        case failed
        case needsReauth
        case reset
        case cancelled
    }

    private enum PollResult {
        case polled
        /// Pages remain, or the share is spent; the poll goes on after this long.
        case deferred(TimeInterval)
        case reset
    }

    /// What a run of change pages wrote, and whether it stopped short to stay within the live share.
    private struct PolledChanges {
        /// Messages new to the store, or back from Spam, and not deleted since: the only ones whose bodies are
        /// prefetched.
        var arrived: [MessageMetadata]
        var deferredFor: TimeInterval?
    }

    static let signInMessage = "Sign in again to keep syncing"
    static let keychainMessage = "Keychain access was denied; reconnect or allow SuperSparrow to read its tokens"
    /// The UI's Slow state reads this phrase.
    static let rateLimitedMessage = "Rate limited; retrying shortly"

    let accountID: AccountID
    private let store: MailStoring
    private let provider: MailProvider
    private let hydrator: Hydrator
    private let runner: OperationRunner
    private let statusCenter: SyncStatusCenter
    private let tokenProvider: AccessTokenProvider
    private let tuning: SyncTuning
    private let budget: QuotaBudget
    private let link: LaneLink
    private let isAppActive: @Sendable () -> Bool
    /// Told once, after this lane's first cycle: the moment the engine's per-launch storage sweep waits for.
    private let firstCycleEnded: @Sendable () -> Void
    /// Told as each full cycle begins, and when one ends with its poll caught up: the snooze runner holds a due return
    /// until a check that began after its time has brought in what came meanwhile (`SnoozeRunner`).
    private let checkStarted: @Sendable () -> Void
    private let checkCaughtUp: @Sendable () -> Void
    private var reportedFirstCycle = false
    private var phase: AccountSyncPhase = .idle
    private var consecutiveFailures = 0
    private var consecutiveResets = 0
    /// When the next full cycle is due; nil means "as soon as the loop runs". Outbox-only cycles leave it alone.
    /// On the clock the waker sleeps by, so setting the Mac's clock back cannot postpone a poll by the step.
    private var nextPollAt: ContinuousClock.Instant?
    /// What the next changes page is expected to cost while a run of dear pages goes on: the last page's cost when
    /// it said `hasMore` (a catch-up) or was heavy (`heavyPageShare`; a busy mailbox, whose next poll is likely as
    /// dear). Nil after a light page that said there is no more. Only while it is set does a page wait for the live
    /// share; it outlives the poll, so the next poll's first page waits too.
    private var runPageCost: Double?
    /// The provider call under way, for the throttle log.
    private var currentCall = "changes"
    /// The wait timer and the clock can disagree by a hair when the timer fires exactly at the deadline.
    private static let pollDueTolerance: TimeInterval = 0.01
    /// A changes page dearer than this part of the live allowance makes the next page wait for the share to cover
    /// it, even when it said there was no more: in a busy mailbox (a bulk action elsewhere, applied in stages) every
    /// poll brings one such page, and polls that never waited would spend several times the share. A tenth is about
    /// what the share earns in one active poll interval, and above a steady poll or a few new messages (2 and 22
    /// Gmail units, three Graph requests), so those never wait.
    private static let heavyPageShare = 0.1

    init(
        accountID: AccountID,
        store: MailStoring,
        provider: MailProvider,
        hydrator: Hydrator,
        runner: OperationRunner,
        statusCenter: SyncStatusCenter,
        tokenProvider: AccessTokenProvider,
        tuning: SyncTuning,
        budget: QuotaBudget,
        link: LaneLink,
        isAppActive: @escaping @Sendable () -> Bool,
        firstCycleEnded: @escaping @Sendable () -> Void = {},
        checkStarted: @escaping @Sendable () -> Void = {},
        checkCaughtUp: @escaping @Sendable () -> Void = {}
    ) {
        self.accountID = accountID
        self.store = store
        self.provider = provider
        self.hydrator = hydrator
        self.runner = runner
        self.statusCenter = statusCenter
        self.tokenProvider = tokenProvider
        self.tuning = tuning
        self.budget = budget
        self.link = link
        self.isAppActive = isAppActive
        self.firstCycleEnded = firstCycleEnded
        self.checkStarted = checkStarted
        self.checkCaughtUp = checkCaughtUp
    }

    // MARK: Loop

    func run() async {
        let id = accountID.rawValue
        SyncLog.logger.info("live lane started for \(id, privacy: .public)")
        var reasons: Set<WakeReason> = [.poll]
        cycles: while !Task.isCancelled {
            if let message = link.takeParkRequest() {
                // The backfill lane's request was refused for the token this lane uses too.
                setPhase(.needsReauth, message: message)
                nextPollAt = nil
            }
            if phase == .needsReauth {
                // Nothing moves until the user signs in again or explicitly asks for a sync; an automatic check
                // (`.check`) does not count as asking.
                guard reasons.contains(.poll) else {
                    reasons = await link.liveWaker.wait(timeout: nil)
                    continue
                }
                await tokenProvider.invalidateAccessToken(for: accountID)
            }
            // A user action only needs the outbox. The poll keeps its deadline, so a stream of actions cannot
            // push it back forever, and an outbox cycle during a failure backoff leaves that backoff in place.
            let requested = reasons.contains(.poll) || reasons.contains(.check)
            let full = requested || pollIsDue
            let outcome = await runCycle(full: full, requested: requested)
            if Task.isCancelled { break }
            if !reportedFirstCycle {
                // Whatever the outcome: the sweep is local, and offline or parked it is as useful.
                reportedFirstCycle = true
                firstCycleEnded()
            }
            let timeout: TimeInterval?
            switch outcome {
            case .completed(let nextAttemptAt, let pollAfter):
                if full {
                    consecutiveFailures = 0
                    consecutiveResets = 0
                    // A poll held back for the live share looks again by the next interval at the latest; the look
                    // is local, and the share may have come back sooner than planned (the clock moved, less spent).
                    nextPollAt = .now + .seconds(min(pollInterval, pollAfter ?? pollInterval))
                }
                link.unpark()
                var delay = nextPollAt.map(Self.seconds(until:)) ?? pollInterval
                if let nextAttemptAt { delay = min(delay, Self.seconds(until: nextAttemptAt)) }
                timeout = delay
            case .throttled(let retryAfter):
                link.liveCycleEnded()
                consecutiveFailures += 1
                // A provider's retry time is honoured up to the cap: asking again costs one change request, and a
                // time hours away is more often a skewed Mac clock or a misread body than advice to wait that long.
                let delay = Backoff.throttleDelay(
                    retryAfter: retryAfter, attempt: consecutiveFailures, base: tuning.backoffBase, cap: backoffCap
                )
                timeout = schedulePoll(after: min(delay, backoffCap))
                reportRetry(after: timeout)
            case .failed:
                link.liveCycleEnded()
                consecutiveFailures += 1
                timeout = schedulePoll(after: backoffDelay(consecutiveFailures))
                reportRetry(after: timeout)
            case .needsReauth:
                link.park()
                nextPollAt = nil
                timeout = nil
            case .reset:
                link.liveCycleEnded()
                consecutiveResets += 1
                // One reset is routine (expired history): poll from the fresh cursor at once. Repeated ones mean
                // the provider keeps rejecting cursors it just handed out.
                if consecutiveResets == 1 {
                    reasons = [.poll]
                    continue cycles
                }
                setPhase(.idle)
                timeout = schedulePoll(after: backoffDelay(consecutiveResets))
            case .cancelled:
                break cycles
            }
            reasons = await link.liveWaker.wait(timeout: timeout)
        }
        setPhase(.paused, force: true)
        SyncLog.logger.info("live lane stopped for \(id, privacy: .public)")
    }

    /// The interval to the next routine check: short while the user is looking at the app.
    private var pollInterval: TimeInterval {
        isAppActive() ? tuning.activePollInterval : tuning.pollInterval
    }

    private var backoffCap: TimeInterval {
        min(tuning.backoffCap, tuning.liveBackoffCap)
    }

    private var pollIsDue: Bool {
        guard let nextPollAt else { return true }
        return Self.seconds(until: nextPollAt) <= Self.pollDueTolerance
    }

    /// Books the next full cycle `delay` seconds out and returns that delay for the wait.
    private func schedulePoll(after delay: TimeInterval) -> TimeInterval {
        nextPollAt = .now + .seconds(delay)
        return delay
    }

    private static func seconds(until instant: ContinuousClock.Instant) -> TimeInterval {
        let remaining = ContinuousClock.now.duration(to: instant).components
        return max(0, TimeInterval(remaining.seconds) + TimeInterval(remaining.attoseconds) * 1e-18)
    }

    /// The outbox's next retry is a stored wall-clock time.
    private static func seconds(until date: Date) -> TimeInterval {
        max(0, date.timeIntervalSinceNow)
    }

    private func runCycle(full: Bool, requested: Bool) async -> CycleOutcome {
        if full { checkStarted() }
        do {
            if try store.syncCursor(for: accountID) == nil, try !adoptCheckpointCursor(), full {
                try await fetchHead()
            }
            let nextAttemptAt = try await drainOutbox()
            var pollAfter: TimeInterval?
            if full {
                switch try await poll(requested: requested) {
                case .reset: return .reset
                case .deferred(let after): pollAfter = after
                case .polled: break
                }
            }
            // A poll held back has not caught up: "checked" would claim it had.
            let caughtUp = full && pollAfter == nil
            setPhase(.idle, markSuccess: caughtUp)
            if caughtUp { checkCaughtUp() }
            return .completed(nextAttemptAt: nextAttemptAt, pollAfter: pollAfter)
        } catch is CancellationError {
            return .cancelled
        } catch let error as ProviderError {
            return await handle(error)
        } catch let error as AuthError where error.isKeychainDenial {
            // macOS asks for the keychain password on every read the user has not allowed (each rebuild of an
            // ad hoc signed app counts as a new app). Retrying on a backoff would bring the prompt back again
            // and again; the account waits for Reconnect or Sync Now instead, like a revoked token.
            setPhase(.needsReauth, message: Self.keychainMessage)
            SyncLog.logger.error("keychain read denied for \(self.accountID.rawValue, privacy: .public)")
            return .needsReauth
        } catch {
            let description = SyncErrorDescription.describe(error)
            setPhase(.error, message: description)
            SyncLog.logger.error("sync failed for \(self.accountID.rawValue, privacy: .public): \(description, privacy: .private)")
            return .failed
        }
    }

    private func handle(_ error: ProviderError) async -> CycleOutcome {
        let id = accountID.rawValue
        switch error {
        case .unauthorized:
            setPhase(.needsReauth, message: Self.signInMessage)
            SyncLog.logger.error("provider rejected the token for \(id, privacy: .public)")
            return .needsReauth
        case .throttled(let retryAfter):
            // Before the cycle ends: at launch that end is what lets the backfill start, and its first request must
            // already find the pause.
            await budget.liveThrottled(retryAfter: retryAfter)
            setPhase(.paused, message: Self.rateLimitedMessage)
            SyncLog.logger.notice("live lane throttled on \(self.currentCall, privacy: .public) for \(id, privacy: .public), retry after \(retryAfter ?? -1, privacy: .public) s")
            return .throttled(retryAfter: retryAfter)
        case .cancelled:
            return .cancelled
        default:
            // A reset is handled where the poll meets it; one here (a head page) is a provider failure like any other.
            let description = SyncErrorDescription.describe(error)
            setPhase(.error, message: description)
            SyncLog.logger.error("sync failed for \(id, privacy: .public): \(description, privacy: .private)")
            return .failed
        }
    }

    // MARK: Cursor

    /// A download the single-loop engine left in progress (or a crash between a head page and its cursor) kept
    /// the cursor captured before its first page. Polling from it now brings in everything since then, and the
    /// backfill lane carries on from the saved page. Local: no request.
    private func adoptCheckpointCursor() throws -> Bool {
        guard let state = try store.bootstrapState(for: accountID),
              let cursor = state.checkpoint.changeCursor, !cursor.isEmpty else { return false }
        try store.setSyncCursor(cursor, for: accountID)
        let pages = state.pagesDone
        let complete = state.isComplete
        SyncLog.logger.notice("adopted the saved change cursor for \(self.accountID.rawValue, privacy: .public) after \(pages, privacy: .public) pages (download complete: \(complete, privacy: .public))")
        link.backfillWaker.signal(.poll)
        return true
    }

    /// The newest page, with the cursor captured before it: rows to show at once and a cursor to poll from. The
    /// rest of the mailbox is the backfill lane's.
    private func fetchHead() async throws {
        // Before the rows land, so the notifier counts the account as in its first sync while they do.
        setPhase(.bootstrapping, progress: 0)
        let page = try await replacingBackfill { () async throws -> BootstrapPage in
            let (page, cursor) = try await fetchFreshHead()
            // Marks of any earlier backfill would misdirect the new one.
            try store.finishBackfill(accountID: accountID, sweepUnseen: false)
            // Before the rows: from here a crash or a failed write leaves a state whose cursor predates them, which
            // the next cycle adopts, so polling covers every head row (even one newer mail has pushed off the head,
            // which the backfill would skip as stored), and whose listing starts again from the top.
            try store.setBootstrapState(Self.listingFromTheTop(page, cursor: cursor, reconciling: false), for: accountID)
            try store.upsertMessages(page.messages)
            var state = BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: page.messages.count,
                                       isComplete: page.nextPage == nil, estimatedTotal: page.estimatedTotal)
            // The cursor stays in the checkpoint until the backfill completes, so a crash between this write and
            // the next leaves a state the next launch adopts the cursor from.
            state.checkpoint = BootstrapCheckpoint(providerPage: page.nextPage, changeCursor: cursor)
            try store.setBootstrapState(state, for: accountID)
            try store.setSyncCursor(cursor, for: accountID)
            return page
        }
        setPhase(.bootstrapping, progress: page.messages.count, total: page.estimatedTotal)
        let count = page.messages.count
        let more = page.nextPage != nil
        SyncLog.logger.info("head page stored for \(self.accountID.rawValue, privacy: .public): \(count, privacy: .public) messages, older mail left to the backfill: \(more, privacy: .public)")
        try await hydrateNewest(page.messages, afterHead: true)
    }

    /// Runs `body` with the backfill lane fenced off: a page it fetched for the backfill being replaced can no
    /// longer be written, and it looks again (and finds the new backfill) once `body` ends, however it ends.
    private func replacingBackfill<T>(_ body: () async throws -> T) async rethrows -> T {
        link.beginReplacingBackfill()
        defer { link.endReplacingBackfill() }
        return try await body()
    }

    /// The newest page and the cursor the provider captured before it, recorded as live spend. Touches nothing in
    /// the store: whatever replaces the backfill starts only once the head is in hand.
    private func fetchFreshHead() async throws -> (BootstrapPage, String) {
        currentCall = "head"
        let page = try await provider.bootstrap(page: nil, limit: tuning.bootstrapPageSize)
        try Task.checkCancellation()
        guard let cursor = page.changeCursor, !cursor.isEmpty else {
            throw ProviderError.decoding("bootstrap returned no change cursor")
        }
        // A new cursor starts a new run of changes.
        runPageCost = nil
        await budget.recordLive(headPageCost(page))
        return (page, cursor)
    }

    /// What a head page cost: the requests the provider says it sent where it is charged per request (Graph: the
    /// system folder lookups, the first steps of its folder walk and the listing), otherwise the listing call plus
    /// its metadata.
    private func headPageCost(_ page: BootstrapPage) -> Double {
        let quota = budget.quota
        guard let requests = page.requestCount else { return pageCost(quota.listCost, messages: page.messages.count) }
        return Double(max(0, requests)) * quota.listCost
    }

    /// A state for the backfill that `head` starts, before anything of it is written: nowhere to resume from, so
    /// a backfill that finds it lists the mailbox again from the top, and `cursor` (which predates the head) for
    /// the next launch to adopt.
    private static func listingFromTheTop(_ head: BootstrapPage, cursor: String, reconciling: Bool) -> BootstrapState {
        var state = BootstrapState(startedAt: Date(), estimatedTotal: head.estimatedTotal, reconciling: reconciling ? true : nil)
        state.checkpoint = BootstrapCheckpoint(providerPage: nil, changeCursor: cursor)
        return state
    }

    /// What a head or changes page cost: the call, plus metadata per message where the provider fetches it by id
    /// (Gmail) rather than carrying it in the page (Graph).
    private func pageCost(_ callCost: Double, messages: Int) -> Double {
        let quota = budget.quota
        return callCost + (quota.inlineMetadata ? 0 : quota.metadataCostPerMessage * Double(messages))
    }

    // MARK: Outbox

    private func drainOutbox() async throws -> Date? {
        let outcome = await runner.drain()
        // Recorded on every drain, so the ask goes away as soon as the work it waited for can go out.
        statusCenter.update(accountID) { $0.permissionsNeeded = outcome.permissionsNeeded }
        if outcome.needsReauth { throw ProviderError.unauthorized }
        // The operations wait on their own schedule and the cycle goes on to poll; the backfill pauses, since the
        // outbox spends the same quota.
        if let throttle = outcome.throttle { await budget.liveThrottled(retryAfter: throttle.retryAfter) }
        return outcome.nextAttemptAt
    }

    // MARK: Poll

    private func poll(requested: Bool) async throws -> PollResult {
        guard let cursor = try store.syncCursor(for: accountID) else { return .polled }
        // Only a check someone asked for says so: the routine one every few seconds would make the status flicker.
        if requested { setPhase(.syncing) }
        let signposter = SyncLog.signposter
        let interval = signposter.beginInterval("sync.poll", id: signposter.makeSignpostID())
        let polled: PolledChanges
        do {
            guard let changes = try await pollChanges(from: cursor) else {
                signposter.endInterval("sync.poll", interval)
                return .reset
            }
            polled = changes
        } catch {
            signposter.endInterval("sync.poll", interval)
            throw error
        }
        signposter.endInterval("sync.poll", interval)
        try await hydrateNewest(polled.arrived)
        return polled.deferredFor.map(PollResult.deferred) ?? .polled
    }

    /// Applies change pages until the provider has no more or the live share runs out, saving the cursor after
    /// each. Returns what arrived, or nil when the cursor was rejected and a reconcile took its place.
    private func pollChanges(from start: String) async throws -> PolledChanges? {
        var arrived: [MessageID: MessageMetadata] = [:]
        do {
            return try await pollChanges(from: start, arrived: &arrived)
        } catch {
            // Pages already written are on screen, but this poll will not reach `hydrateNewest` and the next one
            // starts after them: their bodies are the backfill lane's now.
            if !arrived.isEmpty { link.backfillWaker.signal(.poll) }
            throw error
        }
    }

    private func pollChanges(from start: String, arrived: inout [MessageID: MessageMetadata]) async throws -> PolledChanges? {
        var cursor = start
        var upserted = 0
        var deleted = 0
        var deferredFor: TimeInterval?
        while true {
            try Task.checkCancellation()
            // Only a page after a dear one waits, for the share to cover what that one cost (Gmail fetches metadata
            // for every message a page names). After a light page the next poll's first page always goes, whatever
            // the share owes: opened bodies count against it, and a single new message or Sync Now must not sit out
            // the minute a long conversation's bodies cost.
            if let expected = runPageCost {
                let wait = await budget.liveWait(for: expected)
                if wait > 0 {
                    deferredFor = wait
                    let id = accountID.rawValue
                    SyncLog.logger.notice("live lane holds back its next changes page for \(id, privacy: .public) for \(wait, privacy: .public) s to stay within its share of the quota")
                    break
                }
            }
            currentCall = "changes"
            let page: ChangesPage
            do {
                page = try await provider.changes(since: cursor, limit: tuning.changesPageSize)
            } catch ProviderError.resetRequired {
                try await reconcileAfterReset()
                return nil
            }
            try Task.checkCancellation()
            let cost = changesPageCost(page)
            await budget.recordLive(cost)
            runPageCost = page.hasMore || cost > budget.liveCapacity * Self.heavyPageShare ? cost : nil
            let deletedIDs = page.deletedIDs.map { MessageID(accountID: accountID, providerID: $0) }
            // Settled before the page lands: an operation the provider has now reported on must not be
            // re-applied on top of that report (pending operations win) on its way out.
            settleUncertainOperations(observed: Set(page.upserts.map(\.id)).union(deletedIDs))
            let new = page.upserts.filter(arrives)
            if !page.upserts.isEmpty || !deletedIDs.isEmpty, try backfillIsRunning() {
                // Marked before the write, in its own transaction, so a backfill page fetched before this change
                // can never land between the write and its mark (docs/DATA-MODEL.md, "Backfill marks").
                try store.markLiveChanges(accountID: accountID, upserted: page.upserts.map(\.id.providerID),
                                          deleted: page.deletedIDs)
            }
            if !page.upserts.isEmpty { try store.upsertMessages(page.upserts) }
            if !deletedIDs.isEmpty { try store.deleteMessages(deletedIDs) }
            for message in new { arrived[message.id] = message }
            for id in deletedIDs { arrived[id] = nil }
            upserted += page.upserts.count
            deleted += deletedIDs.count
            cursor = page.cursor
            try store.setSyncCursor(cursor, for: accountID)
            if !page.hasMore { break }
        }
        SyncLog.logger.debug("poll for \(self.accountID.rawValue, privacy: .public): \(upserted, privacy: .public) upserts, \(deleted, privacy: .public) deletes")
        return PolledChanges(arrived: Array(arrived.values), deferredFor: deferredFor)
    }

    /// What a changes page cost: the requests the provider says it sent where it is charged per request (Graph: a
    /// delta GET per folder and a `$batch` part per removal looked up, up to a hundred or more a call), otherwise
    /// the call plus its metadata.
    private func changesPageCost(_ page: ChangesPage) -> Double {
        let quota = budget.quota
        guard let requests = page.requestCount else { return pageCost(quota.changesCost, messages: page.upserts.count) }
        return Double(max(0, requests)) * quota.changesCost
    }

    /// Whether an upsert counts as mail that arrived, whose body is prefetched; looked up before the write. Mail new
    /// to the store does, and so does a stored message leaving Spam, whose body neither lane fetched while it sat
    /// there and which the idle backfill would leave for minutes. Any other stored message whose labels or folder
    /// changed does not: the backfill fetches its body with the rest.
    private func arrives(_ message: MessageMetadata) -> Bool {
        guard let stored = try? store.message(message.id) else { return true }
        return stored.roles.contains(.spam) && !message.roles.contains(.spam)
    }

    /// A backfill is running or about to: its pages must not undo what this lane writes meanwhile.
    private func backfillIsRunning() throws -> Bool {
        guard let state = try store.bootstrapState(for: accountID) else { return false }
        return !state.isComplete
    }

    /// The provider rejected the cursor (Gmail history expired, a Graph delta token gone). Instead of wiping the
    /// mailbox: take a fresh cursor with a new head page and let a reconciling backfill list everything again
    /// behind the live lane, refreshing what is stored and finally removing what the provider no longer lists.
    private func reconcileAfterReset() async throws {
        let id = accountID.rawValue
        let head = try await replacingBackfill { () async throws -> BootstrapPage in
            // Nothing is touched until the head is in hand. A reset that fails before (a throttle, the network, a
            // quit) leaves the backfill it would have replaced as it was, marks and all; had the marks gone, an
            // interrupted reconcile would resume at its saved page and sweep everything it listed before.
            let (head, cursor) = try await fetchFreshHead()
            // Then the old state goes, before its marks: a write that fails or a crash from here on leaves a
            // reconcile that lists everything again from the top before it sweeps, never one with half its marks.
            try store.setBootstrapState(Self.listingFromTheTop(head, cursor: cursor, reconciling: true), for: accountID)
            // The old backfill's marks end before the new one records any: `finishBackfill` returns first.
            try store.finishBackfill(accountID: accountID, sweepUnseen: false)
            try store.upsertMessages(head.messages)
            try store.markBackfillSeen(accountID: accountID, providerIDs: head.messages.map(\.id.providerID))
            let complete = head.nextPage == nil
            var swept = 0
            if complete {
                // The head was the whole mailbox, so what it did not list is gone. Swept before the state says
                // complete: a crash in between leaves the old cursor, which the next poll rejects again.
                swept = try await removeLostTargets(listed: Set(head.messages.map(\.id.providerID)))
                swept += try store.finishBackfill(accountID: accountID, sweepUnseen: true)
            }
            var state = BootstrapState(startedAt: Date(), pagesDone: 1, messagesSeen: head.messages.count,
                                       isComplete: complete, estimatedTotal: head.estimatedTotal, reconciling: true)
            state.checkpoint = BootstrapCheckpoint(providerPage: head.nextPage, changeCursor: cursor)
            try store.setBootstrapState(state, for: accountID)
            try store.setSyncCursor(cursor, for: accountID)
            SyncLog.logger.notice("change cursor rejected for \(id, privacy: .public); kept local mail, took a fresh cursor and \(complete ? "reconciled at once, removing \(swept)" : "reconciles behind the live lane", privacy: .public)")
            return head
        }
        try await hydrateNewest(head.messages, afterHead: true)
    }

    /// Stored messages a live operation targets that the head did not list and the provider no longer has
    /// (`LostTargets`): deleted before the sweep, which would keep them for good. Returns how many went.
    private func removeLostTargets(listed: Set<String>) async throws -> Int {
        let candidates = try LostTargets.candidates(store: store, accountID: accountID, listed: listed,
                                                    limit: tuning.pendingOperationsFetchLimit)
        guard !candidates.isEmpty else { return 0 }
        currentCall = "metadata"
        let quota = budget.quota
        let lost = try await LostTargets.lost(candidates, chunk: tuning.backfillMetadataChunk) { ids in
            let lookup = try await provider.lookUpMetadata(for: ids)
            await budget.recordLive(quota.metadataCostPerMessage * Double(ids.count))
            return lookup
        }
        if !lost.isEmpty { try store.deleteMessages(lost.map { MessageID(accountID: accountID, providerID: $0) }) }
        return lost.count
    }

    /// An uncertain operation is kept so local state wins until the provider's view of its targets is known.
    /// Once a poll has reported those targets and the operation is old enough for any in-flight request to
    /// have landed, the provider's state is the truth: the row goes before that state is written. It is
    /// deleted, not confirmed, because it may never have landed, so it settles no failure mark.
    ///
    /// An invitation's answer is never settled this way: it is a mail and a calendar call, which no report of the
    /// message's labels and flags shows, so deleting it would drop an answer that never went out while the card
    /// still shows it chosen. It retries until it is confirmed or given up, and a give-up puts the previous one back.
    private func settleUncertainOperations(observed: Set<MessageID>) {
        guard !observed.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-tuning.uncertainSettleAge)
        let operations = (try? store.pendingOperations(accountID: accountID, limit: tuning.pendingOperationsFetchLimit)) ?? []
        for operation in operations where operation.status == .uncertain && operation.createdAt < cutoff
            && OperationKind(operation.change) != .answerInvitation {
            guard operation.targets.contains(where: observed.contains) else { continue }
            try? store.deleteOperation(id: operation.id)
        }
    }

    // MARK: Hydration

    /// Fetches the bodies of the newest of `messages` that lack one, up to `liveHydrationLimit` and as many as the
    /// live share has room for, so new mail opens without a wait. The rows are already visible, so a failure here
    /// never fails the cycle: a rejected token parks the account, anything else is left to the backfill lane, as
    /// are bodies beyond the limit or the room, and spam, which the backfill skips too.
    ///
    /// After a head page (`afterHead`) the room is not asked: on Gmail the head alone costs the whole share (2,005
    /// of 2,000 units), so it would leave none, yet these are the bodies a new account opens first. Gmail took
    /// about 5,000 units within 12 s without refusing, and the head with 20 bodies is 3,205.
    private func hydrateNewest(_ messages: [MessageMetadata], afterHead: Bool = false) async throws {
        guard !messages.isEmpty else { return }
        let limit = afterHead ? tuning.liveHydrationLimit : min(tuning.liveHydrationLimit, await affordableBodies())
        var targets: [MessageID] = []
        var more = false
        for message in messages.sorted(by: { $0.date > $1.date }) where !message.roles.contains(.spam) {
            let missing: Bool
            do {
                missing = try store.body(for: message.id) == nil
            } catch {
                continue
            }
            guard missing else { continue }
            if targets.count >= limit {
                more = true
                break
            }
            targets.append(message.id)
        }
        if more { link.handOffBodies() }
        guard !targets.isEmpty else { return }
        let outcome = await hydrator.hydrateLive(targets)
        if let blocking = outcome.blocking, Self.refusesAccess(blocking) { throw blocking }
        if outcome.failed > 0 {
            let failed = outcome.failed
            SyncLog.logger.notice("live hydration for \(self.accountID.rawValue, privacy: .public): \(failed, privacy: .public) bodies failed; the backfill lane retries them")
            link.handOffBodies()
        }
    }

    /// Bodies the live share can pay for now. After a large page that is few or none; the paced path fetches them.
    private func affordableBodies() async -> Int {
        let headroom = await budget.liveHeadroom
        let cost = budget.quota.bodyCost
        guard headroom.isFinite, cost > 0 else { return .max }
        return Int(max(0, headroom) / cost)
    }

    /// A refused token or a denied keychain: the account waits for the user, whichever path met it.
    private static func refusesAccess(_ error: Error) -> Bool {
        if case .unauthorized? = error as? ProviderError { return true }
        return (error as? AuthError)?.isKeychainDenial ?? false
    }

    // MARK: Status

    private func backoffDelay(_ attempt: Int) -> TimeInterval {
        Backoff.delay(attempt: attempt, base: tuning.backoffBase, cap: backoffCap)
    }

    /// The failed or throttled account says when it tries again (“Retrying in 30 s”, §5.40); the next cycle's
    /// first phase change clears it.
    private func reportRetry(after delay: TimeInterval?) {
        guard let delay, !Task.isCancelled else { return }
        let at = Date().addingTimeInterval(delay)
        statusCenter.update(accountID) { $0.retryAt = at }
    }

    /// The live lane's phase. The backfill fields belong to the backfill lane and are never touched here.
    private func setPhase(
        _ newPhase: AccountSyncPhase,
        message: String? = nil,
        progress: Int? = nil,
        total: Int? = nil,
        markSuccess: Bool = false,
        force: Bool = false
    ) {
        // A loop that was just cancelled must not overwrite the "paused" the engine reports on stop.
        guard force || !Task.isCancelled else { return }
        phase = newPhase
        statusCenter.update(accountID) { status in
            status.phase = newPhase
            status.message = message
            status.retryAt = nil
            if let progress {
                status.bootstrapProgress = progress
            } else if newPhase != .bootstrapping {
                status.bootstrapProgress = nil
            }
            if let total {
                status.bootstrapTotal = total
            } else if newPhase != .bootstrapping {
                status.bootstrapTotal = nil
            }
            if markSuccess { status.lastSuccessfulSyncAt = Date() }
        }
    }
}
