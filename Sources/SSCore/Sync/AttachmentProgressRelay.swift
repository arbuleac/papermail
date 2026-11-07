import Foundation

/// Hands one attachment download's progress to everyone waiting on it, at most about ten times a second. A download
/// reports after every chunk, hundreds of times a second on a fast link, and each report the reader takes is a hop
/// to the main thread and a script call into its web view; a contrail 120 pt wide gains nothing from more.
///
/// The first fraction and the final 1 go through at once. One that comes sooner than the interval after the last
/// one handed on is held, and a single delayed hand-on, scheduled only while one is held, delivers the latest when
/// the interval is up, so a download that pauses after a burst still shows how far the burst got. A waiter that
/// joins a download under way hears where it stands at once.
final class AttachmentProgressRelay: @unchecked Sendable {
    /// About ten a second.
    static let interval: TimeInterval = 0.1

    typealias Schedule = @Sendable (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Void

    private let interval: TimeInterval
    private let now: @Sendable () -> TimeInterval
    private let schedule: Schedule
    private let lock = NSLock()
    private var listeners: [@Sendable (Double) -> Void] = []
    private var latest: Double?
    private var handedOn: Double?
    private var handedOnAt: TimeInterval = -.infinity
    private var flushScheduled = false

    /// `now` is a monotonic clock in seconds and `schedule` runs work after a delay; tests pass their own.
    init(interval: TimeInterval = AttachmentProgressRelay.interval,
         now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         schedule: @escaping Schedule = { delay, work in
             DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + delay, execute: work)
         }) {
        self.interval = interval
        self.now = now
        self.schedule = schedule
    }

    /// Adds a waiter, telling it at once how far the download has got when it has reported before.
    func add(_ listener: @escaping @Sendable (Double) -> Void) {
        lock.withLock {
            listeners.append(listener)
            if let handedOn { listener(handedOn) }
        }
    }

    /// The download reached `fraction`. Fractions that do not rise are ignored.
    func report(_ fraction: Double) {
        lock.withLock {
            if let latest, fraction <= latest { return }
            latest = fraction
            let time = now()
            if fraction >= 1 || time - handedOnAt >= interval {
                handOn(fraction, at: time)
            } else if !flushScheduled {
                flushScheduled = true
                schedule(max(0, handedOnAt + interval - time)) { [weak self] in self?.flush() }
            }
        }
    }

    private func flush() {
        lock.withLock {
            flushScheduled = false
            guard let latest, latest > (handedOn ?? -1) else { return }
            handOn(latest, at: now())
        }
    }

    /// Called with the lock held, so listeners hear the fractions in order; they only hand the value on.
    private func handOn(_ fraction: Double, at time: TimeInterval) {
        handedOn = fraction
        handedOnAt = time
        for listener in listeners { listener(fraction) }
    }
}
