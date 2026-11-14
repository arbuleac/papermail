import Foundation

/// Sends queued messages once their undo window has passed.
///
/// Between sends it sleeps until the earliest held send falls due, or until woken: a send was queued, or the Mac
/// woke (`MailEngine.checkForMail`, which also runs when the app comes to the front and when the network returns).
/// An empty outbox keeps no timer faster than the background poll.
///
/// Claiming a send (scheduled → sending) and cancelling one both run under `claimLock`, so a message is never
/// both cancelled and sent. Only a throttle and a failure before any request left this Mac (no connection, a token
/// that could not be fetched: `ProviderError.neverLeftThisMac`) are retried: after any other failure the provider may
/// already have delivered the message and a retry would send it twice, so the send is marked failed for the user to see.
actor SendRunner {
    private let store: MailStoring
    private let registry: AccountRegistry
    private let claimLock: NSLock
    private let tuning: SyncTuning
    private let clock: SendClock
    private let waker: SyncWaker
    private let loop = LoopHandle()
    private var recoveredInterrupted = false
    /// Each held send's due time on `clock.uptime`, recorded when it is queued (`enqueue`) or throttled, so setting
    /// the Mac's clock neither sends a message inside its undo window nor holds it past its time, however late the
    /// runner first reads it (it may be delivering another send for a while). A send an earlier run left gets one at
    /// its first read (`dueTime`). Guarded by `claimLock`: `enqueue` writes it on the caller's thread.
    private nonisolated(unsafe) var held: [String: HeldSend] = [:]

    private struct HeldSend {
        let sendAfter: Date
        let due: TimeInterval
    }

    /// The wait timer and the clock can disagree by a hair when the timer fires exactly at the due time.
    private static let dueTolerance: TimeInterval = 0.01
    /// The SQLite store keeps `sendAfter` to the millisecond, so the time read back is not the one recorded in `held`.
    private static let storedTimePrecision: TimeInterval = 0.001

    init(store: MailStoring, registry: AccountRegistry, claimLock: NSLock, tuning: SyncTuning) {
        self.store = store
        self.registry = registry
        self.claimLock = claimLock
        self.tuning = tuning
        clock = tuning.sendClock
        waker = SyncWaker(sleep: tuning.sendClock.sleep)
    }

    nonisolated func start() {
        loop.start { [weak self] in await self?.run() }
    }

    nonisolated func stop() {
        loop.cancel()
    }

    nonisolated func stopAndWait() async {
        await loop.cancelAndWait()
    }

    /// Re-reads the outbox now instead of when the next held send falls due; called when a send is queued, and
    /// when the Mac wakes, in case the timer for a send that fell due meanwhile has not fired yet.
    nonisolated func wake() {
        waker.signal(.operations)
    }

    /// Stores a send held for `undoWindow` seconds, times the window on the continuous clock from now, and wakes
    /// the runner. Returns the pending send id.
    nonisolated func enqueue(_ message: OutgoingMessage, undoWindow: TimeInterval) throws -> String {
        let window = max(0, undoWindow)
        let due = clock.uptime() + window
        let pending = PendingSend(message: message, sendAfter: clock.now().addingTimeInterval(window))
        try store.enqueueSend(pending)
        // After the write and under the lock a claim holds for its whole read, so a claim that missed the row
        // cannot drop the time.
        claimLock.withLock { held[pending.id] = HeldSend(sendAfter: pending.sendAfter, due: due) }
        wake()
        return pending.id
    }

    /// Cancels a send that is still held. False once it has been claimed for sending, or was never queued.
    nonisolated func cancel(id: String) throws -> Bool {
        claimLock.lock(); defer { claimLock.unlock() }
        guard let send = try store.pendingSends().first(where: { $0.id == id }), send.status == .scheduled else {
            return false
        }
        try store.deleteSend(id: id)
        return true
    }

    private func run() async {
        recoverInterruptedSends()
        while !Task.isCancelled {
            let nextDue = await tick()
            // Every way the app queues a send wakes the runner, so with nothing held it has nothing to time. It still
            // looks at the background poll interval, the live lane's slowest, for a send stored by a path that did
            // not wake it, and so that a timer that did not fire (across sleep, say) costs no more than that.
            var timeout = tuning.pollInterval
            if let nextDue { timeout = min(timeout, max(0, nextDue - clock.uptime())) }
            _ = await waker.wait(timeout: timeout)
        }
    }

    /// A row left in `sending` by a previous process may or may not have gone out; nobody can tell, so it is
    /// reported as failed rather than silently sent twice.
    private func recoverInterruptedSends() {
        guard !recoveredInterrupted else { return }
        recoveredInterrupted = true
        claimLock.lock(); defer { claimLock.unlock() }
        guard let sends = try? store.pendingSends() else { return }
        for var send in sends where send.status == .sending {
            send.status = .failed
            send.lastError = "interrupted while sending; check Sent before sending again"
            try? store.updateSend(send)
        }
    }

    /// Sends everything that is due, one at a time. Returns when, on `clock.uptime`, the earliest send still held falls
    /// due.
    func tick() async -> TimeInterval? {
        // Reads again after every delivery: a throttled send is back in the outbox with a later time, which the read
        // before could not count, and a send queued meanwhile may be due already. Not once stopped (quit, leaving
        // the demo): a send claimed then would reach the provider under a cancelled task and fail as "cancelled",
        // where left scheduled it goes at the next launch.
        while !Task.isCancelled {
            let (claimed, nextDue) = claimNextDueSend()
            guard let claimed else { return nextDue }
            if Task.isCancelled {
                release(claimed)
                return nil
            }
            await deliver(claimed)
        }
        return nil
    }

    /// Puts a claimed send that never reached the provider back as it was before the claim.
    private func release(_ send: PendingSend) {
        claimLock.lock(); defer { claimLock.unlock() }
        var send = send
        send.status = .scheduled
        send.attempts -= 1
        try? store.updateSend(send)
    }

    /// Marks the first due send as `sending` under the claim lock, so `cancel` can no longer take it, and leaves the
    /// others held. One at a time: a crash or a force quit leaves in doubt ("interrupted while sending") only the send
    /// actually handed to the provider, never one claimed beside it and not yet tried, and Undo can still take those.
    /// An extra read of the small outbox per send that falls due beside another; nothing on the poll's path.
    private func claimNextDueSend() -> (claimed: PendingSend?, nextDue: TimeInterval?) {
        claimLock.lock(); defer { claimLock.unlock() }
        var claimed: PendingSend?
        var nextDue: TimeInterval?
        do {
            let now = clock.now()
            let uptime = clock.uptime()
            var stillHeld: [String: HeldSend] = [:]
            for var send in try store.pendingSends() where send.status == .scheduled {
                let due = dueTime(of: send, now: now, uptime: uptime)
                if claimed == nil, due <= uptime + Self.dueTolerance {
                    send.status = .sending
                    send.attempts += 1
                    try store.updateSend(send)
                    claimed = send
                } else {
                    stillHeld[send.id] = HeldSend(sendAfter: send.sendAfter, due: due)
                    nextDue = nextDue.map { min($0, due) } ?? due
                }
            }
            held = stillHeld
        } catch {
            SyncLog.logger.error("send: could not read the outbox: \(String(describing: error), privacy: .private)")
        }
        return (claimed, nextDue)
    }

    /// A send this run queued or throttled keeps the due time recorded then. One an earlier run left is timed by
    /// the wall clock, once, and that clock may have been set since; so it is held no longer than the runner ever
    /// holds a send itself, a throttle's retry (`userRetryAfterCap`; the app's undo windows are shorter), and a
    /// clock set back between runs cannot keep it in the outbox for the size of the jump.
    private func dueTime(of send: PendingSend, now: Date, uptime: TimeInterval) -> TimeInterval {
        if let known = held[send.id], abs(known.sendAfter.timeIntervalSince(send.sendAfter)) < Self.storedTimePrecision {
            return known.due
        }
        return uptime + min(max(0, send.sendAfter.timeIntervalSince(now)), tuning.userRetryAfterCap)
    }

    private func deliver(_ send: PendingSend) async {
        var send = send
        let accountID = send.message.accountID
        guard let context = registry.context(for: accountID) else {
            send.status = .failed
            send.lastError = "account is not available"
            try? store.updateSend(send)
            return
        }
        do {
            _ = try await context.provider.send(send.message)
            send.status = .sent
            try? store.updateSend(send)
            try? store.deleteSend(id: send.id)
            SyncLog.logger.info("send: delivered for \(accountID.rawValue, privacy: .public)")
            // The sent copy arrives through a poll; ask for it now rather than at the next interval.
            context.syncer.wake(.poll)
        } catch ProviderError.throttled(let retryAfter) {
            let delay = Backoff.throttleDelay(
                retryAfter: retryAfter, attempt: send.attempts, base: tuning.backoffBase, cap: tuning.userRetryAfterCap
            )
            reschedule(send, after: delay, error: ProviderError.throttled(retryAfter: retryAfter))
        } catch let error as ProviderError where error.neverLeftThisMac {
            // Nothing reached the provider (no network yet at wake, a token refresh that could not connect), so going
            // again cannot send the message twice. It waits as a throttled send does, and a wake (the network coming
            // back, the Mac waking) looks again sooner.
            let delay = Backoff.delay(attempt: send.attempts, base: tuning.backoffBase, cap: tuning.userRetryAfterCap)
            SyncLog.logger.notice("send: not sent for \(accountID.rawValue, privacy: .public), no connection; trying again in \(delay, privacy: .public) s")
            reschedule(send, after: delay, error: error)
        } catch {
            let description = SyncErrorDescription.describe(error)
            send.status = .failed
            send.lastError = description
            try? store.updateSend(send)
            SyncLog.logger.error("send: failed for \(accountID.rawValue, privacy: .public): \(description, privacy: .private)")
        }
    }

    /// Puts a send back in the outbox to go again in `delay` seconds, timed on the continuous clock from now.
    private func reschedule(_ send: PendingSend, after delay: TimeInterval, error: ProviderError) {
        var send = send
        let due = clock.uptime() + delay
        send.status = .scheduled
        send.sendAfter = clock.now().addingTimeInterval(delay)
        send.lastError = SyncErrorDescription.describe(error)
        try? store.updateSend(send)
        claimLock.withLock { held[send.id] = HeldSend(sendAfter: send.sendAfter, due: due) }
    }
}
