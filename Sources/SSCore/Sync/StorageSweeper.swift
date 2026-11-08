import Foundation

/// Keeps the store inside the Keep mail window and tidy (docs/ARCHITECTURE.md, "Storage bounds"). It keeps no timer:
/// work comes only from moments the engine reports, once per launch after the first live cycle, when a backfill ends
/// and when the window narrows, and each piece runs on the store's writer in short transactions, one per turn of this
/// actor, so `stopAndWait` gets in between any two of them.
///
/// The bodies `kept` names (what the reader shows, what `MailEngine.ensureBody` fetched) are left out of every sweep
/// until the app quits, so mail the reader has on screen keeps its body and a message older than the window
/// opens once per launch, not once per sweep. A batch reads `kept` again inside its write, and the reader marks what it
/// renders before it reads a body, so a body marked while a batch is under way stays whole. `ensureBody` marks a
/// message before it fetches, so a batch whose `kept` misses it found the body still evicted or missing and leaves the
/// whole one saved afterwards alone.
actor StorageSweeper {
    struct Work: OptionSet, Sendable {
        let rawValue: Int
        /// Evict the bodies outside the window.
        static let evict = Work(rawValue: 1 << 0)
        /// Merge the full-text index into one b-tree.
        static let fullTextIndex = Work(rawValue: 1 << 1)
        /// Hand free pages back to the file system, where the file allows it.
        static let reclaim = Work(rawValue: 1 << 2)
    }

    private let store: MailStoring
    private let maintenance: MailStoreMaintenance?
    private let tuning: SyncTuning
    private let retention: @Sendable () -> MailRetention
    private let kept: @Sendable () -> Set<MessageID>
    private let changed: @Sendable () -> Void
    private var sweptAtLaunch = false
    private var pending: Work = []
    private var worker: Task<Void, Never>?

    /// - Parameters:
    ///   - retention: the window as the user set it now, read as each batch of a sweep starts and again in its write.
    ///   - kept: the messages whose bodies stay whole for this run, read as `retention` is.
    ///   - changed: called after a run that evicted bodies, merged the index or gave pages back, so the size Settings
    ///     shows can be measured again.
    init(store: MailStoring, maintenance: MailStoreMaintenance?, tuning: SyncTuning,
         retention: @escaping @Sendable () -> MailRetention, kept: @escaping @Sendable () -> Set<MessageID> = { [] },
         changed: @escaping @Sendable () -> Void) {
        self.store = store
        self.maintenance = maintenance
        self.tuning = tuning
        self.retention = retention
        self.kept = kept
        self.changed = changed
    }

    // MARK: Moments

    /// A live lane finished its first cycle. The first one per launch sweeps, after the work that matters at launch
    /// (the head page, the newest bodies, the outbox) rather than competing with it.
    func liveCycleEnded() {
        guard !sweptAtLaunch else { return }
        sweptAtLaunch = true
        request([.evict, .reclaim])
    }

    /// A backfill brought in older mail: its bodies may lie outside the window, and its index writes left many
    /// b-trees to merge.
    func backfillEnded() {
        request([.evict, .fullTextIndex, .reclaim])
    }

    /// Adds work and starts it unless a run is under way, which picks it up before it ends.
    func request(_ work: Work) {
        pending.formUnion(work)
        guard worker == nil else { return }
        worker = Task { await self.drain() }
    }

    /// Stops between steps and returns once the run under way has; nothing pending is kept.
    func stopAndWait() async {
        pending = []
        let running = worker
        running?.cancel()
        await running?.value
    }

    /// Returns once no run is under way, for tests.
    func waitUntilIdle() async {
        while let running = worker { await running.value }
    }

    // MARK: Running

    private func drain() async {
        while !pending.isEmpty, !Task.isCancelled {
            let work = pending
            pending = []
            var didChange = false
            if work.contains(.evict) { didChange = await evict() > 0 || didChange }
            if work.contains(.fullTextIndex) { didChange = await optimizeFullTextIndex() || didChange }
            if work.contains(.reclaim) { didChange = await reclaim() > 0 || didChange }
            if didChange, !Task.isCancelled { changed() }
        }
        worker = nil
    }

    /// Evicts batch after batch, oldest mail first, until none is left. Returns how many bodies went.
    ///
    /// Each batch starts where the last one stopped, so a sweep reads the mailbox once: about 20 seconds of reads for
    /// 300,000 messages, where starting again from the oldest every batch took a quarter of an hour. The window and the kept bodies are read as each batch looks for candidates and again
    /// inside its write: a user who picks a longer window or Everything meanwhile keeps what it keeps, since widening
    /// never fetches back, and a body the reader marks while a batch is under way stays whole.
    private func evict() async -> Int {
        let retention = retention
        let kept = kept
        let rules = { () -> (cutoff: Date, excluding: Set<MessageID>)? in
            retention().cutoff(now: Date()).map { ($0, kept()) }
        }
        var total = 0
        var start: Date?
        while !Task.isCancelled, retention().cutoff(now: Date()) != nil {
            let batch: (evicted: Int, next: Date?)
            do {
                batch = try store.evictBodies(from: start, limit: tuning.evictionBatchSize, rules: rules)
            } catch {
                SyncLog.logger.error("storage: eviction failed: \(String(describing: error), privacy: .private)")
                break
            }
            total += batch.evicted
            // Done once nothing is left to look at, or (never in practice) a batch that neither evicted nor moved on.
            guard let next = batch.next, batch.evicted > 0 || next != start else { break }
            start = next
            // One batch per turn, so `stopAndWait` never waits behind the whole sweep.
            await Task.yield()
        }
        if total > 0 { SyncLog.logger.info("storage: evicted \(total, privacy: .public) bodies outside the window") }
        return total
    }

    /// FTS5's optimize as merge steps, the first starting a merge of every b-tree, until a step finds nothing left or
    /// after `fullTextMergeMaxSteps`. The steps rewrite the whole index (a second or so for a 300,000-message mailbox),
    /// so each is its own turn of this actor: stopping the engine waits for one step, not the merge. A merge stopped
    /// halfway starts over next time. Returns whether it merged anything.
    private func optimizeFullTextIndex() async -> Bool {
        guard let maintenance else { return false }
        let pages = max(1, tuning.fullTextMergePagesPerStep)
        var steps = 0
        var mergedAny = false
        while steps < tuning.fullTextMergeMaxSteps, !Task.isCancelled {
            let merged: Bool
            do {
                merged = try maintenance.mergeFullTextIndex(pages: pages, startingOver: steps == 0)
            } catch {
                SyncLog.logger.error("storage: full-text optimize failed: \(String(describing: error), privacy: .private)")
                break
            }
            steps += 1
            guard merged else { break }
            mergedAny = true
            await Task.yield()
        }
        if steps > 0 { SyncLog.logger.info("storage: full-text index merged in \(steps, privacy: .public) steps") }
        return mergedAny
    }

    /// Incremental vacuum steps while free pages are left, at most `vacuumMaxSteps`. A file created before v10 cannot
    /// take them (`reclaimFreePages` answers nil) and keeps its free pages for SQLite to reuse. Returns the pages given
    /// back.
    private func reclaim() async -> Int {
        guard let maintenance else { return 0 }
        let step = max(1, tuning.vacuumPagesPerStep)
        var steps = 0
        var total = 0
        while steps < tuning.vacuumMaxSteps, !Task.isCancelled {
            let reclaimed: Int?
            do {
                reclaimed = try maintenance.reclaimFreePages(upTo: step)
            } catch {
                SyncLog.logger.error("storage: incremental vacuum failed: \(String(describing: error), privacy: .private)")
                break
            }
            guard let reclaimed, reclaimed > 0 else { break }
            steps += 1
            total += reclaimed
            // Fewer than asked for: the free list is empty.
            guard reclaimed >= step else { break }
            await Task.yield()
        }
        if total > 0 { SyncLog.logger.info("storage: incremental vacuum gave back \(total, privacy: .public) pages in \(steps, privacy: .public) steps") }
        return total
    }
}
