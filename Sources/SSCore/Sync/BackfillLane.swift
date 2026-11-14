import Foundation

/// The backfill lane of one account: downloads the older mail behind the live lane's head page, then the
/// bodies the live lane left, paced by the account's `QuotaBudget` so the download stays inside the provider's
/// quota instead of running into throttles that throw work away.
///
/// Each turn does one piece of work: an enumeration page while the `BootstrapState` is incomplete (followed by
/// one paced body batch, so the newest bodies keep arriving), otherwise one paced body batch while bodies are
/// missing, otherwise the design-facts backfill (local) and then sleep. Pages are written with
/// `writeBackfillMessages`, which never overwrites a message the live lane wrote or deleted meanwhile (the
/// live lane marks them, docs/DATA-MODEL.md "Backfill marks"), and the state is saved after every page, so a
/// quit or a crash resumes where it stopped.
///
/// A throttle pauses this lane (the live lane keeps polling) and shows as `backfillPausedUntil`. So does a throttle
/// on the live share (`QuotaBudget.liveThrottled`), since both lanes spend one quota: the budget holds every request
/// of this lane until it ends, and tells this lane to show it once a request waits on it. Other failures back off
/// quietly, without touching the live phase. A rejected token parks both lanes until the live
/// lane completes a cycle again, and at launch this lane waits for the live lane's first cycle. The park is
/// looked at again before every request, so a turn under way stops sending once the account is parked.
actor BackfillLane {
    private enum Turn {
        case worked
        case idle(TimeInterval)
    }

    /// The live lane replaced the backfill while this turn worked on the old one.
    private struct StaleBackfill: Error {}
    /// A body batch in which every fetch failed for a transient reason.
    private struct HydrationStalled: Error {}
    /// The account was parked while this turn waited for a slot or units.
    private struct Parked: Error {}

    let accountID: AccountID
    private let store: MailStoring
    private let provider: MailProvider
    private let hydrator: Hydrator
    private let statusCenter: SyncStatusCenter
    private let tuning: SyncTuning
    private let budget: QuotaBudget
    private let link: LaneLink
    /// Told when the lane goes idle after a backfill: the engine optimizes the full-text index and sweeps then.
    private let backfillEnded: @Sendable () -> Void
    /// Listing pages and paced bodies since the lane was last idle, to tell a backfill from a few handed-over bodies.
    private var pagesSinceIdle = 0
    private var bodiesSinceIdle = 0
    private var consecutiveFailures = 0
    private var consecutiveThrottles = 0
    /// The last page token the provider handed this lane. A stored token it has not seen accepted may have
    /// expired over a long quit; one the provider rejects restarts the listing instead of wedging the lane.
    private var issuedPage: String?
    /// The provider call under way, for the throttle log.
    private var currentCall = "list"
    /// Whether this lane has published a `backfillPausedUntil` it has not cleared yet.
    private var pausePublished = false
    /// The `backfillDownloadingBodies` this lane last published.
    private var bodiesPublished = false

    init(
        accountID: AccountID,
        store: MailStoring,
        provider: MailProvider,
        hydrator: Hydrator,
        statusCenter: SyncStatusCenter,
        tuning: SyncTuning,
        budget: QuotaBudget,
        link: LaneLink,
        backfillEnded: @escaping @Sendable () -> Void = {}
    ) {
        self.accountID = accountID
        self.store = store
        self.provider = provider
        self.hydrator = hydrator
        self.statusCenter = statusCenter
        self.tuning = tuning
        self.budget = budget
        self.link = link
        self.backfillEnded = backfillEnded
    }

    // MARK: Loop

    func run() async {
        let id = accountID.rawValue
        SyncLog.logger.info("backfill lane started for \(id, privacy: .public)")
        // A pause this lane did not start (a throttle on the live lane) reaches it only through the budget: it shows
        // while one of this lane's requests waits it out, mid-turn included, and clears as that request goes out.
        await budget.observePauses { [statusCenter, accountID] resume in
            guard !Task.isCancelled else { return }
            statusCenter.update(accountID) { $0.backfillPausedUntil = resume }
        }
        // A download left incomplete by the last run shows how far it got at once, before any request.
        publishProgress(try? store.bootstrapState(for: accountID))
        while !Task.isCancelled {
            let waker = link.backfillWaker
            if link.isParked {
                // No requests while the account waits for sign-in, or at launch until the live lane's first cycle has
                // tried the token; the live lane wakes this one then.
                _ = await waker.wait(timeout: nil)
                continue
            }
            do {
                // The live lane sets the cursor once the head page is stored, and wakes this lane then.
                guard try store.syncCursor(for: accountID) != nil, let generation = link.backfillGeneration else {
                    _ = await waker.wait(timeout: nil)
                    continue
                }
                // This turn's body batch covers bodies handed over before it; only later ones end a backoff.
                _ = link.takeBodiesHandedOff()
                switch try await turn(generation) {
                case .worked:
                    consecutiveFailures = 0
                    consecutiveThrottles = 0
                case .idle(let interval):
                    consecutiveFailures = 0
                    consecutiveThrottles = 0
                    reportIdle()
                    _ = await waker.wait(timeout: interval)
                }
            } catch is StaleBackfill {
                SyncLog.logger.info("backfill for \(id, privacy: .public) replaced mid-turn; starting on the new one")
            } catch is Parked {
                SyncLog.logger.debug("backfill for \(id, privacy: .public) parked mid-turn")
            } catch is CancellationError {
                break
            } catch let error as ProviderError {
                await handle(error)
            } catch let error as AuthError where error.isKeychainDenial {
                SyncLog.logger.error("backfill: keychain read denied for \(id, privacy: .public)")
                link.requestPark(message: LiveLane.keychainMessage)
            } catch {
                await failed(error)
            }
        }
        SyncLog.logger.info("backfill lane stopped for \(id, privacy: .public)")
    }

    /// Nothing is left to fetch. After listing pages, or at least a batch of bodies, that was a backfill ending
    /// (a first download, a reconcile, or the bodies a quit left for this launch); the few bodies of new mail the live
    /// lane hands over are not, so the index is not rewritten after every busy poll.
    private func reportIdle() {
        let ended = pagesSinceIdle > 0 || bodiesSinceIdle >= tuning.backfillEndMinimumBodies
        pagesSinceIdle = 0
        bodiesSinceIdle = 0
        if ended { backfillEnded() }
    }

    private func handle(_ error: ProviderError) async {
        let id = accountID.rawValue
        switch error {
        case .unauthorized:
            SyncLog.logger.error("backfill: provider rejected the token for \(id, privacy: .public)")
            link.requestPark(message: LiveLane.signInMessage)
        case .throttled(let retryAfter):
            await throttled(retryAfter: retryAfter)
        case .cancelled:
            // A request cut off by `stop()`: the lane is ending, nothing failed.
            return
        default:
            await failed(error)
        }
    }

    /// Pauses this lane. Under a metered quota the budget holds the pause (its next grant waits it out) and says
    /// when it ends; unmetered, the budget never pauses, so the lane waits its own backoff.
    private func throttled(retryAfter: TimeInterval?) async {
        consecutiveThrottles += 1
        var resume = await budget.backfillThrottled(retryAfter: retryAfter)
        let budgetPauses = resume > Date()
        if !budgetPauses {
            resume = Date().addingTimeInterval(Backoff.throttleDelay(
                retryAfter: retryAfter, attempt: consecutiveThrottles, base: tuning.backoffBase, cap: tuning.backoffCap
            ))
        }
        publishPause(resume)
        let call = currentCall
        let resumeText = resume.formatted(.iso8601)
        SyncLog.logger.notice("backfill lane throttled on \(call, privacy: .public) for \(self.accountID.rawValue, privacy: .public): retry after \(retryAfter ?? -1, privacy: .public) s, resuming at \(resumeText, privacy: .public)")
        if !budgetPauses { await sleep(until: resume) }
    }

    private func failed(_ error: Error) async {
        // An error that surfaces while the lane is being stopped is the stop itself.
        guard !Task.isCancelled else { return }
        consecutiveFailures += 1
        let delay = Backoff.delay(attempt: consecutiveFailures, base: tuning.backoffBase, cap: tuning.backoffCap)
        let description = SyncErrorDescription.describe(error)
        SyncLog.logger.error("backfill failed for \(self.accountID.rawValue, privacy: .public), retrying in \(delay, privacy: .public) s: \(description, privacy: .private)")
        await sleep(until: Date().addingTimeInterval(delay))
    }

    /// Waits out a backoff. Wakes in the meantime are mostly dropped (a lane woken early would only meet the same
    /// failure sooner), except for new work: a backfill the live lane has replaced, or bodies of new mail it handed
    /// over after a request that went through, which says the network is back.
    private func sleep(until deadline: Date) async {
        let generation = link.backfillGeneration
        while !Task.isCancelled {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return }
            _ = await link.backfillWaker.wait(timeout: remaining)
            if link.backfillGeneration != generation || link.takeBodiesHandedOff() { return }
        }
    }

    // MARK: Turns

    private func turn(_ generation: Int) async throws -> Turn {
        try await waitOutPause()
        let state = try store.bootstrapState(for: accountID)
        if let state, !state.isComplete {
            publishProgress(state)
            do {
                try await enumerate(state, generation: generation)
            } catch let error where !Self.stopsTheTurn(error) {
                // A page that keeps failing (a 500 every time, a lookup the reconcile cannot finish) must not stop the
                // paced bodies with it: new mail past the live lane's twenty would come only when opened. Its batch
                // goes, and the failure backs off as before.
                try await hydrateBatch()
                throw error
            }
            pagesSinceIdle += 1
            try await hydrateBatch()
            await hydrator.backfillDesignFacts()
            return .worked
        }
        clearProgress()
        let outcome = try await hydrateBatch()
        // The design facts are local and cheap, and stop asking once none are missing: one batch after every body
        // batch (docs/DATA-MODEL.md), so an upgraded mailbox does not wait for every body to arrive first.
        let wroteFacts = await hydrator.backfillDesignFacts()
        if outcome.fetched > 0 { publishDownloadingBodies(true) }
        // A skipped fetch was picked when more bodies may be missing behind it: look again rather than sleep.
        if outcome.fetched > 0 || outcome.skipped > 0 { return .worked }
        // Nothing came back and the failures will be asked for again (network errors): back off rather than spin.
        // Deferred failures leave the queue, so the next batch moves on to other bodies.
        if outcome.retryable > 0 { throw HydrationStalled() }
        if outcome.failed > 0 { return .worked }
        publishDownloadingBodies(false)
        // One design-facts batch per poll interval keeps an upgrade's catch-up in the background.
        return .idle(wroteFacts > 0 ? tuning.pollInterval : tuning.backfillIdleInterval)
    }

    /// One paced body batch; a throttle, a rejected token or a park stops the turn.
    @discardableResult
    private func hydrateBatch() async throws -> Hydrator.Outcome {
        let link = link
        let outcome = await hydrator.hydratePaced(while: { !link.isParked })
        bodiesSinceIdle += outcome.fetched
        try Task.checkCancellation()
        if let blocking = outcome.blocking {
            currentCall = "body"
            throw blocking
        }
        if outcome.halted { throw Parked() }
        return outcome
    }

    /// After a throttle, the budget's next grant comes when the pause is over; clearing `backfillPausedUntil`
    /// then, before the next request, ends the "paused until" line the moment the lane resumes.
    private func waitOutPause() async throws {
        guard pausePublished else { return }
        try await budget.acquireBackfill(0)
        pausePublished = false
        guard !Task.isCancelled else { return }
        statusCenter.update(accountID) { $0.backfillPausedUntil = nil }
    }

    // MARK: Enumeration

    private func enumerate(_ state: BootstrapState, generation: Int) async throws {
        var state = state
        let reconciling = state.reconciling ?? false
        var checkpoint = state.checkpoint
        let quota = budget.quota
        let pageSize = tuning.bootstrapPageSize
        let listing: BackfillListing
        if let page = checkpoint.providerPage {
            let untested = page != issuedPage
            do {
                listing = try await request("list", cost: quota.listCost) {
                    try await self.provider.backfillListing(page: page, limit: pageSize)
                }
            } catch let error as ProviderError where Self.rejectsResumeToken(error) {
                guard untested else {
                    // Rejected once already in this run: a second rejection restarts the listing.
                    issuedPage = nil
                    throw error
                }
                // A page token kept across a long quit may have expired (Gmail answers 400). Retrying it would fail
                // the same way every time and the download would never finish; list from the top instead.
                SyncLog.logger.notice("backfill resume token rejected for \(self.accountID.rawValue, privacy: .public); listing again from the top")
                state.pagesDone = 0
                state.messagesSeen = 0
                checkpoint.providerPage = nil
                state.checkpoint = checkpoint
                try fenced(generation) { try store.setBootstrapState(state, for: accountID) }
                return
            }
        } else {
            // Incomplete with nowhere to resume from: list from the top. The cursor this returns is ignored, the live
            // lane owns the cursor; its messages are written like any listing page's. Units for a full metadata page
            // where the provider fetches that metadata by id inside `bootstrap`.
            let metadataCost = quota.inlineMetadata ? 0 : quota.metadataCostPerMessage * Double(pageSize)
            let priced = quota.listCost + metadataCost
            let head = try await request("list", cost: priced) {
                try await self.provider.bootstrap(page: nil, limit: pageSize)
            }
            // A provider charged per request says what the call sent (Graph's also looks up the system folders and
            // lists the top of the folder tree). What it sent beyond the price taken comes out of the bucket now, so
            // the next request waits for it rather than the burst going unseen.
            if let sent = head.requestCount {
                await budget.recordBackfill(Double(max(0, sent)) * quota.listCost - priced)
            }
            listing = BackfillListing(ids: head.messages.map(\.id.providerID), messages: head.messages, nextPage: head.nextPage)
            state.pagesDone = 0
            state.messagesSeen = 0
            if state.estimatedTotal == nil { state.estimatedTotal = head.estimatedTotal }
        }
        issuedPage = listing.nextPage
        try Task.checkCancellation()
        if reconciling {
            try fenced(generation) { try store.markBackfillSeen(accountID: accountID, providerIDs: listing.ids) }
        }
        if let messages = listing.messages {
            try fenced(generation) { try store.writeBackfillMessages(messages, refreshExisting: reconciling) }
        } else {
            try await fetchMetadata(for: listing.ids, reconciling: reconciling, generation: generation)
        }
        state.pagesDone += 1
        state.messagesSeen += listing.ids.count
        checkpoint.providerPage = listing.nextPage
        guard listing.nextPage != nil else {
            try await finish(state, checkpoint: checkpoint, reconciling: reconciling, generation: generation)
            return
        }
        state.checkpoint = checkpoint
        try fenced(generation) { try store.setBootstrapState(state, for: accountID) }
        publishProgress(state)
    }

    /// Metadata for an ids-only listing: only for messages the store lacks (a reconcile refreshes them all), in
    /// chunks of `backfillMetadataChunk`, each written as soon as it arrives. A throttle mid-page loses at most
    /// one chunk, and the page's retry skips what was written. Ids the provider leaves out (gone, or chat
    /// messages) are not asked for again within the page.
    private func fetchMetadata(for ids: [String], reconciling: Bool, generation: Int) async throws {
        let skip = try store.backfillSkippableIDs(accountID: accountID, providerIDs: ids, includeStored: !reconciling)
        var seen: Set<String> = []
        let wanted = ids.filter { !skip.contains($0) && seen.insert($0).inserted }
        let chunkSize = max(1, tuning.backfillMetadataChunk)
        let costPerMessage = budget.quota.metadataCostPerMessage
        for start in stride(from: 0, to: wanted.count, by: chunkSize) {
            let chunk = Array(wanted[start..<min(start + chunkSize, wanted.count)])
            let messages = try await request("metadata", cost: costPerMessage * Double(chunk.count)) {
                try await self.provider.metadata(for: chunk)
            }
            try Task.checkCancellation()
            try fenced(generation) { try store.writeBackfillMessages(messages, refreshExisting: reconciling) }
        }
    }

    /// The listing reached the end. A reconcile first records "listed, not finished" (no page to resume from):
    /// its sweep clears the seen marks, and a crash after the sweep must list everything again rather than resume
    /// at the last page and sweep all but that page. It also keeps the state incomplete during the sweep, so the
    /// live lane goes on marking what it writes and the sweep cannot take mail that just arrived.
    private func finish(_ state: BootstrapState, checkpoint: BootstrapCheckpoint, reconciling: Bool, generation: Int) async throws {
        var state = state
        if reconciling {
            // Before "listed" is saved: a failure here retries the last page, not the whole listing.
            try await markMailOutsideEnumerationSeen(generation: generation)
            try await removeLostTargets(generation: generation)
            var listed = state
            var resumeNowhere = checkpoint
            resumeNowhere.providerPage = nil
            listed.checkpoint = resumeNowhere
            try fenced(generation) { try store.setBootstrapState(listed, for: accountID) }
        }
        let swept = try fenced(generation) { try store.finishBackfill(accountID: accountID, sweepUnseen: reconciling) }
        state.isComplete = true
        state.checkpoint = BootstrapCheckpoint()
        try fenced(generation) { try store.setBootstrapState(state, for: accountID) }
        clearProgress()
        let pages = state.pagesDone
        let messages = state.messagesSeen
        SyncLog.logger.info("backfill complete for \(self.accountID.rawValue, privacy: .public): \(messages, privacy: .public) messages in \(pages, privacy: .public) pages, reconciling \(reconciling, privacy: .public), removed \(swept, privacy: .public)")
    }

    /// Mail the enumeration leaves out that the provider still has (Gmail's Trash and Spam): marked seen so the sweep
    /// keeps it, since nothing after the reset would bring it back. Ids only, paced like the listing.
    private func markMailOutsideEnumerationSeen(generation: Int) async throws {
        guard provider.hasMailOutsideEnumeration else { return }
        let cost = budget.quota.listCost
        let pageSize = tuning.outsideEnumerationPageSize
        var page: String?
        repeat {
            let asked = page
            let listing = try await request("list", cost: cost) {
                try await self.provider.mailOutsideEnumeration(page: asked, limit: pageSize)
            }
            try Task.checkCancellation()
            try fenced(generation) { try store.markBackfillSeen(accountID: accountID, providerIDs: listing.ids) }
            page = listing.nextPage
        } while page != nil
    }

    /// Stored messages a live operation targets that the provider no longer has (`LostTargets`): deleted before the
    /// sweep, which would keep them for good. Paced like the listing's metadata.
    private func removeLostTargets(generation: Int) async throws {
        let candidates = try LostTargets.candidates(store: store, accountID: accountID, limit: tuning.pendingOperationsFetchLimit)
        guard !candidates.isEmpty else { return }
        let costPerMessage = budget.quota.metadataCostPerMessage
        let lost = try await LostTargets.lost(candidates, chunk: tuning.backfillMetadataChunk) { ids in
            try await self.request("metadata", cost: costPerMessage * Double(ids.count)) {
                try await self.provider.lookUpMetadata(for: ids)
            }
        }
        guard !lost.isEmpty else { return }
        try fenced(generation) { try store.deleteMessages(lost.map { MessageID(accountID: accountID, providerID: $0) }) }
        SyncLog.logger.info("reconcile for \(self.accountID.rawValue, privacy: .public): removed \(lost.count, privacy: .public) messages the provider no longer has though an operation targets them")
    }

    /// What a body batch would meet too, or what ends the turn for another reason: a throttle, a refused token or
    /// keychain, the network, a park, a replaced backfill, a stop.
    private static func stopsTheTurn(_ error: Error) -> Bool {
        if error is StaleBackfill || error is Parked || error is CancellationError || error is AuthError { return true }
        switch error as? ProviderError {
        case .throttled?, .unauthorized?, .network?, .cancelled?: return true
        default: return false
        }
    }

    /// Errors that say the page token itself is no good, as opposed to the provider being unwell.
    private static func rejectsResumeToken(_ error: ProviderError) -> Bool {
        switch error {
        case .notFound, .decoding: return true
        case .server(let status, _): return status == 400 || status == 404 || status == 410
        default: return false
        }
    }

    // MARK: Requests

    /// One backfill request: a slot and `cost` units from the budget first, the slot given back exactly once.
    /// Either wait can be long, so the park is looked at again before the request goes out.
    private func request<T>(_ call: String, cost: Double, _ body: () async throws -> T) async throws -> T {
        currentCall = call
        try await budget.acquireBackfillSlot()
        let value: T
        do {
            try await budget.acquireBackfill(cost)
            guard !link.isParked else { throw Parked() }
            value = try await body()
        } catch {
            await budget.releaseBackfillSlot()
            throw error
        }
        await budget.releaseBackfillSlot()
        await budget.backfillSucceeded()
        return value
    }

    /// Runs a store write for the backfill this turn works on; throws `StaleBackfill` once the live lane has
    /// replaced it, so a page fetched for the old backfill never lands on the new one.
    @discardableResult
    private func fenced<T>(_ generation: Int, _ body: () throws -> T) throws -> T {
        guard let value = try link.ifCurrent(generation, body) else { throw StaleBackfill() }
        return value
    }

    // MARK: Status

    /// `backfillProgress` and `backfillTotal` while an enumeration runs; cleared once it completes.
    private func publishProgress(_ state: BootstrapState?) {
        guard let state, !state.isComplete else {
            clearProgress()
            return
        }
        guard !Task.isCancelled else { return }
        statusCenter.update(accountID) { status in
            status.backfillProgress = state.messagesSeen
            status.backfillTotal = state.estimatedTotal
        }
    }

    private func clearProgress() {
        guard !Task.isCancelled else { return }
        statusCenter.update(accountID) { status in
            status.backfillProgress = nil
            status.backfillTotal = nil
        }
    }

    /// Settings' “Up to date · downloading messages…”: on while body batches after the listing bring bodies in,
    /// off once one finds none missing. Published only on a change, since a batch runs every few seconds.
    private func publishDownloadingBodies(_ downloading: Bool) {
        guard downloading != bodiesPublished, !Task.isCancelled else { return }
        bodiesPublished = downloading
        statusCenter.update(accountID) { $0.backfillDownloadingBodies = downloading }
    }

    private func publishPause(_ resume: Date) {
        pausePublished = true
        guard !Task.isCancelled else { return }
        statusCenter.update(accountID) { $0.backfillPausedUntil = resume }
    }
}
