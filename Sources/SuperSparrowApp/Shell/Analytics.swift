import AppKit
import Foundation

/// Product analytics through TelemetryDeck (docs/ARCHITECTURE.md, "Analytics"; setup and the catalog in
/// docs/ANALYTICS-AND-REPORTS.md): which features are used, and how fast, never what they were used on.
///
/// Started in `main.swift` beside crash reporting, and governed by the same switch, Settings › General › Analytics and
/// reports (`sendsCrashReports`): on unless turned off, off stops it at once and deletes what it had queued on disk. It
/// needs an app ID: the bundle's `TelemetryDeckAppID` (written by `scripts/build-app.sh` from `TELEMETRYDECK_APP_ID` or
/// `Resources/TelemetryDeckAppID`), or `--telemetry-app-id` in a debug build. With neither, nothing starts; nor for a
/// snapshot run.
///
/// Signals come from a closed catalog (`AnalyticsSignal`), so a call site can only choose among its cases: no text
/// passes through here. The identifier TelemetryDeck counts users by is the SDK's own random one, hashed on the Mac,
/// never an account's address or name.
@MainActor
enum Analytics {
    /// The Info.plist key holding the TelemetryDeck app's ID.
    static let appIDInfoKey = "TelemetryDeckAppID"
    /// How often the SDK sends what it has queued: never a timer faster than the background poll (30 s, "Performance
    /// budgets"). A debug run against a local listener (`--telemetry-url`) sends every 5 s.
    static let transmitInterval: TimeInterval = 60
    /// How long a search must stand before it counts as one (the field searches at every keystroke).
    static var searchSettleDelay: TimeInterval = 2
    /// The share of timings sent, and at most how many of each kind a run sends.
    static var performanceSampleRate = 0.05
    static let performanceSamplesPerRun = 20

    /// The mailbox on screen, sent with every signal so the demo's use reads as such.
    enum Mode: String, CaseIterable, Sendable {
        case demo, accounts
    }

    /// Where signals go: TelemetryDeck, or a test's recorder.
    static var transport: AnalyticsTransport = TelemetryDeckTransport()

    /// Whether this process started analytics and has not stopped it.
    private(set) static var isRunning = false
    private(set) static var mode = Mode.accounts
    private static var scopedTrigger: AnalyticsSignal.Trigger?
    private static var pendingSearch: DispatchWorkItem?
    private static var samplesSent: [AnalyticsSignal.PerformanceSample: Int] = [:]

    // MARK: Starting

