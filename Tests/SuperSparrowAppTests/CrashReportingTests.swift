import AppKit
import Sentry
import SSDesign
import SwiftUI
import XCTest
@testable import SuperSparrowApp

/// Crash reporting (docs/ARCHITECTURE.md, "Crash reports"): the SDK's options keep everything that could carry mail off,
/// every report is scrubbed before it leaves, breadcrumbs name code and never content, and Settings › General › Analytics
/// and reports turns it off. Nothing here starts the SDK: a test process must never send a report.
@MainActor
final class CrashReportingTests: XCTestCase {
    private let redactor = CrashRedactor(homeDirectory: "/Users/alex", userName: "alex")
    private var suites: [String] = []
    private var originalSink: ((Breadcrumb) -> Void)?

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated { originalSink = CrashReporting.breadcrumbSink }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            if let originalSink { CrashReporting.breadcrumbSink = originalSink }
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            suites = []
        }
        super.tearDown()
    }

    private func throwawayDefaults() throws -> UserDefaults {
        let suite = "SuperSparrowAppTests.CrashReporting.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func options() -> Options {
        CrashReporting.options(dsn: "https://key@o1.ingest.sentry.io/1", environment: "debug",
                               release: .init(info: ["CFBundleIdentifier": "io.supersparrow.mac", "CFBundleShortVersionString": "0.1.0",
                                                     "CFBundleVersion": "7"]),
                               redactor: redactor)
    }

    // MARK: Options

    func testTheSDKCollectsNothingThatCouldCarryMail() {
        let options = options()
        XCTAssertFalse(options.sendDefaultPii)
        XCTAssertFalse(options.enableSwizzling, "no instrumentation of the app's own calls")
        XCTAssertFalse(options.enableAutoBreadcrumbTracking, "window titles are subjects")
        XCTAssertFalse(options.enableNetworkBreadcrumbs, "Gmail and Graph URLs name messages and carry search words")
        XCTAssertFalse(options.enableCaptureFailedRequests)
        XCTAssertFalse(options.enableNetworkTracking)
        XCTAssertFalse(options.enableAutoPerformanceTracing)
        XCTAssertFalse(options.enableFileIOTracing)
        XCTAssertFalse(options.enableDataSwizzling)
        XCTAssertFalse(options.enableFileManagerSwizzling)
        XCTAssertFalse(options.enableCoreDataTracing)
        XCTAssertFalse(options.isTracingEnabled)
        XCTAssertFalse(options.enableMemoryIntrospection, "memory around a crash can hold a body")
        XCTAssertFalse(options.enableMetricKitRawPayload)
        XCTAssertFalse(options.enableLogs)
        XCTAssertFalse(options.enableSpotlight)
        XCTAssertNotNil(options.beforeSend)
        XCTAssertNotNil(options.beforeBreadcrumb)
        XCTAssertEqual(options.cacheDirectoryPath, CrashReporting.cacheDirectory.path,
                       "queued reports in a folder of the app's own, which turning reports off deletes")
        XCTAssertTrue(CrashReporting.cacheDirectory.path.hasSuffix("Caches/io.supersparrow.mac/Sentry"))
    }

    func testCrashesExceptionsHangsAndSessionsAreReported() {
        let options = options()
        XCTAssertTrue(options.enableCrashHandler)
        XCTAssertTrue(options.attachStacktrace)
        XCTAssertTrue(options.enableAutoSessionTracking)
        XCTAssertTrue(options.enableAppHangTracking)
        XCTAssertEqual(options.appHangTimeoutInterval, 2)
        XCTAssertTrue(options.enableMetricKit)
        // What AppKit catches is reported by `SuperSparrowApplication` and the app goes on; Sentry's own capture would
        // make every such exception end the app.
        XCTAssertFalse(options.enableUncaughtNSExceptionReporting)
        XCTAssertEqual(options.environment, "debug")
    }

    func testTheReleaseIsTheBundlesVersionAndBuild() {
        XCTAssertEqual(options().releaseName, "io.supersparrow.mac@0.1.0+7")
        XCTAssertEqual(options().dist, "7")
        let bare = CrashReporting.Release(info: nil)
        XCTAssertEqual(bare.name, "io.supersparrow.mac@0.0.0-dev+0", "a bare binary has no bundle to read")
    }

    func testTheDSNComesFromTheLaunchOptionsElseTheBundle() {
        var launch = LaunchOptions(arguments: ["SuperSparrow"])
        XCTAssertNil(CrashReporting.dsn(launch: launch, info: nil))
        XCTAssertNil(CrashReporting.dsn(launch: launch, info: ["SentryDSN": "  "]), "blank is none")
        XCTAssertEqual(CrashReporting.dsn(launch: launch, info: ["SentryDSN": " https://a@b.ingest.sentry.io/1\n"]),
                       "https://a@b.ingest.sentry.io/1")
        launch.sentryDSN = "http://k@127.0.0.1:9000/2"
        XCTAssertEqual(CrashReporting.dsn(launch: launch, info: ["SentryDSN": "https://a@b.ingest.sentry.io/1"]),
                       "http://k@127.0.0.1:9000/2")
    }

    func testNothingStartsWithoutADSNWhileTurnedOffOrForASnapshot() throws {
        let defaults = try throwawayDefaults()
        // The test bundle has no DSN.
        XCTAssertFalse(CrashReporting.start(launch: LaunchOptions(arguments: ["SuperSparrow"]), defaults: defaults,
                                            bundle: Bundle(for: Self.self)))
        XCTAssertTrue(CrashReporting.isEnabled(in: defaults), "on unless turned off")
        defaults.set(false, forKey: CrashReporting.enabledDefaultsKey)
        var launch = LaunchOptions(arguments: ["SuperSparrow"])
        launch.sentryDSN = "http://k@127.0.0.1:9/1"
        XCTAssertFalse(CrashReporting.start(launch: launch, defaults: defaults), "turned off in Settings")
        defaults.set(true, forKey: CrashReporting.enabledDefaultsKey)
        launch.snapshotPath = "/tmp/never.png"
        XCTAssertFalse(CrashReporting.start(launch: launch, defaults: defaults), "a snapshot run a timeout may end is no crash")
        XCTAssertFalse(CrashReporting.isRunning)
    }

    // MARK: Scrubbing

    func testAReportLeavesWithoutHomePathsNamesOrAddresses() throws {
        let event = Event(level: .fatal)
        event.serverName = "alex-macbook"
        let user = User(userId: "installation-1")
        user.email = "alex@contoso.test"
        user.ipAddress = "10.0.0.2"
        user.username = "alex"
        event.user = user
        event.message = SentryMessage(formatted: "Could not open /Users/alex/Downloads/Invoice for ben@fabrikam.test")
        event.tags = ["folder": "/Users/alex/Library"]
        event.extra = ["paths": ["/Users/alex/a.txt", "fine"], "count": 3]
        event.context = ["device": ["name": "Alex's MacBook Pro", "model": "Mac16,11"], "app": ["path": "/Users/alex/Apps/x"]]
        let exception = Exception(value: "-[NSURL initFileURLWithPath:]: /Users/alex/x for sam@contoso.test", type: "NSInvalidArgumentException")
        let frame = Frame()
        frame.package = "/Users/alex/Projects/supersparrow-macos/dist/SuperSparrow.app/Contents/MacOS/SuperSparrow"
        frame.function = "$s15SuperSparrowApp9CrashTestO3runyyFZ"
        frame.contextLine = "let subject = message.subject"
        exception.stacktrace = SentryStacktrace(frames: [frame], registers: [:])
        event.exceptions = [exception]
        let image = DebugMeta()
        image.codeFile = "/Users/alex/Projects/supersparrow-macos/dist/SuperSparrow.app/Contents/MacOS/SuperSparrow"
        event.debugMeta = [image]
        let crumb = Breadcrumb(level: .info, category: "action")
        crumb.message = "opened /Users/alex/Desktop for alex"
        event.breadcrumbs = [crumb]

        let scrubbed = CrashReportScrubber.scrub(event, with: redactor)
        XCTAssertNil(scrubbed.serverName)
        XCTAssertEqual(scrubbed.user?.userId, "installation-1", "the random installation id counts crash-free sessions")
        XCTAssertNil(scrubbed.user?.email)
        XCTAssertNil(scrubbed.user?.ipAddress)
        XCTAssertNil(scrubbed.user?.username)
        XCTAssertEqual(scrubbed.message?.formatted, "Could not open ~/Downloads/Invoice for <address>")
        XCTAssertEqual(scrubbed.tags?["folder"], "~/Library")
        XCTAssertEqual(scrubbed.extra?["paths"] as? [String], ["~/a.txt", "fine"])
        XCTAssertEqual(scrubbed.extra?["count"] as? Int, 3)
        XCTAssertNil(scrubbed.context?["device"]?["name"], "the Mac's name names its owner")
        XCTAssertEqual(scrubbed.context?["device"]?["model"] as? String, "Mac16,11")
        XCTAssertEqual(scrubbed.context?["app"]?["path"] as? String, "~/Apps/x")
        let value = try XCTUnwrap(scrubbed.exceptions?.first?.value)
        XCTAssertEqual(value, "-[NSURL initFileURLWithPath:]: ~/x for <address>")
        let scrubbedFrame = try XCTUnwrap(scrubbed.exceptions?.first?.stacktrace?.frames.first)
        XCTAssertEqual(scrubbedFrame.package, "~/Projects/supersparrow-macos/dist/SuperSparrow.app/Contents/MacOS/SuperSparrow")
        XCTAssertEqual(scrubbedFrame.function, "$s15SuperSparrowApp9CrashTestO3runyyFZ", "names from the code stay")
        XCTAssertNil(scrubbedFrame.contextLine, "no source lines")
        XCTAssertEqual(scrubbed.debugMeta?.first?.codeFile, "~/Projects/supersparrow-macos/dist/SuperSparrow.app/Contents/MacOS/SuperSparrow")
        XCTAssertEqual(scrubbed.breadcrumbs?.first?.message, "opened ~/Desktop for <user>")
    }

    func testTheRedactorTakesOutHomesAddressesAndTheUsersNameOnly() {
        XCTAssertEqual(redactor.redact("/Users/alex/x and /Users/sam/y"), "~/x and /Users/<user>/y")
        XCTAssertEqual(redactor.redact("Alex's Mac"), "<user>'s Mac")
        XCTAssertEqual(redactor.redact("alexander and malexa stay"), "alexander and malexa stay", "only the name as a word")
        XCTAssertEqual(redactor.redact("reply to first.last+tag@mail.example.co.uk now"), "reply to <address> now")
        XCTAssertEqual(redactor.redact("$s15SuperSparrowApp4MainC + 12 0x0000000100abc"), "$s15SuperSparrowApp4MainC + 12 0x0000000100abc")
        let short = CrashRedactor(homeDirectory: "/Users/al", userName: "al")
        XCTAssertEqual(short.redact("al formal"), "al formal", "a name too short to be told from words of the code stays")
        XCTAssertEqual(short.redact("/Users/al/x"), "~/x")
    }

    // MARK: Breadcrumbs

    func testAnActionLeavesItsSelectorsNameAndNothingElse() {
        var crumbs: [Breadcrumb] = []
        CrashReporting.breadcrumbSink = { crumbs.append($0) }
        CrashReporting.breadcrumb(action: #selector(NSText.copy(_:)))
        CrashReporting.breadcrumb(.sync, "poll failed", count: 3)
        XCTAssertEqual(crumbs.map(\.category), ["action", "sync"])
        XCTAssertEqual(crumbs.map(\.message), ["copy:", "poll failed"])
        XCTAssertEqual(crumbs.last?.data?["count"] as? Int, 3)
    }

    func testAWindowIsNamedByItsControllerNeverItsTitle() {
        var crumbs: [Breadcrumb] = []
        CrashReporting.breadcrumbSink = { crumbs.append($0) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered,
                              defer: true)
        window.isReleasedWhenClosed = false
        window.title = "Re: Contoso rollout"
        let controller = ReaderTestWindowController(window: window)
        CrashReporting.breadcrumb("key", window: window)
        XCTAssertEqual(crumbs.first?.message, "key ReaderTestWindowController")
        XCTAssertFalse(crumbs.contains { ($0.message ?? "").contains("Contoso") })
        withExtendedLifetime(controller) {}
    }

    // MARK: Settings

    func testAnalyticsAndReportsIsOnUnlessTurnedOffAndAppliesAtOnce() throws {
        let defaults = try throwawayDefaults()
        let settings = AppSettings(defaults: defaults)
        var applied: [Bool] = []
        settings.onAnalyticsAndReportsChanged = { applied.append($0) }
        XCTAssertTrue(settings.sendsAnalyticsAndReports)
        settings.sendsAnalyticsAndReports = false
        XCTAssertEqual(applied, [false])
        XCTAssertEqual(defaults.object(forKey: CrashReporting.enabledDefaultsKey) as? Bool, false)
        XCTAssertEqual(CrashReporting.enabledDefaultsKey, "sendsCrashReports", "the key crash reports had, so a choice made then holds")
        XCTAssertFalse(AppSettings(defaults: defaults).sendsAnalyticsAndReports, "kept across launches")
        XCTAssertFalse(CrashReporting.isEnabled(in: defaults), "read at launch, before the app delegate, from the same key")
    }

    func testGeneralShowsTheToggleWithWhatIsSentAndKeepsItsWidth() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        settings.onAnalyticsAndReportsChanged = { _ in }
        XCTAssertTrue(GeneralSettingsView.reportsCaption.contains("Never your mail or addresses"))
        for configured in [true, false] {
            var general = GeneralSettingsView(settings: settings, defaultMailApp: DefaultMailAppModel(handler: FakeMailtoHandler()),
                                              mailboxSize: MailboxSizeModel(measure: { 292_000_000 }),
                                              launchAtLogin: LaunchAtLoginModel(handler: FakeLoginItem()),
                                              notificationPermission: NotificationPermissionModel(handler: FakeNotificationPermission(.allowed)))
            general.reportServices = ReportServices(crashReports: configured, analytics: configured)
            let view = NSHostingView(rootView: general)
            ListTestSupport.spin(for: 0.05)
            view.layoutSubtreeIfNeeded()
            // The caption wraps inside the tab rather than widening Settings.
            XCTAssertEqual(view.fittingSize.width, Quire.Layout.Settings.width, accuracy: 0.5, "configured: \(configured)")
        }
    }
}

/// A window controller named like none of the app's, so the breadcrumb's text is the test's own.
private final class ReaderTestWindowController: NSWindowController {}
