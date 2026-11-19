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
    /// Ids per page a reconcile lists of the mail the enumeration leaves out (`MailProvider.mailOutsideEnumeration`):
    /// Gmail's most, since an ids-only page costs 5 units however many it lists.
    var outsideEnumerationPageSize: Int = 500
    /// Messages per metadata request when a backfill listing returns ids only. Small, so a throttle mid-page
    /// loses at most one chunk; the page's retry skips what was written.
    var backfillMetadataChunk: Int = 10
    /// Turns a backfill page gets whose metadata the service failed for some of its messages (a Gmail 500 for one
    /// message) before it moves on without them. Each later turn asks only for those, after the lane's backoff
    /// (2, 4, 8, 16 s), so a passing failure costs the page nothing and one that lasts cannot hold the backfill.
    var failingPageTries: Int = 5
    /// Stored messages of a gone folder the live lane looks up per poll (`queued_lookups`), at most, and never more
    /// than its share has room for: one Graph `$batch`, so a folder of thousands is worked through without holding new
    /// mail back or outrunning the mailbox's limit.
    var queuedLookupsPerPoll: Int = 20
    /// Tries a queued lookup the service fails gets before its message is left as it is.
    var maxQueuedLookupTries: Int = 5
    /// How long the queued lookups wait after the service failed one, so the tries are spread past a passing outage.
    var queuedLookupRetryDelay: TimeInterval = 60
    /// How long the backfill lane sleeps with nothing to do before looking again on its own.
    var backfillIdleInterval: TimeInterval = 300
    /// How old the calendar's last read may grow while the app is frontmost, and while it is not, before a live cycle
    /// that caught up has the calendar lane read the window again (docs/ARCHITECTURE.md, "Calendar"). The day column
    /// shows events, which change far less often than mail arrives, and every read lists the whole window (that is what
    /// finds the events deleted elsewhere), so two minutes in front cost one read where the poll costs twenty-four. What
    /// this Mac does is read at once: time set aside, an answer once it has gone out, a calendar just shown.
    var calendarActiveInterval: TimeInterval = 120
    var calendarBackgroundInterval: TimeInterval = 600
    /// How much newer a read must be than the one `AccountSyncStatus.calendar` shows before it is published again: only
    /// a change of state is news to the views that observe the statuses, which lay out again on each.
    var calendarStatusRefresh: TimeInterval = 300
    /// The clocks the calendar lane reads by: the wall clock its window is worked out on and its reads are dated by
    /// (`CalendarSyncState.current`), and the continuous clock its intervals and backoff run on, so setting the Mac's
    /// clock never holds a read back. It never sleeps: the live lane's cycles wake it. Tests replace it to move time by hand.
    var calendarClock = SendClock()
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
    /// An uncertain operation last sent longer ago than this is dropped once a poll has observed every target. Past
    /// the 60 s a request may take before it times out, so the request has landed or never will; and well below
    /// `backoffCap`, since the outbox retries a due operation just before each poll: measured from the last attempt,
    /// an age above the longest backoff could never be reached.
    var uncertainSettleAge: TimeInterval = 120
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
