import Foundation

/// The delays and sizes the engine's loops run on. Production uses the defaults; tests shrink the delays so
/// a whole bootstrap-poll-retry story fits in a few hundred milliseconds.
struct SyncTuning: Sendable {
    var pollInterval: TimeInterval = 30
    /// First retry delay after a failure; doubles per consecutive failure up to `backoffCap`.
    var backoffBase: TimeInterval = 2
    var backoffCap: TimeInterval = 300
    /// How often the send runner looks at the outbox when nothing is due sooner.
    var sendTickInterval: TimeInterval = 1
    var bootstrapPageSize: Int = 200
    var changesPageSize: Int = 200
    var hydrationBatchSize: Int = 50
    var hydrationConcurrency: Int = 4
    /// A body whose fetch failed for a non-transient reason is left alone for this long.
    var hydrationRetryDelay: TimeInterval = 600
    var maxApplyTargets: Int = 50
    /// After this many failed attempts an operation is marked `failed` instead of staying in the outbox forever.
    var maxOperationAttempts: Int = 25
    /// Uncertain operations older than this are dropped once a poll has observed their targets.
    var uncertainSettleAge: TimeInterval = 600
    var pendingOperationsFetchLimit: Int = 500

    init() {}

    init(pollInterval: TimeInterval) {
        self.pollInterval = pollInterval
    }
}
