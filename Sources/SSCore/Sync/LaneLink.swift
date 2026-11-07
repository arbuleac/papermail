import Foundation

/// What the live lane and the backfill lane of one account share: each lane's waker, whether the account is
/// parked for sign-in, bodies the live lane handed over, and a fence that keeps a backfill page from landing on
/// top of a newer backfill.
///
/// A plain locked object rather than an actor so neither lane holds a reference to the other (no cycle to
/// keep an account's lanes alive after it is removed), and so the fence can run a short store write under
/// its lock without a suspension point in between.
final class LaneLink: @unchecked Sendable {
    /// `.poll` runs a full live cycle; `.operations` the outbox alone.
    let liveWaker = SyncWaker()
    /// Any signal means "look for work now" to the backfill lane.
    let backfillWaker = SyncWaker()

    private let lock = NSLock()
    private var parked = false
    private var parkRequest: String?
    /// Set at every start until the live lane's first cycle has got past the token. Until then the backfill waits,
    /// so a token refresh or a keychain read the user has to answer is asked for once, by the live lane, rather
    /// than by both lanes at the same moment.
    private var awaitingLiveCycle = false
    private var generation = 0
    private var replacing = false
    private var bodiesHandedOff = false

    // MARK: Parking

    /// Set while the account waits for sign-in, and at launch until the live lane's first cycle. The backfill lane
    /// sends nothing then; it looks again before every request, not only between turns.
    var isParked: Bool {
        lock.lock(); defer { lock.unlock() }
        return parked || awaitingLiveCycle
    }

    /// The live lane found the token (or the keychain) unusable.
    func park() {
        lock.lock(); defer { lock.unlock() }
        parked = true
    }

    /// The backfill lane found the token (or the keychain) unusable: park both lanes and have the live lane
    /// show `message` and wait for the user, as if its own request had failed.
    func requestPark(message: String) {
        lock.lock()
        parked = true
        parkRequest = message
        lock.unlock()
        liveWaker.signal(.operations)
    }

    /// The message of a park the backfill lane asked for, once.
    func takeParkRequest() -> String? {
        lock.lock(); defer { lock.unlock() }
        defer { parkRequest = nil }
        return parkRequest
    }

    /// The live lane completed a cycle, so the account works again; wakes the backfill lane when it was parked.
    /// A park the backfill lane asked for meanwhile stands: the live lane takes it next.
    func unpark() {
        lock.lock()
        let wasHeld = (parked || awaitingLiveCycle) && parkRequest == nil
        if wasHeld {
            parked = false
            awaitingLiveCycle = false
        }
        lock.unlock()
        if wasHeld { backfillWaker.signal(.poll) }
    }

    /// The live lane's cycle failed for a reason other than the token (a throttle, the network, a reset): the token
    /// was read, so the backfill may start. An account parked for sign-in stays parked.
    func liveCycleEnded() {
        lock.lock()
        let released = awaitingLiveCycle && !parked
        awaitingLiveCycle = false
        lock.unlock()
        if released { backfillWaker.signal(.poll) }
    }

    /// A fresh start (the engine started the lanes again) tries the token anew, the live lane first.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        parked = false
        parkRequest = nil
        awaitingLiveCycle = true
    }

    // MARK: Hand-off

    /// The live lane left bodies of mail it just brought in to the backfill lane (beyond its limit or its share of
    /// the quota, or fetches that failed). That is work from a request that went through, so it ends a failure
    /// backoff the backfill lane may be sitting out: the network that failed it is likely back.
    func handOffBodies() {
        lock.lock()
        bodiesHandedOff = true
        lock.unlock()
        backfillWaker.signal(.poll)
    }

    /// Whether bodies were handed off since the last call.
    func takeBodiesHandedOff() -> Bool {
        lock.lock(); defer { lock.unlock() }
        defer { bodiesHandedOff = false }
        return bodiesHandedOff
    }

    // MARK: Fence

    /// The backfill a backfill turn works for; nil while the live lane is replacing it (a head page or a reset).
    var backfillGeneration: Int? {
        lock.lock(); defer { lock.unlock() }
        return replacing ? nil : generation
    }

    /// Called by the live lane before it changes the account's backfill. Waits for a backfill write already
    /// under way, and from then on refuses every write of the backfill it replaces.
    func beginReplacingBackfill() {
        lock.lock(); defer { lock.unlock() }
        replacing = true
        generation += 1
    }

    /// The live lane is done changing the backfill, whether or not it succeeded; the backfill lane looks again.
    func endReplacingBackfill() {
        lock.lock()
        replacing = false
        generation += 1
        lock.unlock()
        backfillWaker.signal(.poll)
    }

    /// Runs `body` (store writes, no suspension) only while `generation` is still the current backfill, under
    /// the fence's lock so the live lane cannot replace the backfill half-way. Nil when it is stale.
    func ifCurrent<T>(_ generation: Int, _ body: () throws -> T) rethrows -> T? {
        lock.lock(); defer { lock.unlock() }
        guard !replacing, generation == self.generation else { return nil }
        return try body()
    }
}
