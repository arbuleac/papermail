import Foundation

/// Sends queued messages once their undo window has passed.
///
/// Claiming a send (scheduled → sending) and cancelling one both run under `claimLock`, so a message is never
/// both cancelled and sent. Only throttling is retried: after any other failure the provider may already have
/// delivered the message and a retry would send it twice, so the send is marked failed for the user to see.
actor SendRunner {
    private let store: MailStoring
    private let registry: AccountRegistry
    private let claimLock: NSLock
    private let tuning: SyncTuning
    private let waker = SyncWaker()
    private let loop = LoopHandle()
    private var recoveredInterrupted = false

    init(store: MailStoring, registry: AccountRegistry, claimLock: NSLock, tuning: SyncTuning) {
        self.store = store
        self.registry = registry
        self.claimLock = claimLock
        self.tuning = tuning
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

    /// Re-reads the outbox now instead of at the next tick; called when a send is queued.
    nonisolated func wake() {
        waker.signal(.operations)
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
            var timeout = tuning.sendTickInterval
            if let nextDue { timeout = min(timeout, max(0, nextDue.timeIntervalSinceNow)) }
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

    /// Sends everything that is due. Returns when the earliest remaining scheduled send becomes due.
    func tick() async -> Date? {
        let (claimed, nextDue) = claimDueSends()
        for send in claimed { await deliver(send) }
        return nextDue
    }

    /// Marks every due send as `sending` under the claim lock so `cancel` can no longer take it.
    private func claimDueSends() -> (claimed: [PendingSend], nextDue: Date?) {
        claimLock.lock(); defer { claimLock.unlock() }
        var claimed: [PendingSend] = []
        var nextDue: Date?
        do {
            let now = Date()
            for var send in try store.pendingSends() where send.status == .scheduled {
                if send.sendAfter <= now {
                    send.status = .sending
                    send.attempts += 1
                    try store.updateSend(send)
                    claimed.append(send)
                } else {
                    nextDue = nextDue.map { min($0, send.sendAfter) } ?? send.sendAfter
                }
            }
        } catch {
            SyncLog.logger.error("send: could not read the outbox: \(String(describing: error), privacy: .private)")
        }
        return (claimed, nextDue)
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
                retryAfter: retryAfter, attempt: send.attempts, base: tuning.backoffBase, cap: tuning.backoffCap
            )
            send.status = .scheduled
            send.sendAfter = Date().addingTimeInterval(delay)
            send.lastError = SyncErrorDescription.describe(ProviderError.throttled(retryAfter: retryAfter))
            try? store.updateSend(send)
        } catch {
            let description = SyncErrorDescription.describe(error)
            send.status = .failed
            send.lastError = description
            try? store.updateSend(send)
            SyncLog.logger.error("send: failed for \(accountID.rawValue, privacy: .public): \(description, privacy: .private)")
        }
    }
}
