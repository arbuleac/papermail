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
    func start(_ setup: AnalyticsSetup)
    func send(_ name: String, parameters: [String: String], floatValue: Double?)
    /// Stops sending at once and deletes what `appID`'s analytics left on this Mac (its queue on disk, the SDK's random
    /// identifier and session counts). Called while stopped too, for what an earlier run left.
    func stop(deleting appID: String?)
}

/// TelemetryDeck's Swift SDK (docs/ARCHITECTURE.md, "Analytics").
///
/// Two of its habits shape this: `TelemetryDeck.signal` and the session it starts half a second after `initialize`
/// reach for the shared manager, which a debug build traps on and a release build replaces with one of an empty app ID
/// if `terminate` has dropped it; so `Analytics` sends only while running, and a stop within that half second turns the
/// SDK off at once and drops it once the session has started. And it keeps its queue in memory, writing it to one file
/// in `~/Library/Caches` (shared, by name, with every unsandboxed app embedding the SDK) only as the app quits; so a
/// stop deletes SuperSparrow's own signals from that file and leaves any other app's.
@MainActor
final class TelemetryDeckTransport: AnalyticsTransport {
    /// The SDK starts its first session this long after `initialize`, through the shared manager.
    static let sessionStartDelay: TimeInterval = 0.6

    private var configuration: TelemetryDeck.Config?
    private var appID: String?
    private var startedAt = Date.distantPast
    /// A stop waiting for the SDK's first session, and the app ID whose leftovers it deletes.
    private var pendingStop: (item: DispatchWorkItem, deleting: String?)?
    private var quitObserver: NSObjectProtocol?

    nonisolated init() {}

    func start(_ setup: AnalyticsSetup) {
        // Turned on again before a stop had dropped the SDK: it carries on as it was.
        if let pending = pendingStop, let configuration, appID == setup.appID {
            pending.item.cancel()
            pendingStop = nil
            removeQuitObserver()
            configuration.analyticsDisabled = false
            return
        }
        finishPendingStop()
        let config = TelemetryDeck.Config(appID: setup.appID, baseURL: setup.baseURL)
        config.testMode = setup.testMode
        config.transmitInterval = setup.transmitInterval
        // No cookies or cache on disk for these requests.
        config.urlSession = URLSession(configuration: .ephemeral)
        // Errors only; the SDK's info lines name the cache file's path.
        config.logHandler = .standard(.error)
        TelemetryDeck.initialize(config: config)
        configuration = config
        appID = setup.appID
        startedAt = Date()
    }

    func send(_ name: String, parameters: [String: String], floatValue: Double?) {
        guard configuration != nil, pendingStop == nil else { return }
        TelemetryDeck.signal(name, parameters: parameters, floatValue: floatValue)
    }

    func stop(deleting appID: String?) {
        guard let configuration else {
            if let appID { Self.deleteLeftovers(of: appID) }
            return
        }
        guard pendingStop == nil else { return }
        // Nothing more is queued from here, the SDK's own signals included.
        configuration.analyticsDisabled = true
        let leftovers = appID ?? self.appID
        let wait = startedAt.addingTimeInterval(Self.sessionStartDelay).timeIntervalSinceNow
        guard wait > 0 else {
            drop(deleting: leftovers)
            return
        }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finishPendingStop() }
        }
        pendingStop = (item, leftovers)
        DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
        // Quitting before then: the SDK writes its queue to disk as the app quits (its observer came first), and this
        // deletes it straight after.
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil,
                                                              queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finishPendingStop() }
        }
    }

    private func finishPendingStop() {
        guard let pending = pendingStop else { return }
        pending.item.cancel()
        drop(deleting: pending.deleting)
    }

    private func removeQuitObserver() {
        if let quitObserver { NotificationCenter.default.removeObserver(quitObserver) }
        quitObserver = nil
    }

    /// Drops the SDK, and with it the signals queued in memory, then deletes what is left on disk.
    private func drop(deleting appID: String?) {
        pendingStop = nil
        removeQuitObserver()
        TelemetryDeck.terminate()
        configuration = nil
        self.appID = nil
        if let appID { Self.deleteLeftovers(of: appID) }
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

    /// Deletes `appID`'s queued signals and the SDK's defaults for it. `removeDomain` is the defaults' own removal but in
    /// tests, which must not touch the user's preferences.
    static func deleteLeftovers(of appID: String, caches: URL? = nil,
                                removeDomain: (String) -> Void = { UserDefaults.standard.removePersistentDomain(forName: $0) }) {
        let cachesDirectory = caches ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        if let cachesDirectory { deleteQueuedSignals(of: appID, from: queueFile(in: cachesDirectory)) }
        removeDomain(statsSuiteName(for: appID))
    }

    /// Takes `appID`'s signals out of the queue file, keeping any other app's; the file goes when nothing is left.
    static func deleteQueuedSignals(of appID: String, from file: URL) {
        guard let data = try? Data(contentsOf: file) else { return }
        // Not the SDK's format: nothing in it can be told to be ours, and the SDK drops such a file itself.
        guard let queued = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        let others = queued.filter { ($0["appID"] as? String) != appID }
        guard others.count != queued.count else { return }
        if others.isEmpty {
            try? FileManager.default.removeItem(at: file)
        } else if let kept = try? JSONSerialization.data(withJSONObject: others) {
            try? kept.write(to: file, options: .atomic)
        }
    }
}
