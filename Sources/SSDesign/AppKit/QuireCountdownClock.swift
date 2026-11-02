import AppKit
import QuartzCore

/// The clock behind a countdown bar or contrail: how much time is left, pausing (a toast's contrail freezes
/// while the pointer rests on it, §5.30), and the once-a-second tick that drives the stepped drain under Reduce
/// Motion. The views own the drawing; the shell still owns what happens when time runs out.
@MainActor
final class QuireCountdownClock {
    let duration: TimeInterval
    private var remainingAtResume: TimeInterval
    private var resumedAt: CFTimeInterval?
    private var tickTimer: Timer?

    /// Called on every whole-second boundary while ticking.
    var onTick: (@MainActor () -> Void)?

    init(duration: TimeInterval, remaining: TimeInterval) {
        self.duration = max(0, duration)
        self.remainingAtResume = min(max(0, remaining), max(0, duration))
    }

    var isRunning: Bool { resumedAt != nil }

    var remaining: TimeInterval {
        guard let resumedAt else { return remainingAtResume }
        return max(0, remainingAtResume - (CACurrentMediaTime() - resumedAt))
    }

    /// The share of the bar still filled when draining continuously.
    var fraction: CGFloat {
        duration > 0 ? CGFloat(remaining / duration) : 0
    }

    /// The share still filled when stepping once per second: the whole seconds left, so a 5 s countdown
    /// shows 5/5, then 4/5 one second in, alongside “Sending in 4 s”.
    var steppedFraction: CGFloat {
        guard duration > 0 else { return 0 }
        let seconds = (remaining - 0.000_1).rounded(.up)
        return CGFloat(max(0, min(duration, seconds)) / duration)
    }

    func start() {
        guard resumedAt == nil else { return }
        resumedAt = CACurrentMediaTime()
    }

    func pause() {
        remainingAtResume = remaining
        resumedAt = nil
        stopTicking()
    }

    /// Ticks on each whole-second boundary of the remaining time until it reaches zero.
    func startTicking() {
        stopTicking()
        guard isRunning, remaining > 0 else { return }
        let untilNext = remaining - (remaining - 0.000_1).rounded(.down)
        let timer = Timer(timeInterval: max(0.01, untilNext), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tickTimer = nil
                self.onTick?()
                self.startTicking()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    func invalidate() {
        stopTicking()
        onTick = nil
    }
}
