import Foundation

/// Tells subscribers, on the main thread, that the mailbox's size on disk changed by more than mail arriving: a sweep
/// evicted bodies or gave pages back, or the attachment cache trimmed itself. No value: a subscriber measures again.
final class StorageChangeFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var handlers: [UUID: @Sendable () -> Void] = [:]

    func observe(_ handler: @escaping @Sendable () -> Void) -> StoreObservation {
        let id = UUID()
        lock.withLock { handlers[id] = handler }
        return StoreObservation { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.handlers[id] = nil }
        }
    }

    func publish() {
        let current = lock.withLock { Array(handlers.values) }
        guard !current.isEmpty else { return }
        DispatchQueue.main.async {
            for handler in current { handler() }
        }
    }
}
