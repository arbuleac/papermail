import Foundation
import Network
import SSCore

/// The two inputs of the sync line the engine's statuses do not carry (spec §5.11): whether macOS reports a
/// network path, and how many sends are in flight after their undo window. Both are read off the main
/// thread; changes are delivered on it.
@MainActor
final class SyncActivityMonitor {
    var onChange: (() -> Void)?
    /// The network path came back after being lost: once per return, so the window can check for mail at once
    /// instead of waiting out the engine's backoff.
    var onNetworkReturned: (() -> Void)?

    private(set) var isNetworkReachable = true
    private(set) var sendingCount = 0

    private let store: MailStoring
    /// What a window's end is compared with; tests pass their own, so passing a window never races the wall clock.
    private let now: () -> Date
    private let pathMonitor = NWPathMonitor()
    private var isWatchingPath = false
    private var sendsObservation: StoreObservation?
    /// From the last outbox value: sends claimed and not settled, and when each held send's undo window ends.
    private var claimedSends = 0
    private var windowEnds: [Date] = []
    private var windowTimer: Timer?
    private static let queue = DispatchQueue(label: "io.supersparrow.mac.sync-activity", qos: .utility)

    init(store: MailStoring, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    func start() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.setReachable(reachable) }
            }
        }
        pathMonitor.start(queue: Self.queue)
        isWatchingPath = true
        startObservingSends()
    }

    /// The outbox half of `start`, internal so tests count the sends without the real network path, which reports
    /// whatever the machine running them has.
    func startObservingSends() {
        // Observed rather than polled, so an idle window keeps no timer.
        sendsObservation = store.observePendingSends { [weak self] sends in
            MainActor.assumeIsolated { self?.sendsArrived(sends) }
        }
    }

    func stop() {
        if isWatchingPath { pathMonitor.cancel() }
        isWatchingPath = false
        sendsObservation?.cancel()
        sendsObservation = nil
        windowTimer?.invalidate()
        windowTimer = nil
    }

    /// When the timer at the next held send's window end fires; nil with nothing held. Internal so tests check that
    /// a window with nothing held keeps no timer, and where one is set.
    var windowTimerFireDate: Date? { windowTimer?.fireDate }

    /// Fires the window timer now, as the run loop would at its date. Internal for tests, which move their clock
    /// past the window rather than wait for it.
    func fireWindowTimer() {
        windowTimer?.fire()
    }

    /// Internal so the transitions are tested without a real path monitor.
    func setReachable(_ reachable: Bool) {
        guard reachable != isNetworkReachable else { return }
        isNetworkReachable = reachable
        onChange?()
        if reachable { onNetworkReturned?() }
    }

    private func sendsArrived(_ sends: [PendingSendSummary]) {
        claimedSends = sends.filter { $0.status == .sending }.count
        windowEnds = sends.filter { $0.status == .scheduled }.map(\.sendAfter)
        recount()
    }

    /// Past the undo window and not settled: what “Sending 1 message” counts. A window can end without an outbox
    /// write: the send runner delivers one send at a time, so one whose window ends while another uploads is claimed
    /// only once that upload settles. A one-shot timer at the next window's end counts it then; with nothing held
    /// there is none.
    private func recount() {
        windowTimer?.invalidate()
        windowTimer = nil
        let now = self.now()
        let count = claimedSends + windowEnds.filter { $0 <= now }.count
        if let next = windowEnds.filter({ $0 > now }).min() {
            let timer = Timer(fire: next, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.recount() }
            }
            RunLoop.main.add(timer, forMode: .common)
            windowTimer = timer
        }
        guard count != sendingCount else { return }
        sendingCount = count
        onChange?()
    }
}
