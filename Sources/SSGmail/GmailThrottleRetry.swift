import Foundation
import SSCore

/// When the provider sends the throttled parts of a metadata batch again, and when it stops and reports the
/// throttle to the engine instead.
///
/// Google runs a batch's parts concurrently, so a few parts of an otherwise healthy batch can trip the
/// per-user concurrency limit; a short wait and a second batch of just those parts keeps the rest of the
/// work. Reporting is the costly choice: the throw discards every message the call already fetched, and the
/// engine's retry spends their quota again, so the provider waits out what it reasonably can.
struct GmailThrottleRetry: Sendable {
    /// The wait before each new send, in order; once they are used up, parts still throttled are reported.
    var delays: [TimeInterval]
    /// The longest Retry-After waited out here: Gmail's quota refills per minute, so a longer one is not a
    /// passing spike, and the engine pausing the lane (and saying until when) beats a call that sits unseen.
    var maxInlineWait: TimeInterval
    /// The longest Retry-After waited out while the call has fetched nothing yet. Stopping then loses no
    /// work, so the throttle goes to the engine, which slows the lane that overspent and shows the pause.
    var maxWaitWithNothingFetched: TimeInterval
    /// Injected so tests neither wait nor depend on the clock.
    var sleep: @Sendable (TimeInterval) async throws -> Void

    static let standard = GmailThrottleRetry(delays: [1, 2, 4], maxInlineWait: 60, maxWaitWithNothingFetched: 10,
                                             sleep: { try await taskSleep($0) })

    /// The wait before new send number `retry` (0-based), or nil when the parts should be reported instead.
    /// `hasFetched` says whether the call already holds messages that reporting would throw away.
    /// A Retry-After is honoured but never shortens the schedule: a refill time Google states in the past
    /// (clock skew) must not turn the retries into an immediate burst.
    func delay(beforeRetry retry: Int, retryAfter: TimeInterval?, hasFetched: Bool) -> TimeInterval? {
        guard delays.indices.contains(retry) else { return nil }
        guard let retryAfter else { return delays[retry] }
        let ceiling = hasFetched ? maxInlineWait : min(maxInlineWait, maxWaitWithNothingFetched)
        guard retryAfter <= ceiling else { return nil }
        return max(retryAfter, delays[retry])
    }

    /// Cancellation ends the wait at once and surfaces as the provider's own cancellation error.
    func wait(_ seconds: TimeInterval) async throws {
        do {
            try await sleep(seconds)
        } catch is CancellationError {
            throw ProviderError.cancelled
        }
    }

    static func taskSleep(_ seconds: TimeInterval) async throws {
        guard seconds > 0 else {
            try Task.checkCancellation()
            return
        }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}
