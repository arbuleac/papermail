import Foundation

/// Paces one account's backfill lane so the older-mail download stays inside the provider's quota instead of
/// spending past it, getting throttled and losing the work in flight.
///
/// A token bucket in provider units, refilled continuously at the backfill's share of the provider's rate
/// times `rateFraction`. The live lane is never delayed: it reports what it spent and that comes out of the
/// same bucket, so a busy live lane slows the backfill and never the reverse.
///
/// The live lane's spend also comes out of an allowance of its own: the share the backfill leaves, refilled at that
/// share of the rate, holding one minute of it and owing one minute, or all of a single cost beyond that. Nothing
/// waits on it; the live lane looks at it before what it can put off (the next page after a dear changes page,
/// prefetching new bodies), so its own bursts stay inside the provider's limit too. Gmail refuses a few thousand
/// units spent in a few seconds well before a minute's 6,000.
///
/// A throttle means the bucket's picture of the provider was wrong, so the backfill halves its rate (AIMD),
/// drops whatever credit it held and pauses until the provider's retry time or an exponential delay. Every quiet
/// minute after the pause wins back a tenth of the rate. Recovery and refill are worked out from timestamps when
/// someone asks, so nothing runs while the lane is idle.
///
/// Under an unmetered quota (`ProviderQuota.unlimited`) nothing waits: not for units and not for a throttle.
actor QuotaBudget {
    nonisolated let quota: ProviderQuota
    /// The most the live lane's allowance holds: a minute of its share (2,000 Gmail units, 333 Graph requests). Zero
    /// when its spend is not counted (unmetered, or a backfill given the whole allowance).
    nonisolated let liveCapacity: Double

    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    /// No unit is ever counted, so no arithmetic can turn an infinite allowance into NaN.
    private let unmetered: Bool
    /// Units per second at a `rateFraction` of 1.
    private let fullRate: Double
    private let capacity: Double

    private var tokens: Double
    private var lastRefill: Date
    /// The live lane's allowance: units per second, what it holds now (negative while it owes).
    private let liveRate: Double
    private var liveTokens: Double
    private var liveLastRefill: Date
    /// The latest clock reading, to notice the wall clock stepping back.
    private var lastSeen: Date
    /// `rateFraction` at `quietSince`; it climbs from there.
    private var baseFraction = QuotaBudget.initialFraction
    /// When the current stretch without a throttle began: creation, or the end of the last pause. The bucket
    /// refills and the rate recovers only from then, which keeps a pause from banking credit or recovery that
    /// the backfill would spend in a burst the moment it resumes.
    private var quietSince: Date
    private var pauseEnd: Date?
    private var consecutiveThrottles = 0
    /// Whether the backfill has been let through since the last throttle. Until it has, a success answers a
    /// request sent before the throttle and says nothing about whether the provider has calmed down.
    private var grantedSinceThrottle = true

    /// One caller at a time works out its wait and spends, in arrival order. If each slept for its own shortfall,
    /// whoever needed least would wake first and take the refill, and a metadata batch could wait behind body
    /// fetches for as long as there were any.
    private var unitTurn = FIFOGate(capacity: 1)
    private var slots: FIFOGate
    private var nextTicket: UInt64 = 0

    /// Half speed at first: the provider may already be counting spend from before this budget existed (a
    /// relaunch mid-download), and recovery reaches full speed within five quiet minutes anyway.
    private static let initialFraction = 0.5
    /// The floor for repeated halving, so the backfill always creeps forward and recovery has something to grow.
    private static let minimumFraction = 0.05
    private static let recoveryStep = 0.1
    private static let recoveryInterval: TimeInterval = 60
    /// Seconds of the full backfill rate the bucket holds: enough for a few batches back to back, little enough
    /// that a burst on top of steady spend stays well inside a provider's per-minute window.
    private static let burstSeconds: TimeInterval = 15
    /// Seconds of its rate the live allowance holds. One minute: a full Gmail changes page (about 2,000 units, the
    /// whole allowance) goes at once, and a run of them continues at about one a minute.
    private static let liveBurstSeconds: TimeInterval = 60
    /// The deepest the bucket can owe, in capacities. Debt is real spend and must slow the backfill, but a live
    /// burst (a big send, a run of new mail) must not starve it for long after the burst ends.
    private static let debtFloorCapacities = 4.0
    /// The deepest the live allowance can owe for a single cost, in allowances (minutes of its share): far beyond any
    /// page a provider sends (a Graph call that looked up a thousand removals is about three), so only a figure
    /// gone wrong is cut short, and it then holds the live lane's dear pages back ten minutes at most.
    private static let liveDebtFloorAllowances = 10.0
    private static let pauseBase: TimeInterval = 15
    private static let pauseCap: TimeInterval = 600
    /// A "retry after 0" must not turn the next attempt into a hot loop.
    private static let minimumRetryAfter: TimeInterval = 1
    /// A provider retry time beyond an hour reads as a parsing slip rather than advice; asking again hourly
    /// costs one request, and the provider can repeat it.
    private static let maximumRetryAfter: TimeInterval = 3600
    /// The bucket never plans a wait near this long, but a duration that overflowed would trap in `Task.sleep`,
    /// so no single sleep is handed more; the loop simply waits again.
    private static let longestSleep: TimeInterval = 3600
    private static let shortestSleep: TimeInterval = 0.001
    private static let stepSlack: TimeInterval = 0.000_001

    init(
        quota: ProviderQuota,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        }
    ) {
        self.quota = quota
        self.now = now
        self.sleep = sleep
        let rate = quota.unitsPerMinute * quota.backfillShare / 60
        // An infinite allowance is meant to be unmetered. A zero or invalid one counts the same, because pacing
        // by it would stall the backfill forever, which is worse than not pacing it.
        unmetered = !(rate.isFinite && rate > 0)
        fullRate = unmetered ? 0 : rate
        capacity = fullRate * Self.burstSeconds
        tokens = capacity
        let liveShare = max(0, 1 - quota.backfillShare)
        let live = unmetered ? 0 : quota.unitsPerMinute * liveShare / 60
        // A backfill given the whole allowance leaves the live lane nothing to count against: unlimited, as before.
        liveRate = live.isFinite && live > 0 ? live : 0
        liveCapacity = liveRate * Self.liveBurstSeconds
        liveTokens = liveCapacity
        slots = FIFOGate(capacity: max(1, quota.maxBackfillConcurrency))
        let start = now()
        lastRefill = start
        liveLastRefill = start
        lastSeen = start
        quietSince = start
    }

    // MARK: Units

    /// Waits until the backfill may spend `cost` units, then spends them. Callers are served in the order they
    /// asked, whatever each one costs. A cost above the bucket's capacity waits for a full bucket and goes into
    /// debt, so an oversized request is slow but never stuck. Throws `CancellationError` when the calling task is
    /// cancelled; nothing is spent then, and a caller that was being served hands its turn to the next.
    func acquireBackfill(_ cost: Double) async throws {
        let cost = cost.isNaN ? 0 : max(0, cost)
        if unmetered {
            try Task.checkCancellation()
            return
        }
        try await enter(.unitTurn)
        defer { leave(.unitTurn) }
        while true {
            try Task.checkCancellation()
            let current = readClock()
            if let pauseEnd, current < pauseEnd {
                try await sleep(Self.bounded(pauseEnd.timeIntervalSince(current)))
                continue
            }
            refill(to: current)
            let needed = min(cost, capacity)
            let offset = current.timeIntervalSince(quietSince)
            let rate = fullRate * fraction(atOffset: offset)
            // Within a millisecond's refill counts as covered: waking when the deficit should be paid off must not
            // turn date rounding into a second sliver of a sleep.
            if needed - tokens <= rate * Self.shortestSleep {
                spend(cost)
                grantedSinceThrottle = true
                return
            }
            var wait = (needed - tokens) / rate
            // The rate rises at the next recovery step; waking there re-plans at the faster rate.
            if let step = nextStepOffset(after: offset) { wait = min(wait, step - offset) }
            try await sleep(Self.bounded(wait))
        }
    }

    /// Records units a backfill request spent beyond what it took before going out: a call that reports it sent more
    /// than it was priced at. Never waits, since the request has gone; the backfill's next request waits for it.
    func recordBackfill(_ cost: Double) {
        guard !unmetered, !cost.isNaN, cost > 0 else { return }
        refill(to: readClock())
        spend(cost)
    }

    /// Records units the live lane spent. Never waits: the live lane carries new mail and the user's actions.
    func recordLive(_ cost: Double) {
        guard !unmetered, !cost.isNaN, cost > 0 else { return }
        let current = readClock()
        refill(to: current)
        spend(cost)
        guard liveRate > 0 else { return }
        refillLive(to: current)
        // Spend spread over many costs (an opened conversation's bodies) owes a minute at most, so it never holds the
        // live lane back for long. A single cost beyond the allowance is owed in full: cut to a minute, a Graph page
        // of a thousand requests would be paced as if it cost 666 and a run of them would outrun the share. The cut
        // never raises the balance, so a small cost after such a page cannot forgive what the page still owes.
        let floor = min(max(liveCapacity, cost), Self.liveDebtFloorAllowances * liveCapacity)
        liveTokens = max(liveTokens - cost, min(liveTokens, -floor))
    }

    /// What the live lane can still spend in a burst without going past its share; negative while it owes.
    /// Infinite when its spend is not counted (unmetered).
    var liveHeadroom: Double {
        guard liveRate > 0 else { return .infinity }
        refillLive(to: readClock())
        return liveTokens
    }

    /// Seconds until the live lane's allowance covers `cost`, zero when it already does. A cost above the whole
    /// allowance waits only for a full one, so a big page is late but never stuck; the last such page left a debt of
    /// all it cost beyond the allowance (`recordLive`), so the wait still lasts as long as that page took to earn.
    func liveWait(for cost: Double) -> TimeInterval {
        guard liveRate > 0, !cost.isNaN else { return 0 }
        refillLive(to: readClock())
        let needed = min(max(0, cost), liveCapacity)
        guard liveTokens < needed else { return 0 }
        return (needed - liveTokens) / liveRate
    }

    /// Callers waiting for their turn at the units behind the one being served.
    var backfillUnitWaiters: Int { unitTurn.waiters.count }

    // MARK: Throttles

    /// The provider throttled a backfill request: halve the rate and pause the backfill until `retryAfter`
    /// (at least a second) or, without one, 15 s doubling per consecutive throttle up to 10 minutes.
    /// Returns when the backfill resumes. Unmetered, nothing pauses and it returns now: the caller keeps its own
    /// retry schedule there.
    @discardableResult
    func backfillThrottled(retryAfter: TimeInterval?) -> Date {
        let current = readClock()
        guard !unmetered else { return current }
        let hint = retryAfter.flatMap { $0.isFinite ? min(max($0, Self.minimumRetryAfter), Self.maximumRetryAfter) : nil }
        if let pauseEnd, current < pauseEnd {
            // Requests already in flight when the first throttle came back are throttled too. They are the same
            // event, and counting each would halve the rate and double the pause several times over.
            let resume = hint.map { max(pauseEnd, current.addingTimeInterval($0)) } ?? pauseEnd
            self.pauseEnd = resume
            quietSince = resume
            return resume
        }
        refill(to: current)
        baseFraction = max(Self.minimumFraction, fraction(atOffset: current.timeIntervalSince(quietSince)) / 2)
        consecutiveThrottles += 1
        let delay = hint ?? Backoff.delay(attempt: consecutiveThrottles, base: Self.pauseBase, cap: Self.pauseCap)
        let resume = current.addingTimeInterval(delay)
        tokens = min(tokens, 0)
        pauseEnd = resume
        quietSince = resume
        grantedSinceThrottle = false
        return resume
    }

    /// A backfill request went through: the next throttle starts the pause schedule from the beginning. Ignored
    /// until the backfill has been let through again since the last throttle, because until then the success
    /// came from a request sent before it, and counting it would keep the pause from ever growing past 15 s.
    func backfillSucceeded() {
        guard grantedSinceThrottle else { return }
        consecutiveThrottles = 0
    }

    /// When a throttled backfill resumes; nil when it is not paused.
    var pausedUntil: Date? {
        let current = readClock()
        guard let pauseEnd, current < pauseEnd else { return nil }
        return pauseEnd
    }

    /// The share of the backfill's full rate it currently runs at.
    var rateFraction: Double {
        fraction(atOffset: readClock().timeIntervalSince(quietSince))
    }

    // MARK: Slots

    /// Waits for one of `maxBackfillConcurrency` backfill slots, first come first served. Throws
    /// `CancellationError` when the calling task is cancelled, and then holds no slot; once it returns, the
    /// caller holds one and must give it back with `releaseBackfillSlot()`.
    func acquireBackfillSlot() async throws {
        try await enter(.slots)
    }

    /// Gives back a slot from `acquireBackfillSlot()`, handing it straight to the longest waiter if there is one.
    func releaseBackfillSlot() {
        leave(.slots)
    }

    /// Slots currently held, including ones handed to a waiter that has not resumed yet.
    var backfillSlotsInUse: Int { slots.holders }
    /// Tasks queued for a slot.
    var backfillSlotWaiters: Int { slots.waiters.count }

    // MARK: Queues

    /// Places handed out first come, first served: up to `capacity` holders at once, the rest queued in the order
    /// they asked.
    private struct FIFOGate {
        let capacity: Int
        var holders = 0
        var waiters: [(ticket: UInt64, continuation: CheckedContinuation<Void, Error>)] = []

        /// Takes a place at once when one is free and nobody is queued ahead.
        mutating func enterIfFree() -> Bool {
            guard waiters.isEmpty, holders < capacity else { return false }
            holders += 1
            return true
        }

        /// Gives a place back, handing it straight to the longest waiter so nobody can slip in ahead of it.
        mutating func leave() {
            if waiters.isEmpty {
                holders = max(0, holders - 1)
            } else {
                waiters.removeFirst().continuation.resume()
            }
        }

        mutating func cancel(_ ticket: UInt64) {
            guard let index = waiters.firstIndex(where: { $0.ticket == ticket }) else { return }
            waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        }
    }

    private enum GateID: Sendable {
        case unitTurn, slots
    }

    private func withGate<T>(_ id: GateID, _ body: (inout FIFOGate) -> T) -> T {
        switch id {
        case .unitTurn: return body(&unitTurn)
        case .slots: return body(&slots)
        }
    }

    /// Waits for a place in the gate. Throws `CancellationError`, holding nothing, when the task is cancelled.
    private func enter(_ id: GateID) async throws {
        try Task.checkCancellation()
        if withGate(id, { $0.enterIfFree() }) { return }
        let ticket = nextTicket
        nextTicket &+= 1
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                withGate(id) { $0.waiters.append((ticket, continuation)) }
                // A cancellation that landed before the waiter was queued found nothing to cancel.
                if Task.isCancelled { withGate(id) { $0.cancel(ticket) } }
            }
        } onCancel: {
            Task { await self.cancelWaiter(ticket, at: id) }
        }
        // The place was handed over just as the task was cancelled: pass it on rather than keep it.
        if Task.isCancelled {
            leave(id)
            throw CancellationError()
        }
    }

    private func leave(_ id: GateID) {
        withGate(id) { $0.leave() }
    }

    private func cancelWaiter(_ ticket: UInt64, at id: GateID) {
        withGate(id) { $0.cancel(ticket) }
    }

    // MARK: Bucket

    /// Reads the clock. When the wall clock steps back (the default clock is `Date()`), every stored time moves
    /// back with it, as if the step never happened; left alone, refill, recovery and any pause would stand still
    /// until the clock caught up again.
    private func readClock() -> Date {
        let date = now()
        if date < lastSeen {
            let step = lastSeen.timeIntervalSince(date)
            lastRefill.addTimeInterval(-step)
            liveLastRefill.addTimeInterval(-step)
            quietSince.addTimeInterval(-step)
            pauseEnd = pauseEnd?.addingTimeInterval(-step)
        }
        lastSeen = date
        return date
    }

    private func spend(_ cost: Double) {
        tokens = max(tokens - cost, -Self.debtFloorCapacities * capacity)
    }

    /// Adds what the bucket earned since the last refill, in segments between recovery steps so a rate that rose
    /// mid-way is credited at each rate for its own stretch.
    private func refill(to date: Date) {
        guard date > lastRefill else { return }
        let start = max(lastRefill, quietSince)
        lastRefill = date
        guard date > start else { return }
        var offset = start.timeIntervalSince(quietSince)
        let end = date.timeIntervalSince(quietSince)
        while offset < end, tokens < capacity {
            let segmentEnd = min(end, nextStepOffset(after: offset) ?? end)
            tokens = min(capacity, tokens + (segmentEnd - offset) * fullRate * fraction(atOffset: offset))
            offset = segmentEnd
        }
    }

    /// The live allowance refills at its own steady rate: a throttle on the backfill says nothing about it.
    private func refillLive(to date: Date) {
        guard date > liveLastRefill else { return }
        liveTokens = min(liveCapacity, liveTokens + date.timeIntervalSince(liveLastRefill) * liveRate)
        liveLastRefill = date
    }

    /// The rate fraction `offset` seconds after `quietSince`.
    private func fraction(atOffset offset: TimeInterval) -> Double {
        let steps = Self.recoverySteps(atOffset: offset)
        return steps > 0 ? min(1, baseFraction + steps * Self.recoveryStep) : baseFraction
    }

    /// The offset of the next recovery step after `offset`, or nil once the rate is at the top. Always later
    /// than `offset`, so a segmented loop over it always moves forward.
    private func nextStepOffset(after offset: TimeInterval) -> TimeInterval? {
        guard fraction(atOffset: offset) < 1 else { return nil }
        return (Self.recoverySteps(atOffset: offset) + 1) * Self.recoveryInterval
    }

    /// Whole recovery intervals elapsed at `offset`. An offset a hair short of a step counts as on it: a wait
    /// planned to end at the step lands there give or take date rounding, and should see the new rate.
    private static func recoverySteps(atOffset offset: TimeInterval) -> Double {
        guard offset > 0 else { return 0 }
        return ((offset + stepSlack) / recoveryInterval).rounded(.down)
    }

    private static func bounded(_ wait: TimeInterval) -> TimeInterval {
        guard wait.isFinite else { return longestSleep }
        return min(max(wait, shortestSleep), longestSleep)
    }
}
