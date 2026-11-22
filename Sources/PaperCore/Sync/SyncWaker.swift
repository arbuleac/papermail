import Foundation

/// Why a sync loop was woken. Reasons that arrive while the loop is busy are merged into its next wait.
enum WakeReason: Hashable, Sendable {
    /// Run a full cycle: outbox, changes and hydration. Someone asked (Check for New Mail, a reconnect), so an
    /// account parked for sign-in tries its token again.
    case poll
    /// Run a full cycle because the moment suggests new mail (the app coming to the front, the Mac waking, the
    /// network returning), not because anyone asked. An account parked for sign-in stays parked: retrying would
    /// bring back the keychain prompt with nobody there to answer, and the token provider waits on that prompt
    /// for every account.
    case check
    /// Only the outbox needs attention (a user action was queued).
    case operations
}

/// Lets a loop sleep until a timeout or an explicit signal, whichever comes first, without polling.
///
/// Signals that arrive while nobody is waiting are remembered, so a `syncNow` during a running cycle triggers
/// exactly one more cycle instead of being lost, and twenty quick user actions collapse into one wake.
actor SyncWaker {
    private var waiter: CheckedContinuation<Set<WakeReason>, Never>?
    private var pendingReasons: Set<WakeReason> = []
    /// Identifies the current wait so a timer left over from an earlier wait cannot end a later one.
    private var generation = 0
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// `sleep` times the waits: the send runner's allows less slack, and tests pass one on a clock they move.
    init(sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.sleep = sleep
    }

    nonisolated func signal(_ reason: WakeReason) {
        Task { await self.deliver(reason) }
    }

    func deliver(_ reason: WakeReason) {
        pendingReasons.insert(reason)
        resumeWaiter()
    }

    /// Returns the reasons collected since the last wait, or an empty set when the timeout elapsed first.
    /// A nil timeout waits for a signal alone. Cancelling the calling task also returns.
    func wait(timeout: TimeInterval?) async -> Set<WakeReason> {
        if !pendingReasons.isEmpty { return takeReasons() }
        if Task.isCancelled { return [] }
        generation += 1
        let current = generation
        let sleep = self.sleep
        let timer: Task<Void, Never>? = timeout.map { seconds in
            Task { [weak self] in
                try? await sleep(max(0, seconds))
                guard !Task.isCancelled else { return }
                await self?.resumeWaiter(ifGeneration: current)
            }
        }
        let reasons = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Set<WakeReason>, Never>) in
                // Only one loop waits on a waker; if a stale waiter is somehow still here, let it go.
                waiter?.resume(returning: [])
                waiter = continuation
            }
        } onCancel: {
            Task { await self.resumeWaiter(ifGeneration: current) }
        }
        timer?.cancel()
        return reasons
    }

    private func resumeWaiter(ifGeneration expected: Int) {
        guard expected == generation else { return }
        resumeWaiter()
    }

    private func resumeWaiter() {
        guard let waiter else { return }
        self.waiter = nil
        waiter.resume(returning: takeReasons())
    }

    private func takeReasons() -> Set<WakeReason> {
        let reasons = pendingReasons
        pendingReasons = []
        return reasons
    }
}
