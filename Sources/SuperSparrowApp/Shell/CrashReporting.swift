import AppKit
import Foundation
import Sentry

/// Crash reporting through Sentry (docs/ARCHITECTURE.md, "Crash reports"; setup in docs/CRASH-REPORTING.md).
///
/// Started in `main.swift` right after the application object and before anything else of the app's, so a crash at
/// launch is caught too. It is on unless Settings › General › Crash reports is off, and needs a DSN: the bundle's
/// `SentryDSN` (written by `scripts/build-app.sh` from `SENTRY_DSN` or `Resources/SentryDSN`), or `--sentry-dsn` in a
/// debug build. With neither, nothing starts.
///
/// Nothing a user wrote or received may reach a report. The SDK's own collectors that could see mail are off (network
/// breadcrumbs and failed requests: Gmail and Graph URLs name messages and carry search words; automatic breadcrumbs:
/// window titles are subjects; tracing; memory introspection near a crash; swizzling), breadcrumbs are names from the
/// code only (`breadcrumb(_:_:)` takes a `StaticString`), and `CrashReportScrubber` takes home paths, the account's
/// name, addresses and the Mac's name out of every event before it leaves.
enum CrashReporting {
    /// What a breadcrumb is about.
    enum Category: String, CaseIterable {
        case app
        case window
        case action
        case sync
        case memory
        /// Help Me Write's milestones (“write started”, …) and the provider's kind, as names from the code: never a prompt,
        /// a reply or a CLI's output (§5.55).
        case ai
    }

    /// Settings › General › Crash reports; on unless turned off.
    static let enabledDefaultsKey = "sendsCrashReports"
    /// The Info.plist key holding the project's DSN.
    static let dsnInfoKey = "SentryDSN"
    /// The main thread blocked this long is a hang worth a report (the sync line's spinner keeps turning at 1 s).
    static let appHangTimeout: TimeInterval = 2

    /// Where breadcrumbs go: the SDK, or a test's recorder. Set before any breadcrumb is left; read from any thread.
    nonisolated(unsafe) static var breadcrumbSink: (Breadcrumb) -> Void = { SentrySDK.addBreadcrumb($0) }

    /// Whether this process started the SDK.
    nonisolated(unsafe) private(set) static var isRunning = false

    // MARK: Starting

