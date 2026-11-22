import AppKit
import CryptoKit
import Foundation
import TelemetryDeck

/// How analytics starts: the TelemetryDeck app, where signals go (nil: TelemetryDeck's own server), whether they are
/// test signals, and how often the queue is sent.
struct AnalyticsSetup: Equatable, Sendable {
    var appID: String
    var baseURL: URL?
    var testMode: Bool
    var transmitInterval: TimeInterval
}

/// Where `Analytics` hands its signals: TelemetryDeck in the app, a recorder in tests.
@MainActor
protocol AnalyticsTransport: AnyObject {
    /// Once a process at most (`Analytics` never starts it again after a stop).
    func start(_ setup: AnalyticsSetup)
    func send(_ name: String, parameters: [String: String], floatValue: Double?)
    /// Stops sending at once and deletes what the running app ID's analytics left on this Mac.
    func stop()
    /// Deletes what `appID`'s analytics left on this Mac: its signals in the SDK's queue file, and the SDK's random
    /// identifier and session counts.
    func deleteLeftovers(of appID: String)
}

/// The calls `TelemetryDeckTransport` makes into TelemetryDeck's SDK, so tests can stand in for it.
@MainActor
protocol TelemetryDeckSDK: AnyObject {
    /// Makes the SDK's shared manager, which reads the queue file (and deletes it) at once and starts its first session
    /// half a second later.
    func initialize(_ setup: AnalyticsSetup)
    func signal(_ name: String, parameters: [String: String], floatValue: Double?)
    /// Nothing more is queued, the SDK's own signals included (`analyticsDisabled`).
    func disable()
    /// Drops the shared manager, and with it the signals it held in memory.
    func terminate()
}

/// TelemetryDeck's Swift SDK itself.
@MainActor
final class LiveTelemetryDeck: TelemetryDeckSDK {
    private var configuration: TelemetryDeck.Config?

    nonisolated init() {}

    func initialize(_ setup: AnalyticsSetup) {
        let config = TelemetryDeck.Config(appID: setup.appID, baseURL: setup.baseURL)
        config.testMode = setup.testMode
        config.transmitInterval = setup.transmitInterval
        // No cookies or cache on disk for these requests.
        config.urlSession = URLSession(configuration: .ephemeral)
        // Errors only; the SDK's info lines name the cache file's path.
        config.logHandler = .standard(.error)
        // `mode` on the SDK's own signals too (the session, a new install), so the demo's can be told apart.
        config.defaultParameters = { Analytics.sdkParameters() }
        TelemetryDeck.initialize(config: config)
        configuration = config
    }

    func signal(_ name: String, parameters: [String: String], floatValue: Double?) {
        TelemetryDeck.signal(name, parameters: parameters, floatValue: floatValue)
    }

    func disable() {
        configuration?.analyticsDisabled = true
    }

    func terminate() {
        TelemetryDeck.terminate()
        configuration = nil
    }
}

/// TelemetryDeck's Swift SDK (docs/ARCHITECTURE.md, "Analytics"), started once a process at most.
///
/// Three of its habits shape this:
/// - `TelemetryDeck.signal` and the session it starts half a second after `initialize` reach for the shared manager,
///   which a debug build traps on and a release build replaces with one of an empty app ID if `terminate` has dropped it;
///   so `Analytics` sends only while running, and a stop within that half second turns the SDK off at once and drops it
///   once the session has started.
/// - It keeps its queue in memory and writes it to one file in `~/Library/Caches`, shared by name with every unsandboxed
///   app embedding the SDK, only as the app quits; so a stop deletes Paper's own signals from that file and
///   leaves any other app's.
/// - `initialize` reads that whole file, every app's signals in it, deletes it and sends them all, and its write as the
///   app quits replaces the file; so other apps' entries are set aside while it reads and put back after, and those the
///   file holds as the app quits are put back after that write.
@MainActor
final class TelemetryDeckTransport: AnalyticsTransport {
    /// The SDK starts its first session this long after `initialize`, through the shared manager.
    nonisolated static let sessionStartDelay: TimeInterval = 0.6
    /// The SDK writes its session counts on a queue of its own a moment after each tick: the second sweep of its
    /// defaults, after a stop, comes once any such write has landed.
    nonisolated static let secondSweepDelay: TimeInterval = 1.5

    private let sdk: TelemetryDeckSDK
    private let caches: URL?
    private let removeDomain: (String) -> Void
    private let sessionStartDelay: TimeInterval
    /// The app ID the SDK runs for; nil before it starts and once it has been dropped.
    private(set) var appID: String?
    private var hasStarted = false
    private var startedAt = Date.distantPast
    /// A stop waiting for the SDK's first session.
    private var pendingStop: DispatchWorkItem?
    /// Around the SDK's own observer of the app quitting: one made before `initialize`, one after.
    private var quitObservers: [NSObjectProtocol] = []
    /// Other apps' signals the queue file held as the app began to quit, put back after the SDK's write replaced it.
    private var othersAtQuit: [[String: Any]] = []

    /// `caches` and `removeDomain` are the user's caches folder and the defaults' own removal but in tests, which must
    /// not touch the user's files or preferences.
    init(sdk: TelemetryDeckSDK = LiveTelemetryDeck(), caches: URL? = nil,
                     removeDomain: @escaping (String) -> Void = { UserDefaults.standard.removePersistentDomain(forName: $0) },
                     sessionStartDelay: TimeInterval = TelemetryDeckTransport.sessionStartDelay) {
        self.sdk = sdk
        self.caches = caches ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        self.removeDomain = removeDomain
        self.sessionStartDelay = sessionStartDelay
    }

