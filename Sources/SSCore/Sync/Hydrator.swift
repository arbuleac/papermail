import Foundation

/// Fetches the bodies the store is missing for one account, sanitizes each once and stores it render-ready.
///
/// Two paths share one in-flight table, so a body being hydrated and a body being opened never fetch twice:
/// the live path fetches the bodies of mail a poll just brought, a few at a time, and only records what it
/// spent; the paced path serves the backfill lane, and every fetch on it first takes a backfill slot and its
/// units from the account's `QuotaBudget`. `ensureBody` serves the UI's on-demand fetches as live spend.
actor Hydrator {
    struct Outcome: Sendable {
        var fetched = 0
        /// Paced fetches that found the body stored or being fetched by the time their slot and units came free.
        var skipped = 0
        var failed = 0
        /// Failures that were not set aside for `hydrationRetryDelay` (network errors), so the next batch would ask
        /// for the same bodies again.
        var retryable = 0
        /// An error that stops hydration for the whole account (a refused token, a denied keychain, a throttle);
        /// the lane decides what to do.
        var blocking: Error?
        /// The paced batch stopped early because its caller said to (the account was parked meanwhile).
        var halted = false
    }

    /// A paced fetch found its caller no longer wants it.
    private struct Halted: Error {}

    nonisolated let budget: QuotaBudget
    private let accountID: AccountID
    private let store: MailStoring
    private let provider: MailProvider
    private let sanitizer: BodySanitizing
    private let tuning: SyncTuning
    private var inFlight: [MessageID: Task<StoredBody, Error>] = [:]
    /// Bodies whose fetch failed for a reason a retry will not fix soon (decoding, not found, server errors)
    /// wait here so they do not occupy the whole batch every time.
    private var retryAfter: [MessageID: Date] = [:]
    /// Set once no stored body of this account lacks design facts; new bodies always carry them.
    private var designFactsComplete = false

    init(
        accountID: AccountID,
        store: MailStoring,
        provider: MailProvider,
        sanitizer: BodySanitizing,
        tuning: SyncTuning,
        budget: QuotaBudget = QuotaBudget(quota: .unlimited)
    ) {
        self.accountID = accountID
        self.store = store
        self.provider = provider
        self.sanitizer = sanitizer
        self.tuning = tuning
        self.budget = budget
    }

    /// The live lane's path: fetches these bodies now, `liveHydrationConcurrency` at a time, and records each
    /// fetch as live spend. Never waits on the budget: the rows are already on screen and the user is likely to
    /// open the newest of them.
    func hydrateLive(_ ids: [MessageID]) async -> Outcome {
        pruneRetryAfter()
        var seen: Set<MessageID> = []
        let wanted = ids.filter { retryAfter[$0] == nil && seen.insert($0).inserted }
        guard !wanted.isEmpty else { return Outcome() }
        let outcome = await fetch(wanted, concurrency: tuning.liveHydrationConcurrency) { [self] id in
            _ = try await fetchTask(for: id, chargesLive: true).value
            return true
        }
        log("live", outcome)
        return outcome
    }

    /// The backfill lane's path: one batch of missing bodies, newest inbox messages first. Each fetch takes a
    /// backfill slot and `bodyCost` units first, so the batch keeps to the budget's pace; at most
    /// `min(hydrationConcurrency, maxBackfillConcurrency)` run at once. A throttle comes back as `blocking`.
    /// `proceed` is asked before each fetch spends units and again before it sends: once it says no, the batch
    /// stops and comes back `halted`.
    func hydratePaced(while proceed: @escaping @Sendable () -> Bool = { true }) async -> Outcome {
        pruneRetryAfter()
        let candidates: [MessageID]
        do {
            // Ask for a little more than one batch so deferred failures do not crowd out fetchable bodies.
            let limit = tuning.hydrationBatchSize + min(retryAfter.count, tuning.hydrationBatchSize * 9)
            candidates = try store.messageIDsMissingBodies(accountID: accountID, limit: limit)
        } catch {
            SyncLog.logger.error("hydration: store read failed: \(String(describing: error), privacy: .private)")
            return Outcome()
        }
        let ids = Array(candidates.filter { retryAfter[$0] == nil && inFlight[$0] == nil }.prefix(tuning.hydrationBatchSize))
        guard !ids.isEmpty else { return Outcome() }
        let budget = budget
        let cost = budget.quota.bodyCost
        let concurrency = min(tuning.hydrationConcurrency, budget.quota.maxBackfillConcurrency)
        let outcome = await fetch(ids, concurrency: concurrency) { [self] id in
            try await budget.acquireBackfillSlot()
            let fetched: Bool
            do {
                fetched = try await pacedFetch(id, cost: cost, proceed: proceed)
            } catch {
                await budget.releaseBackfillSlot()
                throw error
            }
            await budget.releaseBackfillSlot()
            if fetched { await budget.backfillSucceeded() }
            return fetched
        }
        log("paced", outcome)
        return outcome
    }

    /// One fetch of a paced batch, its slot already held. False when there was nothing left to fetch.
    private func pacedFetch(_ id: MessageID, cost: Double, proceed: @Sendable () -> Bool) async throws -> Bool {
        guard proceed() else { throw Halted() }
        // The batch was picked before its slots and units came free. A body stored meanwhile (the live lane's
        // newest, a message the user opened) or still being fetched costs the backfill nothing.
        if inFlight[id] != nil || (try? store.body(for: id)) != nil { return false }
        try await budget.acquireBackfill(cost)
        // The wait for units can be long, and the account may have been parked for sign-in during it.
        guard proceed() else { throw Halted() }
        _ = try await fetchTask(for: id, chargesLive: false).value
        return true
    }

    /// Works out the design facts (§8.5) of up to one batch of bodies stored before v3 kept them, from the
    /// source the store still holds, and writes them in one transaction. Without them the reader treats every
    /// such body as styled with its own colours, so in Dark mode even plain mail took the colours notice and
    /// never the reading page. Sanitizing again here keeps the rule that bodies are parsed at sync time, never
    /// when opened, and needs no network. Returns how many were written.
    @discardableResult
    func backfillDesignFacts() async -> Int {
        guard !designFactsComplete else { return 0 }
        let ids: [MessageID]
        do {
            ids = try store.messageIDsMissingDesignFacts(accountID: accountID, limit: tuning.designFactsBatchSize)
        } catch {
            SyncLog.logger.error("design facts: store read failed: \(String(describing: error), privacy: .private)")
            return 0
        }
        guard !ids.isEmpty else {
            designFactsComplete = true
            return 0
        }
        let store = store
        let sanitizer = sanitizer
        let written = await Task.detached(priority: .background) { () -> Int in
            var facts: [MessageID: BodyDesignFacts] = [:]
            for id in ids {
                if Task.isCancelled { break }
                guard let stored = try? store.body(for: id) else {
                    // Unreadable: the reader's own assumption, written down so the row leaves the queue.
                    facts[id] = .unknown
                    continue
                }
                let sanitized = sanitizer.sanitize(stored.body, messageID: id)
                facts[id] = BodyDesignFacts(typesetting: sanitized.typesetting, declaresColors: sanitized.declaresColors,
                                            coveredByNewYork: sanitized.coveredByNewYork)
            }
            do {
                try store.saveDesignFacts(facts)
            } catch {
                SyncLog.logger.error("design facts: store write failed: \(String(describing: error), privacy: .private)")
                return 0
            }
            return facts.count
        }.value
        SyncLog.logger.debug("design facts: wrote \(written, privacy: .public)")
        return written
    }

    /// The stored body, fetched and sanitized first when missing. Concurrent callers share one fetch, which
    /// counts as live spend: the user is waiting for it.
    func ensureBody(for id: MessageID) async throws -> StoredBody {
        if let stored = try store.body(for: id) { return stored }
        return try await fetchTask(for: id, chargesLive: true).value
    }

    func cancelAll() {
        for task in inFlight.values { task.cancel() }
        inFlight = [:]
    }

    // MARK: Fetching

    /// Runs `fetchOne` over `ids` with at most `concurrency` in flight, and stops starting new ones after an
    /// error that blocks the whole account or once a paced fetch is halted. `fetchOne` returns whether it fetched.
    private func fetch(
        _ ids: [MessageID],
        concurrency: Int,
        _ fetchOne: @escaping @Sendable (MessageID) async throws -> Bool
    ) async -> Outcome {
        var outcome = Outcome()
        await withTaskGroup(of: (MessageID, Result<Bool, Error>).self) { group in
            var iterator = ids.makeIterator()
            var stopLaunching = false
            for _ in 0..<max(1, concurrency) {
                guard let id = iterator.next() else { break }
                Self.add(id, fetchOne, to: &group)
            }
            for await (id, result) in group {
                switch result {
                case .success(let fetched):
                    if fetched {
                        outcome.fetched += 1
                    } else {
                        outcome.skipped += 1
                    }
                case .failure(let error) where error is Halted:
                    outcome.halted = true
                    stopLaunching = true
                case .failure(let error):
                    outcome.failed += 1
                    if let blocking = Self.blockingError(error) {
                        if outcome.blocking == nil { outcome.blocking = blocking }
                        stopLaunching = true
                    } else if Self.deservesDeferral(error) {
                        retryAfter[id] = Date().addingTimeInterval(tuning.hydrationRetryDelay)
                    } else {
                        outcome.retryable += 1
                    }
                }
                if !stopLaunching, !Task.isCancelled, let next = iterator.next() {
                    Self.add(next, fetchOne, to: &group)
                }
            }
        }
        return outcome
    }

    private static func add(
        _ id: MessageID,
        _ fetchOne: @escaping @Sendable (MessageID) async throws -> Bool,
        to group: inout TaskGroup<(MessageID, Result<Bool, Error>)>
    ) {
        group.addTask {
            do {
                return (id, .success(try await fetchOne(id)))
            } catch {
                return (id, .failure(error))
            }
        }
    }

    /// The fetch of `id`, joined when one is already in flight. `chargesLive` records the body's cost as live
    /// spend when this call starts the request; the paced path has already acquired it.
    private func fetchTask(for id: MessageID, chargesLive: Bool) -> Task<StoredBody, Error> {
        if let existing = inFlight[id] { return existing }
        let provider = provider
        let sanitizer = sanitizer
        let store = store
        let budget = budget
        let cost = budget.quota.bodyCost
        // Detached so sanitizing (HTML parsing) runs off this actor and fetches overlap freely.
        let task = Task.detached(priority: .utility) { () throws -> StoredBody in
            // The other path may have stored it between the caller's look and now; that costs no request.
            if let stored = try store.body(for: id) { return stored }
            if chargesLive { await budget.recordLive(cost) }
            let body = try await provider.body(for: id.providerID)
            try Task.checkCancellation()
            let sanitized = sanitizer.sanitize(body, messageID: id)
            let stored = StoredBody(
                body: body,
                renderedHTML: sanitized.html,
                plainText: sanitized.plainText,
                hasQuotedContent: sanitized.hasQuotedContent,
                // What the reader's "Load images" restores: parked <img> sources, not dropped backgrounds.
                blockedRemoteImageCount: RenderPayloadBuilder.blockedRemoteImageCount(in: sanitized.html),
                typesetting: sanitized.typesetting,
                declaresColors: sanitized.declaresColors,
                coveredByNewYork: sanitized.coveredByNewYork
            )
            try store.saveBody(stored, for: id)
            return stored
        }
        inFlight[id] = task
        Task { [weak self] in
            _ = try? await task.value
            await self?.finish(id, task: task)
        }
        return task
    }

    private func finish(_ id: MessageID, task: Task<StoredBody, Error>) {
        if inFlight[id] == task { inFlight[id] = nil }
    }

    private func pruneRetryAfter() {
        let now = Date()
        retryAfter = retryAfter.filter { $0.value > now }
    }

    private func log(_ path: String, _ outcome: Outcome) {
        let fetched = outcome.fetched
        let failed = outcome.failed
        SyncLog.logger.debug("hydration (\(path, privacy: .public)): fetched \(fetched, privacy: .public), failed \(failed, privacy: .public)")
    }

    private static func blockingError(_ error: Error) -> Error? {
        if let providerError = error as? ProviderError {
            switch providerError {
            case .unauthorized, .throttled: return providerError
            default: return nil
            }
        }
        // Every further fetch would read the keychain again and bring its password prompt back once per body.
        if let authError = error as? AuthError, authError.isKeychainDenial { return authError }
        return nil
    }

    /// Transient failures are retried on the next batch; everything else waits out `hydrationRetryDelay`.
    private static func deservesDeferral(_ error: Error) -> Bool {
        guard let providerError = error as? ProviderError else { return !(error is CancellationError) }
        switch providerError {
        case .network, .cancelled: return false
        default: return true
        }
    }
}
