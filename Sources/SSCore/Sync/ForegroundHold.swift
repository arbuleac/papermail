import Foundation

/// The reader's body fetches under way for one account (`MailClient.ensureBody`), which the account's background work
/// waits behind: a backfill request does not go out while one is waiting or on its way (`QuotaBudget.acquireBackfill`),
/// and the live lane's prefetch of new mail's bodies and the calendar's read wait for them up to a limit.
///
/// The provider counts what is in flight together (Gmail's per-user concurrency, Graph's four requests per mailbox at
/// once), so a body the user is waiting for, sent beside a full batch of background fetches, could queue behind them or
/// be refused with a throttle. Holding the background back while the user waits keeps the line clear for it.
///
/// The hold outlasts the last fetch by `linger`: the reader asks for a conversation's folded bodies once its opened one
/// has landed and been drawn, and the user often opens the next conversation a moment later, so a background request let
/// through in between would take the provider's place just as the next foreground request needs it.
///
/// A lock, not an actor: the hydrator enters and leaves without a hop, and a wait is a continuation released when the
/// hold ends.
final class ForegroundHold: @unchecked Sendable {
    /// How long the hold lasts after the last fetch leaves.
    let linger: TimeInterval
    private let lock = NSLock()
    private var active = 0
    /// Bumped by every enter, so a linger that ends after the hold was taken again lets nobody go.
    private var generation: UInt64 = 0
    private var lingering = false
    private var nextTicket: UInt64 = 0
    /// Tickets handed out whose wait has not ended.
    private var pending: Set<UInt64> = []
    private var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
    /// How many background requests waited behind a fetch since the hold was made; for tests and the log.
    private var heldCount = 0

    init(linger: TimeInterval = 0.25) {
        self.linger = linger
    }

    /// Whether a foreground fetch is waiting or on its way, or the last one left less than `linger` ago.
    var isActive: Bool {
        lock.withLock { held }
    }

    private var held: Bool { active > 0 || lingering }

    /// Background waits that began while the hold was active.
    var backgroundWaits: Int {
        lock.withLock { heldCount }
    }

    func enter() {
        lock.withLock {
            active += 1
            generation &+= 1
        }
    }

    /// Ends one fetch. When the last leaves, the hold lingers, then lets every waiting background request go unless a
    /// fetch came in meanwhile.
    func leave() {
        let ending: UInt64? = lock.withLock {
            active = max(0, active - 1)
            guard active == 0 else { return nil }
            lingering = true
            return generation
        }
        guard let ending else { return }
        guard linger > 0 else {
            endLinger(ending)
            return
        }
        Task { [weak self, linger] in
            try? await Task.sleep(for: .seconds(linger))
            self?.endLinger(ending)
        }
    }

    private func endLinger(_ ending: UInt64) {
        let released: [CheckedContinuation<Void, Never>] = lock.withLock {
            guard generation == ending, active == 0 else { return [] }
            lingering = false
            let waiting = Array(waiters.values)
            pending.subtract(waiters.keys)
            waiters = [:]
            return waiting
        }
        for continuation in released { continuation.resume() }
    }

    /// Returns once no foreground fetch is waiting or on its way, at once when none is. With a `limit` it returns after
    /// that many seconds whatever is under way, so a fetch that hangs until its timeout cannot hold that work for
    /// longer. Cancellation ends the wait; the caller checks for it.
    func waitUntilIdle(limit: TimeInterval? = nil) async {
        let ticket: UInt64? = lock.withLock {
            guard held else { return nil }
            nextTicket &+= 1
            pending.insert(nextTicket)
            heldCount += 1
            return nextTicket
        }
        guard let ticket else { return }
        let timer = limit.map { seconds in
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(max(0, seconds)))
                self?.release(ticket)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    // Released (the hold ended, the limit passed, the task was cancelled) before it could be queued.
                    guard held, pending.contains(ticket) else {
                        pending.remove(ticket)
                        return true
                    }
                    waiters[ticket] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            release(ticket)
        }
        timer?.cancel()
    }

    private func release(_ ticket: UInt64) {
        let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
            guard pending.remove(ticket) != nil else { return nil }
            return waiters.removeValue(forKey: ticket)
        }
        continuation?.resume()
    }
}