    private var queueFile: URL? { caches.map(Self.queueFile(in:)) }

    var isStopping: Bool { pendingStop != nil }

    func start(_ setup: AnalyticsSetup) {
        guard !hasStarted else { return }
        hasStarted = true
        let others = queueFile.map { Self.setAsideOthers(of: setup.appID, in: $0) } ?? []
        // NotificationCenter calls a notification's observers in the order they came: this one before the SDK's, made by
        // `initialize`, the next after it.
        quitObservers = [observeQuit { $0.appBeginsToQuit() }]
        sdk.initialize(setup)
        appID = setup.appID
        startedAt = Date()
        if let queueFile, !others.isEmpty { Self.putBack(others, into: queueFile) }
        quitObservers.append(observeQuit { $0.appWillTerminate() })
    }

    private func observeQuit(_ react: @escaping (TelemetryDeckTransport) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self { react(self) } }
        }
    }

    func send(_ name: String, parameters: [String: String], floatValue: Double?) {
        guard appID != nil, pendingStop == nil else { return }
        sdk.signal(name, parameters: parameters, floatValue: floatValue)
    }

    func stop() {
        guard appID != nil, pendingStop == nil else { return }
        // Nothing more is queued from here, the SDK's own signals included.
        sdk.disable()
        let wait = startedAt.addingTimeInterval(sessionStartDelay).timeIntervalSinceNow
        guard wait > 0 else {
            drop()
            return
        }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.drop() }
        }
        pendingStop = item
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
    }

    func deleteLeftovers(of appID: String) {
        Self.deleteLeftovers(of: appID, caches: caches, removeDomain: removeDomain)
    }

    /// The app begins to quit, before the SDK writes its queue over the file: what other apps have in it now (another app
    /// may have taken what was put back at start, or added its own since). Internal for the tests.
    func appBeginsToQuit() {
        guard appID != nil, let queueFile else { return }
        othersAtQuit = (Self.readQueue(queueFile) ?? []).filter { ($0["appID"] as? String) != appID }
    }

    /// The SDK has just written its queue: the other apps' signals go back beside it, and a stop still waiting drops the
    /// SDK now, deleting what it wrote. Internal for the tests.
    func appWillTerminate() {
        guard appID != nil else { return }
        if let queueFile, !othersAtQuit.isEmpty { Self.putBack(othersAtQuit, into: queueFile) }
        othersAtQuit = []
        if pendingStop != nil { drop() }
    }

    /// Drops the SDK, and with it the signals queued in memory, then deletes what is left on disk.
    private func drop() {
        pendingStop?.cancel()
        pendingStop = nil
        for observer in quitObservers { NotificationCenter.default.removeObserver(observer) }
        quitObservers = []
        guard let appID else { return }
        sdk.terminate()
        self.appID = nil
        deleteLeftovers(of: appID)
        // The SDK's session timer keeps ticking for the run (its counts live in a process-wide object), and a write it
        // began just before the drop may land just after the deletion: the suite goes once more, after any such write.
        let suite = Self.statsSuiteName(for: appID)
        let removeDomain = removeDomain
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.secondSweepDelay) { removeDomain(suite) }
    }

    // MARK: What the SDK keeps on this Mac

    /// The SDK's queue file (2.x): written as the app quits, read and deleted by the next `initialize`.
    static func queueFile(in caches: URL) -> URL {
        caches.appending(path: "telemetrysignalcache")
    }

    /// The SDK's own defaults suite for `appID`: its random user identifier and the session counts it sends.
    static func statsSuiteName(for appID: String) -> String {
        let digest = SHA256.hash(data: Data(appID.utf8)).map { String(format: "%02x", $0) }.joined()
        return "com.telemetrydeck.\(digest.suffix(12))"
    }

    /// Deletes `appID`'s queued signals and the SDK's defaults for it.
    static func deleteLeftovers(of appID: String, caches: URL?, removeDomain: (String) -> Void) {
        if let caches { deleteQueuedSignals(of: appID, from: queueFile(in: caches)) }
        removeDomain(statsSuiteName(for: appID))
    }

    /// Takes `appID`'s signals out of the queue file, keeping any other app's; the file goes when nothing is left.
    static func deleteQueuedSignals(of appID: String, from file: URL) {
        guard let queued = readQueue(file) else { return }
        let others = queued.filter { ($0["appID"] as? String) != appID }
        guard others.count != queued.count else { return }
        write(others, to: file)
    }

    /// Leaves only `appID`'s signals in the queue file for the SDK to read, and returns the others. A file nothing in
    /// which can be told to be anyone's (not the SDK's format) is left as it is.
    static func setAsideOthers(of appID: String, in file: URL) -> [[String: Any]] {
        guard let queued = readQueue(file) else { return [] }
        let others = queued.filter { ($0["appID"] as? String) != appID }
        guard !others.isEmpty else { return [] }
        write(queued.filter { ($0["appID"] as? String) == appID }, to: file)
        return others
    }

    /// Adds `signals` to what the queue file holds.
    static func putBack(_ signals: [[String: Any]], into file: URL) {
        write((readQueue(file) ?? []) + signals, to: file)
    }

    static func readQueue(_ file: URL) -> [[String: Any]]? {
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    }

    private static func write(_ signals: [[String: Any]], to file: URL) {
        if signals.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else if let data = try? JSONSerialization.data(withJSONObject: signals) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
