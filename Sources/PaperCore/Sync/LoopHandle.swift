import Foundation

/// Owns the task behind a long-running loop so `start`/`stop` can be called from any thread, in any order,
/// without two loops ever running for the same owner.
final class LoopHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        guard let task else { return false }
        return !task.isCancelled
    }

    /// Starts the loop unless it is already running. A loop that was cancelled earlier is replaced.
    func start(_ body: @escaping @Sendable () async -> Void) {
        lock.lock(); defer { lock.unlock() }
        if let task, !task.isCancelled { return }
        task = Task { await body() }
    }

    func cancel() {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
    }

    /// Cancels the loop and returns once it has actually finished, so a restart on the same store cannot
    /// interleave with the old loop's last writes.
    func cancelAndWait() async {
        await cancelAndTake()?.value
    }

    private func cancelAndTake() -> Task<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        task?.cancel()
        return task
    }
}