    /// Whether the user lets SuperSparrow send analytics and reports: the one switch both services follow.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        CrashReporting.isEnabled(in: defaults)
    }

    /// The app ID this build sends to: `--telemetry-app-id` (debug builds), else the bundle's. Blank is none.
    static func appID(launch: LaunchOptions, info: [String: Any]?) -> String? {
        let candidates = [launch.telemetryAppID, info?[appIDInfoKey] as? String]
        return candidates.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    /// Whether this build has an app ID to send to.
    static var isConfigured: Bool {
        appID(launch: LaunchOptions(), info: Bundle.main.infoDictionary) != nil
    }

    /// Starts analytics unless the user turned it off, the build has no app ID, or this is a snapshot run (a debug aid,
    /// not a use of the app). Returns whether it started. Debug builds send TelemetryDeck's test signals, which its
    /// dashboard keeps apart from users'.
    @discardableResult
    static func start(launch: LaunchOptions, defaults: UserDefaults = .standard, bundle: Bundle = .main) -> Bool {
        guard !isRunning, isEnabled(in: defaults), !launch.isSnapshot,
              let appID = appID(launch: launch, info: bundle.infoDictionary) else { return false }
        let local = launch.telemetryURL.flatMap(URL.init(string:))
        transport.start(AnalyticsSetup(appID: appID, baseURL: local, testMode: isDebugBuild,
                                       transmitInterval: local == nil ? transmitInterval : 5))
        isRunning = true
        return true
    }

    /// Settings › General › Analytics and reports. Off stops sending at once, the current run included: nothing more is
    /// queued, what was queued in memory is dropped, and what an earlier run left queued on disk is deleted. On starts
    /// it again.
    static func setEnabled(_ enabled: Bool, launch: LaunchOptions = LaunchOptions(), bundle: Bundle = .main) {
        if enabled {
            start(launch: launch, bundle: bundle)
            return
        }
        pendingSearch?.cancel()
        pendingSearch = nil
        isRunning = false
        transport.stop(deleting: appID(launch: launch, info: bundle.infoDictionary))
    }

    /// Every later signal says which mailbox is on screen.
    static func setMode(demo: Bool) {
        mode = demo ? .demo : .accounts
    }

    /// Seconds since the kernel started this process, so a launch counts dyld and AppKit's start too; nil if it cannot say.
    nonisolated static func secondsSinceProcessStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        let started = Double(start.tv_sec) + Double(start.tv_usec) / 1_000_000
        let seconds = Date().timeIntervalSince1970 - started
        return seconds >= 0 ? seconds : nil
    }

    static var isDebugBuild: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    // MARK: Sending

    /// Sends `signal` while analytics runs; nothing otherwise.
    static func send(_ signal: AnalyticsSignal) {
        guard isRunning else { return }
        var parameters = signal.parameters
        parameters["mode"] = mode.rawValue
        transport.send(signal.name.rawValue, parameters: parameters, floatValue: signal.floatValue)
    }

    /// A search of this Mac, sent once it has stood for `searchSettleDelay`: the field searches as the user types, and
    /// only the search they stopped at counts. A newer one replaces it; leaving search before then sends nothing.
    static func searchSettled(operators: Int, results: Int) {
        pendingSearch?.cancel()
        guard isRunning else { return }
        let item = DispatchWorkItem {
            MainActor.assumeIsolated {
                pendingSearch = nil
                send(.localSearch(operators: operators, results: results))
            }
        }
        pendingSearch = item
        DispatchQueue.main.asyncAfter(deadline: .now() + searchSettleDelay, execute: item)
    }

    /// Another query, or none: a search still settling is not sent.
    static func cancelPendingSearch() {
        pendingSearch?.cancel()
        pendingSearch = nil
    }

    /// A timing where the app keeps a signpost, sent for a sample of them (`performanceSampleRate`), at most
    /// `performanceSamplesPerRun` of each kind a run.
    static func sample(_ kind: AnalyticsSignal.PerformanceSample, seconds: Double) {
        guard isRunning, samplesSent[kind, default: 0] < performanceSamplesPerRun,
              Double.random(in: 0..<1) < performanceSampleRate else { return }
        samplesSent[kind, default: 0] += 1
        send(.performance(kind, seconds: seconds))
    }

    /// Seconds from `start` to now.
    nonisolated static func seconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    // MARK: Triggers

    /// Where the step being taken came from: a key while a key is being handled, else what the way in said (`from`),
    /// else a menu.
    static var trigger: AnalyticsSignal.Trigger {
        isHandlingKey ? .key : scopedTrigger ?? .menu
    }

    /// A key press is what the app is handling now. `currentEvent` is the last event taken from the queue, so a step that
    /// comes some other way (a notification's button, a reply from the reader's page) may find an old key press there:
    /// only one from the last second counts.
    static var isHandlingKey: Bool {
        guard let event = NSApp?.currentEvent, event.type == .keyDown else { return false }
        return ProcessInfo.processInfo.systemUptime - event.timestamp < 1
    }

    /// Runs `step` as one that came from `trigger` (a swipe, a drop, the reader's buttons, a toast, a notification),
    /// which the event being handled cannot say. The outermost way in wins.
    @discardableResult
    static func from<T>(_ trigger: AnalyticsSignal.Trigger, _ step: () throws -> T) rethrows -> T {
        let outer = scopedTrigger
        scopedTrigger = outer ?? trigger
        defer { scopedTrigger = outer }
        return try step()
    }

    // MARK: Tests

    #if DEBUG
    /// Puts the service back as a launch finds it, with `transport` in place of TelemetryDeck. Tests only.
    static func reset(transport: AnalyticsTransport) {
        pendingSearch?.cancel()
        pendingSearch = nil
        isRunning = false
        mode = .accounts
        scopedTrigger = nil
        samplesSent = [:]
        searchSettleDelay = 2
        performanceSampleRate = 0.05
        self.transport = transport
    }
    #endif
}
