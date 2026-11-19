import AppKit
import SSDesign

/// “Now” for the calendar, and the minute tick that moves the now line (spec §5.54, “Marks”; docs/ARCHITECTURE.md,
/// timers). An idle app keeps no timer faster than its poll, so the tick runs only while some calendar view is on screen:
/// in a window, not hidden, and the window not occluded (minimised, covered, on another space). The day turns at
/// midnight on the system's day-change notice, tick or none.
@MainActor
final class CalendarClock {
    /// Where now comes from: tests move it.
    var source: () -> Date
    private(set) var now: Date
    /// Called with whether the day changed, on every tick and every day change.
    var onTick: ((_ dayChanged: Bool) -> Void)?

    /// Overrides whether a calendar view counts as on screen, for tests (off-screen test windows are never visible).
    var visibilityOverride: Bool? {
        didSet { visibilityMayHaveChanged() }
    }

    /// True while the minute timer runs.
    var isTicking: Bool { timer != nil }

    private var calendar: Calendar
    private var timer: Timer?
    private let views = NSHashTable<NSView>.weakObjects()
    private var observers: [NSObjectProtocol] = []

    init(calendar: Calendar, source: @escaping () -> Date = Date.init) {
        self.calendar = calendar
        self.source = source
        now = source()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.visibilityMayHaveChanged() }
        })
        // Posted on whatever thread noticed midnight pass.
        observers.append(center.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        })
    }

    func invalidate() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    // MARK: Visibility

    /// A calendar view that shows the now line: it asks again from `viewDidMoveToWindow`, `viewDidHide` and
    /// `viewDidUnhide`.
    func register(_ view: NSView) {
        views.add(view)
        visibilityMayHaveChanged()
    }

    func unregister(_ view: NSView) {
        views.remove(view)
        visibilityMayHaveChanged()
    }

    /// Whether some registered view is on screen now.
    var isSomeViewOnScreen: Bool {
        views.allObjects.contains { view in
            guard let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return false }
            return visibilityOverride ?? window.occlusionState.contains(.visible)
        }
    }

    /// Starts or stops the minute timer to match what is on screen; a view coming back reads now at once, since the
    /// line may have stood still for hours behind another window.
    func visibilityMayHaveChanged() {
        let shouldTick = isSomeViewOnScreen
        if shouldTick, timer == nil {
            tick()
            schedule()
        } else if !shouldTick, let timer {
            timer.invalidate()
            self.timer = nil
        }
    }

    /// The next tick lands on the minute, so the line and the gutter's time move as the menu bar clock does.
    private func schedule() {
        let current = source()
        let second = calendar.component(.second, from: current)
        let nanos = calendar.component(.nanosecond, from: current)
        let untilMinute = max(0.05, 60 - Double(second) - Double(nanos) / 1_000_000_000)
        let timer = Timer(fire: Date().addingTimeInterval(untilMinute), interval: Quire.Motion.nowTick, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Reads now and tells the state; a turn of the day is told as such.
    func tick() {
        let previous = now
        now = source()
        let dayChanged = !calendar.isDate(previous, inSameDayAs: now)
        guard now != previous || dayChanged else { return }
        onTick?(dayChanged)
    }

    /// The calendar changed (a zone or a first weekday): the day may have too.
    func setCalendar(_ calendar: Calendar) {
        self.calendar = calendar
        tick()
    }
}
