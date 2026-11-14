import Foundation

/// Sends queued messages once their undo window has passed, and Send Later messages at the time the user chose.
///
/// Between sends it sleeps until the earliest held send falls due, or until woken: a send was queued, or the Mac
/// woke (`MailEngine.checkForMail`, which also runs when the app comes to the front and when the network returns),
/// or the wall clock was set, which a Send Later time is kept on. An empty outbox keeps no timer faster than the
/// background poll.
///
/// Claiming a send (scheduled or later → sending) and cancelling one both run under `claimLock`, so a message is never
/// both cancelled and sent. Only a throttle and a failure before any request left this Mac (no connection,
/// `ProviderError.neverLeftThisMac`; a token that could not be fetched, an `AuthError`) are retried: after any other
/// failure the provider may already have delivered the message and a retry would send it twice, so the send is marked
/// failed for the user to see.
///
/// A Send Later time that passed while the app was closed is never sent at launch: the runner's first read marks it
/// `missed`, which it never claims, and the app asks the user (spec §5.23); `sendNow` sends it once they say so.
///
/// It reads the outbox as summaries (`MailStoring.pendingSendSummaries`), which leave the attachments out, and writes only
/// a send's state back: a Send Later message waits for days, and the runner looks at the outbox at every poll interval.
/// The whole message is read once, for the provider.
actor SendRunner {
    private let store: MailStoring
    private let registry: AccountRegistry
    private let claimLock: NSLock
    private let tuning: SyncTuning
    private let clock: SendClock
    private let waker: SyncWaker
    private let loop = LoopHandle()
    private var recoveredPreviousRun = false
    /// Each held send's due time on `clock.uptime`, recorded when it is queued (`enqueue`) or throttled, so setting
    /// the Mac's clock neither sends a message inside its undo window nor holds it past its time, however late the
    /// runner first reads it (it may be delivering another send for a while). A send an earlier run left gets one at
    /// its first read (`dueTime`). Guarded by `claimLock`: `enqueue` writes it on the caller's thread.
    private nonisolated(unsafe) var held: [String: HeldSend] = [:]

    private struct HeldSend {
        let sendAfter: Date
        let due: TimeInterval
        /// Held after a failure before the request left this Mac (no connection, no token): `wakeForConnection`, which
        /// comes when the network may be back, makes it due at once instead of at the end of its backoff.
        var retryOnWake = false
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
    /// when the wall clock is set.
    nonisolated func wake() {
        waker.signal(.operations)
    }

    /// The Mac woke, the app came to the front or the network returned (`MailEngine.checkForMail`): re-reads the
    /// outbox, in case the timer for a send that fell due meanwhile has not fired yet, and sends now what is waiting
    /// out the backoff of a failure that never left this Mac, rather than up to a minute after the connection is back.
    nonisolated func wakeForConnection() {
        let now = clock.uptime()
        claimLock.withLock {
            for (id, send) in held where send.retryOnWake {
                held[id] = HeldSend(sendAfter: send.sendAfter, due: now)
            }
        }
        wake()
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

    /// Stores a Send Later message held until `date` on the wall clock (the time the user chose, which daylight saving
    /// and a clock set by hand move with the wall), with the draft it was written in, and wakes the runner. Returns the
    /// pending send id.
    nonisolated func enqueueLater(_ message: OutgoingMessage, at date: Date, draftID: UUID?) throws -> String {
        let pending = PendingSend(message: message, createdAt: clock.now(), sendAfter: date, status: .later, draftID: draftID)
        try store.enqueueSend(pending)
        wake()
        return pending.id
    }

    /// Cancels a send that is still held: in its undo window, waiting for its Send Later time, or missed while the app
    /// was closed. False once it has been claimed for sending, or was never queued.
    nonisolated func cancel(id: String) throws -> Bool {
        claimLock.lock(); defer { claimLock.unlock() }
        guard let send = try store.pendingSendSummaries().first(where: { $0.id == id }),
              send.status == .scheduled || send.isHeldForLater else {
            return false
        }
        try store.deleteSend(id: id)
        return true
    }

    /// Sends these Send Later messages now, whether their time has come or was missed while the app was closed (the user
    /// said Send Now). Returns the ids it found still held; the rest had gone, or been cancelled.
    nonisolated func sendNow(ids: [String]) throws -> [String] {
        let wanted = Set(ids)
        var released: [String] = []
        try claimLock.withLock {
            let now = clock.now()
            for var send in try store.pendingSendSummaries() where wanted.contains(send.id) && send.isHeldForLater {
                // Still `later`, not `scheduled`: if the app quits before it goes, the next launch asks again rather than
                // sending a message the user may since have thought better of.
                send.status = .later
                send.sendAfter = now
                try store.updateSend(send)
                released.append(send.id)
            }
        }
        if !released.isEmpty { wake() }
        return released
    }

    private func run() async {
        recoverPreviousRun()
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

    /// What the previous process left, read once before the first claim. A row left in `sending` may or may not have
    /// gone out; nobody can tell, so it is reported as failed rather than silently sent twice. A Send Later time that
    /// passed while the app was closed becomes `missed`: the user may have changed their mind meanwhile, so it waits for
    /// them to say (spec §5.23) instead of going the moment the app opens. So does a Send Later message a throttle put
    /// back to retry (`scheduled`, still carrying its draft id) whose retry time passed while the app was closed: it is
    /// that message, not an undo-send left behind, which goes within a minute of launch.
    private func recoverPreviousRun() {
        guard !recoveredPreviousRun else { return }
        recoveredPreviousRun = true
        claimLock.lock(); defer { claimLock.unlock() }
        guard let sends = try? store.pendingSendSummaries() else { return }
        let now = clock.now()
        for var send in sends {
            switch send.status {
            case .sending:
                send.status = .failed
                send.lastError = "interrupted while sending; check Sent before sending again"
            case .later where send.sendAfter <= now:
                send.status = .missed
            case .scheduled where send.draftID != nil && send.sendAfter <= now:
                send.status = .missed
            default:
                continue
            }
            try? store.updateSend(send)
        }
    }

    /// Sends everything that is due, one at a time. Returns when, on `clock.uptime`, the earliest send still held falls
    /// due.
    func tick() async -> TimeInterval? {
        // Reads again after every delivery: a throttled send is back in the outbox with a later time, which the read
        // before could not count, and a send queued meanwhile may be due already. Not once stopped (quit, leaving
        // the demo): a send claimed then would reach the provider under a cancelled task and fail as "cancelled",
        // where left scheduled (or later) it goes, or is asked about, at the next launch.
        while !Task.isCancelled {
            let (claimed, nextDue) = claimNextDueSend()
            guard let claimed else { return nextDue }
            if Task.isCancelled {
                release(claimed)
                return nil
            }
            await deliver(claimed.send)
        }
        return nil
    }

    /// A send marked `sending`, with the status it had before: a stop puts it back as it was.
    private struct Claim {
        var send: PendingSendSummary
        let from: PendingSendStatus
    }

    /// Puts a claimed send that never reached the provider back as it was before the claim: a Send Later message
    /// waits for its time again, so the next launch asks about it rather than sending it.
    private func release(_ claim: Claim) {
        claimLock.lock(); defer { claimLock.unlock() }
        var send = claim.send
        send.status = claim.from
        send.attempts -= 1
        try? store.updateSend(send)
    }

    /// Marks the first due send as `sending` under the claim lock, so `cancel` can no longer take it, and leaves the
    /// others held. One at a time: a crash or a force quit leaves in doubt ("interrupted while sending") only the send
    /// actually handed to the provider, never one claimed beside it and not yet tried, and Undo can still take those.
    /// An extra read of the small outbox per send that falls due beside another; nothing on the poll's path.
    private func claimNextDueSend() -> (claimed: Claim?, nextDue: TimeInterval?) {
        claimLock.lock(); defer { claimLock.unlock() }
        var claimed: Claim?
        var nextDue: TimeInterval?
        do {
            let now = clock.now()
            let uptime = clock.uptime()
            var stillHeld: [String: HeldSend] = [:]
            for var send in try store.pendingSendSummaries() where send.status == .scheduled || send.status == .later {
                let due = dueTime(of: send, now: now, uptime: uptime)
                if claimed == nil, due <= uptime + Self.dueTolerance {
                    let from = send.status
                    send.status = .sending
                    send.attempts += 1
                    try store.updateSend(send)
                    claimed = Claim(send: send, from: from)
                } else {
                    if send.status == .scheduled {
                        let retryOnWake = held[send.id].map { Self.isHeld($0, as: send) && $0.retryOnWake } ?? false
                        stillHeld[send.id] = HeldSend(sendAfter: send.sendAfter, due: due, retryOnWake: retryOnWake)
                    }
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
    ///
    /// A Send Later message is timed by the wall clock at every read instead: its time is one the user named on the
    /// wall (“Monday 09:00”), so setting the clock moves it as it moves the meeting it was written for. The engine wakes
    /// the runner when the clock is set, which a wait on the continuous clock cannot see.
    private func dueTime(of send: PendingSendSummary, now: Date, uptime: TimeInterval) -> TimeInterval {
        if send.status == .later {
            return uptime + max(0, send.sendAfter.timeIntervalSince(now))
        }
        if let known = held[send.id], Self.isHeld(known, as: send) {
            return known.due
        }
        return uptime + min(max(0, send.sendAfter.timeIntervalSince(now)), tuning.userRetryAfterCap)
    }

    /// Whether `known` was recorded for the send as it is stored now: the same time, read back to the millisecond.
    private static func isHeld(_ known: HeldSend, as send: PendingSendSummary) -> Bool {
        abs(known.sendAfter.timeIntervalSince(send.sendAfter)) < storedTimePrecision
    }

    private func deliver(_ send: PendingSendSummary) async {
        var send = send
        let accountID = send.accountID
        guard let context = registry.context(for: accountID) else {
            send.status = .failed
            send.lastError = "account is not available"
            try? store.updateSend(send)
            return
        }
        let message: OutgoingMessage
        do {
            // The claim read the outbox without the attachments; the provider needs them. A row gone meanwhile went with
            // its account.
            guard let whole = try store.pendingSend(id: send.id) else { return }
            message = whole.message
        } catch {
            let description = SyncErrorDescription.describe(error)
            send.status = .failed
            send.lastError = description
            try? store.updateSend(send)
            SyncLog.logger.error("send: could not read the message for \(accountID.rawValue, privacy: .public): \(description, privacy: .private)")
            return
        }
        do {
            _ = try await context.provider.send(message)
            send.status = .sent
            try? store.updateSend(send)
            // A Send Later message stays, `sent`, until the app has removed the draft it was written in and then the
            // row: a row deleted here would leave that draft in Drafts if the app quit before it saw the delivery.
            if send.draftID == nil { try? store.deleteSend(id: send.id) }
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
            // back, the Mac waking) sends it then (`wakeForConnection`).
            let delay = Backoff.delay(attempt: send.attempts, base: tuning.backoffBase, cap: tuning.userRetryAfterCap)
            SyncLog.logger.notice("send: not sent for \(accountID.rawValue, privacy: .public), no connection; trying again in \(delay, privacy: .public) s")
            reschedule(send, after: delay, error: error, retryOnWake: true)
        } catch let error as AuthError {
            // The token could not be had (the token endpoint failed, the keychain could not be read): the request was
            // never made, so going again cannot send the message twice. The HTTP clients fetch the token outside their
            // error mapping, so it arrives here as itself rather than as a `notSent`. Send Later makes this likely: its
            // time often comes after hours idle, with the token expired. A refused keychain waits at the cap, since each
            // try asks for the keychain password again; anything else waits as a send with no connection does.
            let delay = error.isKeychainDenial
                ? tuning.userRetryAfterCap
                : Backoff.delay(attempt: send.attempts, base: tuning.backoffBase, cap: tuning.userRetryAfterCap)
            SyncLog.logger.notice("send: not sent for \(accountID.rawValue, privacy: .public), no token; trying again in \(delay, privacy: .public) s")
            reschedule(send, after: delay, error: error, retryOnWake: !error.isKeychainDenial)
        } catch {
            let description = SyncErrorDescription.describe(error)
            send.status = .failed
            send.lastError = description
            try? store.updateSend(send)
            SyncLog.logger.error("send: failed for \(accountID.rawValue, privacy: .public): \(description, privacy: .private)")
        }
    }

    /// Puts a send back in the outbox to go again in `delay` seconds, timed on the continuous clock from now, or at
    /// the next `wakeForConnection` when `retryOnWake`. A Send Later message keeps its draft id, so the Drafts row still
    /// reads “Sending…” and a quit before the retry makes it `missed` at the next launch (`recoverPreviousRun`).
    private func reschedule(_ send: PendingSendSummary, after delay: TimeInterval, error: Error, retryOnWake: Bool = false) {
        var send = send
        let due = clock.uptime() + delay
        send.status = .scheduled
        send.sendAfter = clock.now().addingTimeInterval(delay)
        send.lastError = SyncErrorDescription.describe(error)
        try? store.updateSend(send)
        claimLock.withLock { held[send.id] = HeldSend(sendAfter: send.sendAfter, due: due, retryOnWake: retryOnWake) }
    }
}
