import AppKit
import Foundation
import os

/// Product analytics through TelemetryDeck (docs/ARCHITECTURE.md, "Analytics"; setup and the catalog in
/// docs/ANALYTICS-AND-REPORTS.md): which features are used, and how fast, never what they were used on.
///
/// Started in `main.swift` beside crash reporting, and governed by the same switch, Settings › General › Analytics and
/// reports (`sendsCrashReports`): on unless turned off, off stops it at once and deletes what it had queued on disk. It
/// needs an app ID: the bundle's `TelemetryDeckAppID` (written by `scripts/build-app.sh` from `TELEMETRYDECK_APP_ID` or
/// `Resources/TelemetryDeckAppID`), or `--telemetry-app-id` in a debug build. With neither, nothing starts; nor for a
/// snapshot run.
///
/// The SDK itself starts the first time the app is active, not at launch: its session timer is only stopped when the app
/// goes behind, so a session begun behind other apps (a launch at login, or one the user clicked away from) would leave
/// a 1 s timer running for the whole run. Signals sent before then are held, at most `heldLimit`, and sent as it starts.
/// Once started and stopped in a run, it starts again only at the next launch: the SDK keeps its session counts in a
/// process-wide object nothing resets, which a restart would send again under the new identifier.
///
/// Signals come from a closed catalog (`AnalyticsSignal`), so a call site can only choose among its cases: no text
/// passes through here. The identifier TelemetryDeck counts users by is the SDK's own random one, hashed on the Mac,
/// never an account's address or name.
@MainActor
enum Analytics {
    /// The Info.plist key holding the TelemetryDeck app's ID.
    static let appIDInfoKey = "TelemetryDeckAppID"
    /// The app ID analytics last started with, in the app's own defaults: whose leftovers to delete when a later launch
    /// finds the switch off, or a build that sends to another app ID or to none.
    static let startedAppIDDefaultsKey = "analyticsStartedAppID"
    /// How often the SDK sends what it has queued: never a timer faster than the background poll (30 s, "Performance
    /// budgets"). A debug run against a local listener (`--telemetry-url`) sends every 5 s.
    static let transmitInterval: TimeInterval = 60
    /// How long a search must stand before it counts as one (the field searches at every keystroke).
    static var searchSettleDelay: TimeInterval = 2
    /// The share of timings sent, and at most how many of each kind an hour.
    static var performanceSampleRate = 0.05
    static let performanceSamplesPerHour = 20
    /// Signals held until the SDK starts, at most.
    static let heldLimit = 100

    /// The mailbox on screen, sent with every signal so the demo's use reads as such.
    enum Mode: String, CaseIterable, Sendable {
        case demo, accounts
    }

    /// Where signals go: TelemetryDeck, or a test's recorder.
    static var transport: AnalyticsTransport = TelemetryDeckTransport()
    /// Whether the app is the active one; tests say.
    static var appIsActive: () -> Bool = { NSApp?.isActive ?? false }
    /// Whether a key press is what the app is handling now; tests say.
    static var keyIsBeingHandled: () -> Bool = { recentKeyDown() }
    /// The time, for the timings' hourly cap; tests move it.
    static var now: () -> Date = { Date() }

    /// Whether signals are taken: started and not stopped. Until the SDK starts they are held.
    private(set) static var isRunning = false
    /// The SDK was started in this process, so it does not start again before the next launch.
    private(set) static var sdkStarted = false
    private(set) static var mode = Mode.accounts
    /// `mode` for the SDK's own signals (`defaultParameters`), which it may build off the main thread.
    nonisolated private static let sdkMode = OSAllocatedUnfairLock(initialState: Mode.accounts)
    private static var scopedTrigger: AnalyticsSignal.Trigger?
    private static var isQuiet = false
    private static var pendingSearch: DispatchWorkItem?
    private static var samplesSent: [AnalyticsSignal.PerformanceSample: Int] = [:]
    private static var samplesHourBegan = Date.distantPast
    private static var context = Context(launch: LaunchOptions(arguments: ["SuperSparrow"]), defaults: .standard, bundle: .main)
    /// The SDK's setup, waiting for the app to be active.
    private static var waitingSetup: AnalyticsSetup?
    private static var activationObserver: NSObjectProtocol?
    private static var held: [Held] = []

