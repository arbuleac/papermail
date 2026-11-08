import Foundation

/// The clocks the send runner times sends by, and the sleep it waits with. Production reads the system's; tests
/// move time by hand, so a send due in five seconds, a Mac that slept or a clock set back is checked without waiting.
struct SendClock: Sendable {
    /// The wall clock, which `PendingSend.sendAfter` is stored in so a held send survives a relaunch.
    var now: @Sendable () -> Date = { Date() }
    /// Seconds on the continuous clock `sleep` waits by: it keeps counting while the Mac sleeps and ignores changes
    /// to the wall clock, so a due time kept on it is neither brought forward nor put off by setting the clock.
    var uptime: @Sendable () -> TimeInterval = { SendClock.continuousSeconds() }
    /// A timer's default slack is a tenth of its length, two seconds on a twenty-second undo window. The send time is
    /// a promise the countdown shows to the second, so the runner's waits allow a tenth of a second instead.
    var sleep: @Sendable (TimeInterval) async throws -> Void = { seconds in
        try await Task.sleep(for: .seconds(seconds), tolerance: .milliseconds(100))
    }

    private static let origin = ContinuousClock.now

    private static func continuousSeconds() -> TimeInterval {
        let elapsed = origin.duration(to: .now).components
        return TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) * 1e-18
    }
}