    /// Whether reports are on in `defaults`, the user's choice.
    static func isEnabled(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: enabledDefaultsKey) as? Bool ?? true
    }

    /// The DSN this build sends to: `--sentry-dsn` (debug builds), else the bundle's. Blank is none.
    static func dsn(launch: LaunchOptions, info: [String: Any]?) -> String? {
        let candidates = [launch.sentryDSN, info?[dsnInfoKey] as? String]
        return candidates.lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    /// Whether this build has a DSN to send to (Settings › General disables Crash reports without one).
    static var isConfigured: Bool {
        dsn(launch: LaunchOptions(), info: Bundle.main.infoDictionary) != nil
    }

    /// Starts the SDK unless the user turned reports off, the build has no DSN, or this is a snapshot run (a debug aid a
    /// timeout may kill, which is no crash). Returns whether it started.
    @discardableResult
    static func start(launch: LaunchOptions, defaults: UserDefaults = .standard, bundle: Bundle = .main) -> Bool {
        guard !isRunning, isEnabled(in: defaults), !launch.isSnapshot,
              let dsn = dsn(launch: launch, info: bundle.infoDictionary) else { return false }
        let release = Release(info: bundle.infoDictionary)
        SentrySDK.start(options: options(dsn: dsn, environment: environment, release: release, redactor: .current))
        isRunning = SentrySDK.isEnabled
        return isRunning
    }

    /// Settings › General › Crash reports. Off closes the SDK at once and deletes the reports it had queued on disk
    /// (a crash from an earlier run not yet sent), so none goes later; on starts it again.
    static func setEnabled(_ enabled: Bool, launch: LaunchOptions = LaunchOptions(), bundle: Bundle = .main) {
        if enabled {
            start(launch: launch, bundle: bundle)
        } else {
            if isRunning {
                SentrySDK.close()
                isRunning = false
            }
            try? FileManager.default.removeItem(at: cacheDirectory)
        }
    }

    /// The SDK's queue and its crash reports, in a folder of the app's own: by default they share
    /// `~/Library/Caches/io.sentry` and `SentryCrash` with every other unsandboxed app that embeds the SDK, and turning
    /// reports off must delete SuperSparrow's alone.
    static var cacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return caches.appending(path: "io.supersparrow.mac", directoryHint: .isDirectory)
            .appending(path: "Sentry", directoryHint: .isDirectory)
    }

    /// "debug" or "production", so a developer's own crashes never mix with users' in Sentry's issues.
    static var environment: String {
        #if DEBUG
        return "debug"
        #else
        return "production"
        #endif
    }

    /// The release a report belongs to, `io.supersparrow.mac@0.1.0+1` as Sentry names releases, with the build as its
    /// distribution, so an uploaded dSYM matches. A bare binary (`swift run`) has no bundle to read and is a dev release.
    struct Release: Equatable {
        let name: String
        let build: String

        init(info: [String: Any]?) {
            let identifier = info?["CFBundleIdentifier"] as? String ?? "io.supersparrow.mac"
            let version = info?["CFBundleShortVersionString"] as? String ?? "0.0.0-dev"
            build = info?["CFBundleVersion"] as? String ?? "0"
            name = "\(identifier)@\(version)+\(build)"
        }
    }

    /// The SDK's options. Internal so a test can hold every privacy choice in place.
    static func options(dsn: String, environment: String, release: Release, redactor: CrashRedactor) -> Options {
        let options = Options()
        options.dsn = dsn
        options.environment = environment
        options.releaseName = release.name
        options.dist = release.build
        options.cacheDirectoryPath = cacheDirectory.path
        options.sendDefaultPii = false
        options.enableCrashHandler = true
        options.attachStacktrace = true
        options.maxBreadcrumbs = 100
        // Crash-free sessions per release.
        options.enableAutoSessionTracking = true
        // The main thread blocked for 2 s, while the app runs; and what MetricKit saw (crashes and hangs the in-process
        // handler could not, CPU and disk-write excess), delivered at the next launch.
        options.enableAppHangTracking = true
        options.appHangTimeoutInterval = appHangTimeout
        options.enableMetricKit = true
        options.enableMetricKitRawPayload = false
        // AppKit catches an exception thrown on the main thread and goes on; `SuperSparrowApplication` reports it as an
        // error rather than letting Sentry make it crash the app (`NSApplicationCrashOnExceptions`). An exception no one
        // catches, on any other thread, still ends the app and is reported as the crash it is.
        options.enableUncaughtNSExceptionReporting = false
        // Nothing that could carry mail: no swizzling at all, no automatic or network breadcrumbs, no failed-request
        // events, no tracing, no memory read around a crash, no logs or metrics.
        options.enableSwizzling = false
        options.enableAutoBreadcrumbTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableCaptureFailedRequests = false
        options.enableNetworkTracking = false
        options.enableAutoPerformanceTracing = false
        options.enableFileIOTracing = false
        options.enableDataSwizzling = false
        options.enableFileManagerSwizzling = false
        options.enableCoreDataTracing = false
        options.tracesSampleRate = nil
        options.enableMemoryIntrospection = false
        options.enableLogs = false
        options.enableMetrics = false
        options.enableSpotlight = false
        options.beforeSend = { event in CrashReportScrubber.scrub(event, with: redactor) }
        options.beforeBreadcrumb = { crumb in CrashReportScrubber.scrub(crumb, with: redactor) }
        return options
    }

    // MARK: While running

    /// Tags every later report with the mode the app is in, so a crash in the demo reads as one.
    static func setMode(demo: Bool) {
        guard isRunning else { return }
        SentrySDK.configureScope { $0.setTag(value: demo ? "demo" : "accounts", key: "mode") }
    }

    /// Leaves a breadcrumb. The message is a name from the code: a `StaticString` cannot carry anything the user
    /// wrote or received.
    static func breadcrumb(_ category: Category, _ message: StaticString, count: Int? = nil) {
        leave(category, message.description, count: count)
    }

    /// A menu item, a button or a key equivalent: the action's selector, which names code, never content.
    static func breadcrumb(action: Selector) {
        leave(.action, NSStringFromSelector(action), count: nil)
    }

    /// A window: its controller's type, never its title (a reader window's title is a subject).
    @MainActor
    static func breadcrumb(_ message: StaticString, window: NSWindow) {
        let owner: Any = window.windowController ?? window
        leave(.window, "\(message) \(String(describing: type(of: owner)))", count: nil)
    }

    private static func leave(_ category: Category, _ message: String, count: Int?) {
        let crumb = Breadcrumb(level: .info, category: category.rawValue)
        crumb.message = message
        if let count { crumb.setData(value: count, key: "count") }
        breadcrumbSink(crumb)
    }

    /// An exception AppKit caught on the main thread and logged; the app goes on. Reported as an error with the stack it
    /// was thrown from: symbol names and image offsets, no data.
    static func reportCaughtException(_ exception: NSException) {
        guard isRunning else { return }
        SentrySDK.capture(exception: exception) { scope in
            scope.setLevel(.error)
            scope.setTag(value: "appkit", key: "caught_by")
            scope.setExtra(value: exception.callStackSymbols, key: "thrown_from")
        }
    }
}
