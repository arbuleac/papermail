import Foundation

/// Render bookkeeping for one pooled web view.
///
/// Every request gets a generation so a late completion for an older render is ignored, and anyone may
/// wait for the latest render to land no matter who started it: a `show` that finds a pre-render still
/// in flight waits on it instead of starting over or giving up. Pure so the superseding rules are
/// testable without WebKit. Not `Sendable`: the waiters are plain closures owned by one main-actor slot.
public struct SlotRenderTracker {
    public enum Completion {
        /// A newer request replaced this render before it finished; its waiters now belong to that one.
        case superseded
        /// This was the latest render: the slot is idle and these waiters are owed the result.
        case landed(waiters: [(Bool) -> Void])
    }

    public private(set) var generation: UInt64 = 0
    /// True from a request until its completion lands or the slot is reset.
    public private(set) var isInFlight = false
    private var waiters: [(Bool) -> Void] = []

    public init() {}

    public var waiterCount: Int { waiters.count }

    /// Registers a render request and returns the generation `finish` must quote.
    public mutating func begin() -> UInt64 {
        generation &+= 1
        isInFlight = true
        return generation
    }

    /// Runs `waiter` with true when the latest render lands, or with false when the slot is reset first.
    /// The waiters are handed back by `finish` and `reset` rather than run here, so one that starts the
    /// next render does not overlap the mutation that released it.
    public mutating func wait(_ waiter: @escaping (Bool) -> Void) {
        waiters.append(waiter)
    }

    public mutating func finish(_ generation: UInt64) -> Completion {
        guard generation == self.generation, isInFlight else { return .superseded }
        isInFlight = false
        let released = waiters
        waiters = []
        return .landed(waiters: released)
    }

    /// Forgets any render in flight (the view was cleared or replaced); returns the waiters owed `false`.
    public mutating func reset() -> [(Bool) -> Void] {
        generation &+= 1
        isInFlight = false
        let released = waiters
        waiters = []
        return released
    }
}
