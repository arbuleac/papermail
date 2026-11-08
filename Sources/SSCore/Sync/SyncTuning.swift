import Foundation

/// The delays and sizes the engine's loops run on. Production uses the defaults; tests shrink the delays so
/// a whole bootstrap-poll-retry story fits in a few hundred milliseconds.
struct SyncTuning: Sendable {
    /// How often the live lane checks for new mail while the app is in the background.
    var pollInterval: TimeInterval = 30
    /// How often the live lane checks while the app is frontmost. Follows `pollInterval` down (never above it)
    /// until set, so a test or caller that shortens the background interval shortens this one too.
    var activePollInterval: TimeInterval {
        get { activePollIntervalOverride ?? min(Self.defaultActivePollInterval, pollInterval) }
        set { activePollIntervalOverride = newValue }
    }
    /// First retry delay after a failure; doubles per consecutive failure up to `backoffCap`.
    var backoffBase: TimeInterval = 2
    var backoffCap: TimeInterval = 300
    /// The live lane never waits longer than this between attempts, on its own schedule or on a provider's retry
    /// time: new mail matters more than the request a failing poll costs, and a retry time hours away is more often
    /// a skewed clock than advice.
    var liveBackoffCap: TimeInterval = 60
    /// The longest a user action or a send waits on a throttle: the live lane's cap, for the same reasons. The
    /// throttle schedule without a provider time keeps to `backoffCap`, as their other retries do.
    var userRetryAfterCap: TimeInterval { min(backoffCap, liveBackoffCap) }
    /// The clocks the send runner times held sends by. Tests replace it to move time by hand.
    var sendClock = SendClock()
    /// The clocks the snooze runner times Later by: the wall clock the due times are written in, and the continuous
    /// clock it sleeps on. Tests replace it to move time by hand.
    var snoozeClock = SendClock()
    /// The head page and every backfill listing page. 100 keeps a Gmail head page (a list call plus metadata for
    /// each message) at about 2,005 of the 6,000 units a user may spend a minute.
    var bootstrapPageSize: Int = 100
    /// Messages per changes page. Gmail fetches metadata for each message a page names (20 units apiece), so 100
    /// keeps a full page at about 2,000 units, the live lane's share of a minute.
    var changesPageSize: Int = 100
    /// Bodies the live lane fetches itself for the newest mail a poll or head page brought (new to the store, and
    /// no more than its share of the quota pays for); the backfill lane fetches the rest, paced.
    var liveHydrationLimit: Int = 20
    var liveHydrationConcurrency: Int = 2
    /// Messages per metadata request when a backfill listing returns ids only. Small, so a throttle mid-page
    /// loses at most one chunk; the page's retry skips what was written.
    var backfillMetadataChunk: Int = 10
    /// How long the backfill lane sleeps with nothing to do before looking again on its own.
    var backfillIdleInterval: TimeInterval = 300
    var hydrationBatchSize: Int = 50
    var hydrationConcurrency: Int = 4
    /// A body whose fetch failed for a non-transient reason is left alone for this long.
    var hydrationRetryDelay: TimeInterval = 600
    /// Bodies stored before v3 whose design facts are worked out again per batch, from the stored source: one
    /// transaction each, on a background task, after every backfill body batch, so an upgraded mailbox catches up
    /// within a few backfill turns.
    var designFactsBatchSize: Int = 200
    /// Bodies evicted per transaction by a Keep mail sweep: a few milliseconds of the writer each, so a user action
    /// written meanwhile waits for one batch at most (docs/ARCHITECTURE.md, "Storage bounds").
    var evictionBatchSize: Int = 200
    /// Full-text index pages merged per step of the optimize that follows a backfill (about 256 KB each), and the most
    /// steps one optimize takes: far more than a large mailbox's index needs, it only stops a merge that never settles.
    var fullTextMergePagesPerStep: Int = 64
    var fullTextMergeMaxSteps: Int = 4096
    /// Free pages handed back to the file system per incremental vacuum step (1 MiB at 4 KiB pages), and the most
    /// steps one idle moment takes; what is left waits for the next one.
    var vacuumPagesPerStep: Int = 256
    var vacuumMaxSteps: Int = 1024
    /// A backfill counts as ended, for its optimize and sweep, when the lane goes idle after listing pages or after at
    /// least this many bodies; fewer are the bodies of a few new messages the live lane handed over, not a backfill.
    var backfillEndMinimumBodies: Int { hydrationBatchSize }
    /// Hits a search of the server asks each provider for, and how many accounts it searches at once
    /// (`ServerSearcher`).
    var serverSearchLimit: Int = 50
    var serverSearchConcurrency: Int = 2
    var maxApplyTargets: Int = 50
    /// After this many failed attempts an operation is marked `failed` instead of staying in the outbox forever.
    var maxOperationAttempts: Int = 25
    /// Uncertain operations older than this are dropped once a poll has observed their targets.
    var uncertainSettleAge: TimeInterval = 600
    /// How long a failed operation stays, keeping its conversation's failed mark, before it is pruned.
    var failedOperationRetention: TimeInterval = 24 * 60 * 60
    var pendingOperationsFetchLimit: Int = 500
    /// What each account's provider allows, for its quota budget. The demo's made-up mailbox has no limit.
    var quota: @Sendable (MailProvider) -> ProviderQuota = { provider in
        provider is DemoMailProvider ? .unlimited : .standard(for: provider.kind)
    }
    /// Builds an account's budget. Tests replace it to give the budget a clock they control.
    var makeBudget: @Sendable (ProviderQuota) -> QuotaBudget = { QuotaBudget(quota: $0) }
    /// The session a one-click unsubscribe goes out on (`Unsubscriber.configuration()`). Tests replace it with one
    /// whose stub protocol answers, so no test reaches a sender's server.
    var unsubscribeConfiguration: @Sendable () -> URLSessionConfiguration = { Unsubscriber.configuration() }

    private var activePollIntervalOverride: TimeInterval?
    private static let defaultActivePollInterval: TimeInterval = 5

    init() {}

    init(pollInterval: TimeInterval) {
        self.pollInterval = pollInterval
    }
}
