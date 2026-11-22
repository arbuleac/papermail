import Foundation

/// The Keep mail window and the messages whose bodies stay whole for the rest of the run (docs/ARCHITECTURE.md,
/// "Storage bounds"), shared by the engine, which sets them, and by its sweeper and hydrators, which read them.
///
/// A lock, not an actor: the reader marks the messages it shows and `ensureBody` the one it fetches without waiting
/// behind a sweep step, and a hydrator decides how to save a body without a hop.
final class KeepMailState: @unchecked Sendable {
    private let lock = NSLock()
    private var window: MailRetention = .everything
    private var keptIDs: Set<MessageID> = []

    var retention: MailRetention {
        lock.withLock { window }
    }

    /// Sets the window and returns the one it replaced.
    func setRetention(_ retention: MailRetention) -> MailRetention {
        lock.withLock {
            let previous = window
            window = retention
            return previous
        }
    }

    /// Bodies the user has on screen or asked for: no sweep evicts them, and a backfill fetching one stores it whole,
    /// until the app quits.
    func keep(_ ids: some Sequence<MessageID>) {
        lock.withLock { keptIDs.formUnion(ids) }
    }

    var kept: Set<MessageID> {
        lock.withLock { keptIDs }
    }

    /// The cutoff before which a body the backfill fetches for `id` is stored already evicted, so the store never grows
    /// past what the window keeps; nil when it is stored whole (Everything, or a message kept for this run).
    func evictionCutoff(for id: MessageID, now: Date = Date()) -> Date? {
        lock.withLock {
            guard !keptIDs.contains(id) else { return nil }
            return window.cutoff(now: now)
        }
    }
}
