import Foundation
import Network
import SSCore

/// The two inputs of the sync line the engine's statuses do not carry (spec §5.11): whether macOS reports a
/// network path, and how many sends are in flight after their undo window. Both are read off the main
/// thread; changes are delivered on it.
@MainActor
final class SyncActivityMonitor {
    /// How often the outbox is looked at. A read of the small pending-sends table, off the main thread.
    static let sendPollInterval: TimeInterval = 2

    var onChange: (() -> Void)?
    /// The network path came back after being lost: once per return, so the window can check for mail at once
    /// instead of waiting out the engine's backoff.
    var onNetworkReturned: (() -> Void)?

    private(set) var isNetworkReachable = true
    private(set) var sendingCount = 0

    private let store: MailStoring
    private let pathMonitor = NWPathMonitor()
    private var pollTimer: Timer?
    private var isPolling = false
    private static let queue = DispatchQueue(label: "io.supersparrow.mac.sync-activity", qos: .utility)

    init(store: MailStoring) {
        self.store = store
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.setReachable(reachable) }
            }
        }
        pathMonitor.start(queue: Self.queue)
        pollSends()
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.sendPollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollSends() }
        }
        // The store has no observation for sends, so this ticks for the window's life; the slack lets macOS
        // coalesce it with other wake-ups.
        pollTimer?.tolerance = Self.sendPollInterval / 4
    }

    func stop() {
        pathMonitor.cancel()
        pollTimer?.invalidate()
        pollTimer = nil
    }

    /// Internal so the transitions are tested without a real path monitor.
    func setReachable(_ reachable: Bool) {
        guard reachable != isNetworkReachable else { return }
        isNetworkReachable = reachable
        onChange?()
        if reachable { onNetworkReturned?() }
    }

    private func pollSends() {
        guard !isPolling else { return }
        isPolling = true
        let store = self.store
        Self.queue.async { [weak self] in
            let now = Date()
            let sends = (try? store.pendingSends()) ?? []
            // Past the undo window and not settled: what “Sending 1 message” counts.
            let inFlight = sends.filter { $0.status == .sending || ($0.status == .scheduled && $0.sendAfter <= now) }.count
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.sendsArrived(inFlight) }
            }
        }
    }

    private func sendsArrived(_ count: Int) {
        isPolling = false
        guard count != sendingCount else { return }
        sendingCount = count
        onChange?()
    }
}