    /// What the launch said: where the app ID comes from, and where the switch and the started app ID are kept.
    private struct Context {
        var launch: LaunchOptions
        var defaults: UserDefaults
        var bundle: Bundle
    }

    private struct Held {
        var name: String
        var parameters: [String: String]
        var floatValue: Double?
    }

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

    private static var configuredAppID: String? {
        appID(launch: context.launch, info: context.bundle.infoDictionary)
    }

    /// Starts analytics unless the user turned it off, the build has no app ID, or this is a snapshot run (a debug aid,
    /// not a use of the app). Returns whether it started. Turned off, it deletes what an earlier run left on this Mac.
    /// Debug builds send TelemetryDeck's test signals, which its dashboard keeps apart from users'.
    @discardableResult
    static func start(launch: LaunchOptions, defaults: UserDefaults = .standard, bundle: Bundle = .main) -> Bool {
        guard !isRunning, !sdkStarted else { return false }
        context = Context(launch: launch, defaults: defaults, bundle: bundle)
        guard !launch.isSnapshot else { return false }
        setMode(demo: launch.demo)
        guard isEnabled(in: defaults) else {
            deleteLeftovers()
            return false
        }
        return begin()
    }

    /// Takes signals from now on, and starts the SDK once the app is active. Not twice in a run.
    private static func begin() -> Bool {
        guard !isRunning, !sdkStarted, !context.launch.isSnapshot else { return false }
        let appID = configuredAppID
        // An earlier build sent to another app ID, or this one has none: what that one left goes.
        if let started = context.defaults.string(forKey: startedAppIDDefaultsKey), started != appID {
            transport.deleteLeftovers(of: started)
            context.defaults.removeObject(forKey: startedAppIDDefaultsKey)
        }
        guard let appID else { return false }
        context.defaults.set(appID, forKey: startedAppIDDefaultsKey)
        let local = context.launch.telemetryURL.flatMap(URL.init(string:))
        waitingSetup = AnalyticsSetup(appID: appID, baseURL: local, testMode: isDebugBuild,
                                      transmitInterval: local == nil ? transmitInterval : 5)
        isRunning = true
        if appIsActive() {
            appBecameActive()
        } else {
            activationObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                        object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { appBecameActive() }
            }
        }
        return true
    }

    /// The app is active: the SDK starts, so its session begins in front, and the signals held until now go to it.
    static func appBecameActive() {
        stopWaitingForActivation()
        guard isRunning, !sdkStarted, let setup = waitingSetup else { return }
        waitingSetup = nil
        sdkStarted = true
        transport.start(setup)
        let held = self.held
        self.held = []
        for signal in held { transport.send(signal.name, parameters: signal.parameters, floatValue: signal.floatValue) }
    }

    private static func stopWaitingForActivation() {
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        activationObserver = nil
    }

    /// Settings › General › Analytics and reports. Off stops sending at once, the current run included: nothing more is
    /// queued, what was queued in memory is dropped, and what this run or an earlier one left queued on disk is deleted.
    /// On starts it again, but once the SDK has started in this run, only from the next launch.
    static func setEnabled(_ enabled: Bool) {
        if enabled {
            _ = begin()
            return
        }
        cancelPendingSearch()
        stopWaitingForActivation()
        waitingSetup = nil
        held = []
        let running = isRunning && sdkStarted ? configuredAppID : nil
        isRunning = false
        if running != nil { transport.stop() }
        deleteLeftovers(except: running)
    }

    /// Whether analytics waits for the next launch: switched off after the SDK started in this run, and on again.
    static var resumesAtNextLaunch: Bool {
        sdkStarted && !isRunning && isEnabled(in: context.defaults)
    }

    /// Deletes what analytics left on this Mac for the build's app ID and the one it last started with, but `running`,
    /// whose stop deletes it.
    private static func deleteLeftovers(except running: String? = nil) {
        let ids = Set([configuredAppID, context.defaults.string(forKey: startedAppIDDefaultsKey)].compactMap { $0 })
        for id in ids.sorted() where id != running { transport.deleteLeftovers(of: id) }
        context.defaults.removeObject(forKey: startedAppIDDefaultsKey)
    }

    /// Every later signal says which mailbox is on screen.
    static func setMode(demo: Bool) {
        let mode: Mode = demo ? .demo : .accounts
        self.mode = mode
        sdkMode.withLock { $0 = mode }
    }

    /// The SDK's own parameters for every signal, its own ones included (`TelemetryDeck.Session.started`,
    /// `newInstallDetected`): which mailbox is on screen.
    nonisolated static func sdkParameters() -> [String: String] {
        ["mode": sdkMode.withLock { $0.rawValue }]
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

    /// Sends `signal` while analytics runs (held until the SDK starts); nothing otherwise, nor in a step the app takes on
    /// its own (`quietly`).
    static func send(_ signal: AnalyticsSignal) {
        guard isRunning, !isQuiet else { return }
        var parameters = signal.parameters
        parameters["mode"] = mode.rawValue
        if sdkStarted {
            transport.send(signal.name.rawValue, parameters: parameters, floatValue: signal.floatValue)
        } else if held.count < heldLimit {
            held.append(Held(name: signal.name.rawValue, parameters: parameters, floatValue: signal.floatValue))
        }
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
    /// `performanceSamplesPerHour` of each kind an hour, so a run left open for days is measured all along.
    static func sample(_ kind: AnalyticsSignal.PerformanceSample, seconds: Double) {
        guard isRunning else { return }
        let time = now()
        if time.timeIntervalSince(samplesHourBegan) >= 3600 || time < samplesHourBegan {
            samplesHourBegan = time
            samplesSent = [:]
        }
        guard samplesSent[kind, default: 0] < performanceSamplesPerHour, Double.random(in: 0..<1) < performanceSampleRate else { return }
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

    static var isHandlingKey: Bool { keyIsBeingHandled() }

    /// `currentEvent` is the last event taken from the queue, so a step that comes some other way (a notification's
    /// button, a reply from the reader's page) may find an old key press there: only one from the last second counts.
    private static func recentKeyDown() -> Bool {
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

    /// Runs `step`, a step the app takes on its own on the way through a user's path (the rail falling back to All
    /// Inboxes when an account goes): nothing in it is sent.
    static func quietly<T>(_ step: () throws -> T) rethrows -> T {
        let outer = isQuiet
        isQuiet = true
        defer { isQuiet = outer }
        return try step()
    }

    // MARK: Tests

    #if DEBUG
    /// Puts the service back as a launch finds it, with `transport` in place of TelemetryDeck and `defaults` in place of
    /// the app's. Tests only: the app is active, and no key is being handled.
    static func reset(transport: AnalyticsTransport, defaults: UserDefaults) {
        pendingSearch?.cancel()
        pendingSearch = nil
        stopWaitingForActivation()
        waitingSetup = nil
        held = []
        isRunning = false
        sdkStarted = false
        isQuiet = false
        setMode(demo: false)
        scopedTrigger = nil
        samplesSent = [:]
        samplesHourBegan = .distantPast
        searchSettleDelay = 2
        performanceSampleRate = 0.05
        appIsActive = { true }
        keyIsBeingHandled = { false }
        now = { Date() }
        context = Context(launch: LaunchOptions(arguments: ["SuperSparrow"]), defaults: defaults, bundle: .main)
        self.transport = transport
    }
    #endif
}
