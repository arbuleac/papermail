import AppKit
import CryptoKit
import SSCore
import SSDesign
import SwiftUI
import XCTest
@testable import SuperSparrowApp

/// Analytics (docs/ARCHITECTURE.md, "Analytics"; the catalog in docs/ANALYTICS-AND-REPORTS.md): every signal's
/// parameters come from closed sets, the one switch stops it at once, a snapshot or a build without an app ID never
/// starts it, and the app's own paths send what the catalog says. Nothing here starts TelemetryDeck: every test sends
/// to a recorder, so no test process sends a signal or touches the SDK's files.
@MainActor
final class AnalyticsTests: XCTestCase {
    private var recorder = RecordingAnalyticsTransport()
    private var suites: [String] = []
    private var directories: [URL] = []

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            recorder = RecordingAnalyticsTransport()
            Analytics.reset(transport: recorder)
            // Timings are sampled at random; tests that want them ask.
            Analytics.performanceSampleRate = 0
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            Analytics.reset(transport: TelemetryDeckTransport())
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            suites = []
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
            directories = []
        }
        super.tearDown()
    }

    private func throwawayDefaults() throws -> UserDefaults {
        let suite = "SuperSparrowAppTests.Analytics.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func throwawayDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowAppTests-Analytics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    /// A launch with an app ID of its own, as `--telemetry-app-id` gives one.
    private func configuredLaunch() -> LaunchOptions {
        var launch = LaunchOptions(arguments: ["SuperSparrow"])
        launch.telemetryAppID = "TEST-APP-ID"
        return launch
    }

    /// Starts analytics on the recorder; the test bundle has no app ID of its own.
    private func startAnalytics(defaults: UserDefaults? = nil) throws {
        XCTAssertTrue(Analytics.start(launch: configuredLaunch(), defaults: try defaults ?? throwawayDefaults(), bundle: Bundle(for: Self.self)))
    }

    // MARK: The catalog

    /// Every case of the catalog, every enum value each takes and counts and durations across every bucket's edges.
    private static var everySignal: [AnalyticsSignal] {
        typealias S = AnalyticsSignal
        var signals: [S] = []
        let counts = [-1, 0, 1, 2, 5, 6, 10, 11, 20, 21, 50, 51, 199, 200, 10_000, Int.max]
        let durations: [Double] = [-1, 0, 0.0159, 0.016, 0.05, 0.1, 0.25, 0.4999, 0.5, 1, 2, 5, 60, 86_400, .infinity]
        for seconds in durations {
            for count in counts {
                signals.append(.launched(.init(seconds: seconds, gmailAccounts: count, microsoftAccounts: count, theme: .dusk,
                                               appearance: .dark, density: .compact, textSize: .larger, typeface: .sfPro)))
            }
            for sample in S.PerformanceSample.allCases { signals.append(.performance(sample, seconds: seconds)) }
        }
        for theme in QuireTheme.allCases {
            for appearance in AppAppearance.allCases {
                for size in QuireFont.TextSize.allCases {
                    for face in QuireFont.Typeface.allCases {
                        signals.append(.launched(.init(seconds: 0.4, gmailAccounts: 1, microsoftAccounts: 0, theme: theme,
                                                       appearance: appearance, density: .standard, textSize: size, typeface: face)))
                    }
                }
            }
        }
        signals.append(.settingsOpened)
        let changes: [S.SettingChange] = AppSettings.ListDensity.allCases.map(S.SettingChange.listDensity)
            + [true, false].flatMap { on in
                [S.SettingChange.accountInitials(on), .remoteImages(on), .notifications(on), .notificationPreviews(on),
                 .adaptMailColours(on)]
            }
            + ([5, 10, 20, 7, 0, -3, 1e9] as [TimeInterval]).map(S.SettingChange.undoSend)
            + MailRetention.allCases.map(S.SettingChange.keepMail)
            + QuireTheme.allCases.map(S.SettingChange.theme)
            + AppAppearance.allCases.map(S.SettingChange.appearance)
            + QuireFont.Typeface.allCases.map(S.SettingChange.font)
            + QuireFont.TextSize.allCases.map(S.SettingChange.textSize)
            + SendAction.allCases.map(S.SettingChange.sendAction)
        signals += changes.map(S.settingChanged)
        for action in S.MailAction.allCases {
            for trigger in S.Trigger.allCases {
                for count in counts { signals.append(.mailAction(action, trigger, conversations: count)) }
            }
        }
        for kind in S.ComposeKind.allCases {
            for origin in S.ComposeOrigin.allCases { signals.append(.composeStarted(kind, origin)) }
            signals += [.messageSent(kind, archives: true), .messageSent(kind, archives: false)]
        }
        for source in S.SendSource.allCases { signals += [.sendLaterScheduled(source), .sendUndone(source)] }
        for all in [true, false] {
            for archives in [true, false] { signals.append(.quickReplySent(replyAll: all, archives: archives)) }
        }
        for count in counts {
            for operators in counts {
                signals.append(.localSearch(operators: operators, results: count))
                for outcome in S.ServerSearchOutcome.allCases { signals.append(.serverSearch(outcome, operators: operators, found: count)) }
            }
        }
        for trigger in S.Trigger.allCases {
            signals += [.readerWindowOpened(trigger), .dayColumn(shown: true, trigger), .dayColumn(shown: false, trigger),
                        .weekOpened(trigger), .timeBlocked(trigger), .undo(trigger)]
        }
        signals += S.InvitationAnswer.allCases.map(S.invitationAnswered)
        for provider in S.Provider.allCases { signals += [.accountAdded(provider), .accountRemoved(provider)] }
        return signals
    }

    func testTheSamplesCoverEveryNameInTheCatalog() {
        XCTAssertEqual(Set(Self.everySignal.map(\.name)), Set(AnalyticsSignal.Name.allCases))
        XCTAssertEqual(AnalyticsSignal.Name.allCases.count, 22, "the catalog the doc lists")
    }

    /// (a) Every parameter of every signal, `mode` included, is a key of the vocabulary and takes one of its values.
    func testEverySignalsParametersComeFromClosedSets() throws {
        try startAnalytics()
        for demo in [true, false] {
            Analytics.setMode(demo: demo)
            for signal in Self.everySignal { Analytics.send(signal) }
        }
        XCTAssertEqual(recorder.sent.count, Self.everySignal.count * 2)
        for sent in recorder.sent {
            XCTAssertNotNil(AnalyticsSignal.Name(rawValue: sent.name))
            XCTAssertNotNil(sent.parameters["mode"], "every signal says which mailbox was on screen")
            for (key, value) in sent.parameters {
                let words = try XCTUnwrap(AnalyticsSignal.vocabulary[key], "\(sent.name): \(key) is in the vocabulary")
                XCTAssertTrue(words.contains(value), "\(sent.name): \(key)=\(value) is one of \(words)")
            }
        }
    }

    /// (d) No parameter value is longer than the longest value its key can take, and none looks like anything a user
    /// wrote: no @, no slash, no space.
    func testNoParameterIsLongerThanItsEnumValues() {
        for signal in Self.everySignal {
            for (key, value) in signal.parameters {
                let longest = AnalyticsSignal.vocabulary[key]?.map(\.count).max() ?? 0
                XCTAssertLessThanOrEqual(value.count, longest, "\(signal.name.rawValue): \(key)=\(value)")
                XCTAssertNil(value.rangeOfCharacter(from: CharacterSet(charactersIn: "@/: \n")), "\(key)=\(value)")
            }
        }
        let longestValue = AnalyticsSignal.vocabulary.values.joined().map(\.count).max() ?? 0
        XCTAssertLessThanOrEqual(longestValue, 20, "every value is a short word from the code")
    }

    /// docs/ANALYTICS-AND-REPORTS.md lists every signal, every parameter and every value they can take, so what the doc
    /// promises is what the code can send.
    func testTheDocListsEverySignalParameterAndValue() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let doc = try String(contentsOf: root.appendingPathComponent("docs/ANALYTICS-AND-REPORTS.md"), encoding: .utf8)
        for name in AnalyticsSignal.Name.allCases {
            XCTAssertTrue(doc.contains("| `\(name.rawValue)` |"), "the catalog's row for \(name.rawValue)")
        }
        for (key, values) in AnalyticsSignal.vocabulary {
            XCTAssertTrue(doc.contains("`\(key)`"), "the doc names \(key)")
            for value in values { XCTAssertTrue(doc.contains("`\(value)`"), "the doc lists \(key)=\(value)") }
        }
    }

    func testCountsAndDurationsAreBucketed() {
        typealias C = AnalyticsSignal.CountBuckets
        XCTAssertEqual([1, 2, 5, 6, 20, 21, 400].map(C.conversations.label), ["1", "2-5", "2-5", "6-20", "6-20", "21+", "21+"])
        XCTAssertEqual([0, 1, 2, 3, 5, 6, 30].map(C.accounts.label), ["0", "1", "2", "3-5", "3-5", "6+", "6+"])
        XCTAssertEqual([0, 1, 10, 11, 50, 51, 199, 200].map(C.results.label), ["0", "1-10", "1-10", "11-50", "11-50", "51-199", "51-199", "200+"])
        XCTAssertEqual(C.accounts.label(-4), "0", "below the first range is the first")
        typealias D = AnalyticsSignal.DurationBuckets
        XCTAssertEqual([0.004, 0.016, 0.049, 0.05, 0.12, 0.3, 2].map(D.interaction.label),
                       ["<16ms", "16-50ms", "16-50ms", "50-100ms", "100-250ms", "250ms-1s", "1s+"])
        XCTAssertEqual([0.2, 0.7, 1.5, 3, 9].map(D.launch.label), ["<0.5s", "0.5-1s", "1-2s", "2-5s", "5s+"])
        XCTAssertEqual(AnalyticsSignal.performance(.search, seconds: 0.012_345).floatValue, 12.3, "milliseconds to a tenth")
        let launch = AnalyticsSignal.Launch(seconds: 0.412_49, gmailAccounts: 1, microsoftAccounts: 0, theme: .study, appearance: .automatic,
                                            density: .standard, textSize: .default, typeface: .newYork)
        XCTAssertEqual(AnalyticsSignal.launched(launch).floatValue, 0.412, "seconds to the millisecond")
        XCTAssertNil(AnalyticsSignal.mailAction(.archive, .key, conversations: 3).floatValue)
    }

    func testOperatorsAreCountedAndTheWordsNeverKept() {
        func operators(_ text: String) -> Int { AnalyticsSignal.operators(in: SearchQuery(parsing: text)) }
        XCTAssertEqual(operators("lisbon trip"), 0)
        XCTAssertEqual(operators("\"lisbon trip\""), 0)
        XCTAssertEqual(operators("from:ana lisbon"), 1)
        XCTAssertEqual(operators("is:unread has:attachment -lisbon"), 3, "a negated word is an operator")
        XCTAssertEqual(AnalyticsSignal.operators(in: nil), 0)
        let signal = AnalyticsSignal.serverSearch(.found, operators: operators("from:ana@contoso.test lisbon"), found: 4)
        XCTAssertEqual(signal.parameters, ["outcome": "found", "operators": "1", "results": "1-10"])
    }

    func testMailActionsAreNamedFromTheirChange() {
        typealias A = AnalyticsSignal.MailAction
        XCTAssertEqual(A(.archive), .archive)
        XCTAssertEqual(A(.setStarred(true)), .star)
        XCTAssertEqual(A(.setStarred(false)), .unstar)
        XCTAssertEqual(A(.setRead(false)), .markUnread)
        XCTAssertEqual(A(.restoreFromTrash), .moveToInbox)
        XCTAssertNil(A(.markNotSpam), "an undo's inverse is no action of the user's")
    }

    // MARK: Starting and stopping

    /// (c) No app ID, the switch off, or a snapshot run: nothing starts, and nothing reaches the transport.
    func testNothingStartsWithoutAnAppIDWhileTurnedOffOrForASnapshot() throws {
        let defaults = try throwawayDefaults()
        let bundle = Bundle(for: Self.self)
        XCTAssertFalse(Analytics.start(launch: LaunchOptions(arguments: ["SuperSparrow"]), defaults: defaults, bundle: bundle),
                       "the test bundle has no TelemetryDeckAppID")
        XCTAssertNil(Analytics.appID(launch: LaunchOptions(arguments: ["SuperSparrow"]), info: [Analytics.appIDInfoKey: " \n"]), "blank is none")
        XCTAssertEqual(Analytics.appID(launch: LaunchOptions(arguments: ["SuperSparrow"]), info: [Analytics.appIDInfoKey: " ABC-1\n"]), "ABC-1")
        XCTAssertEqual(Analytics.appID(launch: configuredLaunch(), info: [Analytics.appIDInfoKey: "ABC-1"]), "TEST-APP-ID",
                       "the launch option wins")
        defaults.set(false, forKey: CrashReporting.enabledDefaultsKey)
        XCTAssertFalse(Analytics.start(launch: configuredLaunch(), defaults: defaults, bundle: bundle), "turned off in Settings")
        defaults.set(true, forKey: CrashReporting.enabledDefaultsKey)
        for snapshot in ["--snapshot=/tmp/never.png", "--snapshot-settings=/tmp/never.png", "--snapshot-alerts=/tmp/never.png",
                         "--snapshot-compose=/tmp/never.png"] {
            var launch = LaunchOptions(arguments: ["SuperSparrow", snapshot])
            launch.telemetryAppID = "TEST-APP-ID"
            XCTAssertFalse(Analytics.start(launch: launch, defaults: defaults, bundle: bundle), snapshot)
        }
        XCTAssertFalse(Analytics.isRunning)
        Analytics.send(.settingsOpened)
        XCTAssertTrue(recorder.started.isEmpty)
        XCTAssertTrue(recorder.sent.isEmpty)
    }

    func testAStartSendsTestSignalsInADebugBuildAndToALocalListenerWhenAsked() throws {
        var launch = configuredLaunch()
        launch.telemetryURL = "http://127.0.0.1:8978"
        XCTAssertTrue(Analytics.start(launch: launch, defaults: try throwawayDefaults(), bundle: Bundle(for: Self.self)))
        XCTAssertEqual(recorder.started, [AnalyticsSetup(appID: "TEST-APP-ID", baseURL: URL(string: "http://127.0.0.1:8978"),
                                                         testMode: true, transmitInterval: 5)])
        Analytics.setEnabled(false, launch: launch)
        try startAnalytics()
        XCTAssertEqual(recorder.started.last?.baseURL, nil, "TelemetryDeck's own server")
        XCTAssertEqual(recorder.started.last?.transmitInterval, 60, "never a timer faster than the background poll")
        XCTAssertFalse(Analytics.start(launch: configuredLaunch(), defaults: try throwawayDefaults()), "once is enough")
    }

    /// (b) The switch off stops sending at once and deletes what is queued; on starts it again.
    func testTurningTheSwitchOffStopsSendingAtOnce() throws {
        let defaults = try throwawayDefaults()
        let settings = AppSettings(defaults: defaults)
        let launch = configuredLaunch()
        settings.onAnalyticsAndReportsChanged = { Analytics.setEnabled($0, launch: launch, bundle: Bundle(for: Self.self)) }
        XCTAssertTrue(Analytics.start(launch: launch, defaults: defaults, bundle: Bundle(for: Self.self)))
        Analytics.send(.settingsOpened)
        XCTAssertEqual(recorder.sent.map(\.name), ["Settings.opened"])

        Analytics.searchSettleDelay = 0.05
        Analytics.searchSettled(operators: 0, results: 3)
        settings.sendsAnalyticsAndReports = false
        XCTAssertFalse(Analytics.isRunning)
        XCTAssertEqual(recorder.stops, ["TEST-APP-ID"], "the transport drops its queue and deletes TEST-APP-ID's leftovers")
        Analytics.send(.settingsOpened)
        Analytics.send(.mailAction(.archive, .key, conversations: 1))
        settings.listDensity = .compact
        Analytics.performanceSampleRate = 1
        Analytics.sample(.listRefresh, seconds: 0.01)
        ListTestSupport.spin(for: 0.2)
        XCTAssertEqual(recorder.sent.map(\.name), ["Settings.opened"], "nothing after the switch, the settling search included")
        XCTAssertEqual(defaults.object(forKey: CrashReporting.enabledDefaultsKey) as? Bool, false, "the one key both services read")
        XCTAssertFalse(Analytics.isEnabled(in: defaults))

        settings.sendsAnalyticsAndReports = true
        XCTAssertTrue(Analytics.isRunning, "on starts it again, without a relaunch")
        Analytics.send(.settingsOpened)
        XCTAssertEqual(recorder.sent.count, 2)
    }

    func testTheSettingIsTheCrashReportsKeySoAnEarlierOptOutHolds() throws {
        let defaults = try throwawayDefaults()
        defaults.set(false, forKey: "sendsCrashReports")
        XCTAssertFalse(AppSettings(defaults: defaults).sendsAnalyticsAndReports)
        XCTAssertFalse(Analytics.start(launch: configuredLaunch(), defaults: defaults, bundle: Bundle(for: Self.self)))
        XCTAssertTrue(AppSettings(defaults: try throwawayDefaults()).sendsAnalyticsAndReports, "on unless turned off")
    }

    // MARK: Sending

    func testTheTriggerIsAKeyElseTheWayInElseAMenu() throws {
        try XCTSkipIf(Analytics.isHandlingKey, "a test just before this one sent a key press")
        XCTAssertEqual(Analytics.trigger, .menu)
        XCTAssertEqual(Analytics.from(.swipe) { Analytics.trigger }, .swipe)
        XCTAssertEqual(Analytics.from(.toolbar) { Analytics.from(.drag) { Analytics.trigger } }, .toolbar, "the outermost way in wins")
        XCTAssertEqual(Analytics.trigger, .menu, "only for the step")
    }

    func testASearchCountsOnceTheUserStopsTyping() throws {
        try startAnalytics()
        Analytics.searchSettleDelay = 0.1
        Analytics.searchSettled(operators: 0, results: 1)
        Analytics.searchSettled(operators: 1, results: 40)
        ListTestSupport.spin(for: 0.3)
        Analytics.searchSettled(operators: 0, results: 0)
        Analytics.cancelPendingSearch()
        ListTestSupport.spin(for: 0.3)
        XCTAssertEqual(recorder.sent.map(\.parameters), [["operators": "1", "results": "11-50", "mode": "accounts"]])
    }

    func testTimingsAreSampledAndCapped() throws {
        try startAnalytics()
        Analytics.performanceSampleRate = 0
        for _ in 0..<50 { Analytics.sample(.listRefresh, seconds: 0.004) }
        XCTAssertTrue(recorder.sent.isEmpty)
        Analytics.performanceSampleRate = 1
        for _ in 0..<50 { Analytics.sample(.listRefresh, seconds: 0.004) }
        Analytics.sample(.search, seconds: 0.03)
        XCTAssertEqual(recorder.sent.filter { $0.name == "Performance.listRefresh" }.count, Analytics.performanceSamplesPerRun)
        XCTAssertEqual(recorder.sent.last?.parameters["duration"], "16-50ms")
        XCTAssertEqual(recorder.sent.last?.floatValue, 30)
    }

    func testASettingTheUserChangesIsSentWithItsNewValue() throws {
        try startAnalytics()
        let settings = AppSettings(defaults: try throwawayDefaults())
        settings.listDensity = .compact
        settings.listDensity = .compact
        settings.undoSendDelay = 20
        settings.keepMail = .threeMonths
        settings.setShowAccountInitialsByUser(true)
        settings.accountWasAdded(totalAccounts: 9)
        XCTAssertEqual(recorder.sent.map(\.parameters).map { [$0["setting"], $0["value"]] },
                       [["listDensity", "compact"], ["undoSend", "20s"], ["keepMail", "threeMonths"], ["accountInitials", "on"]],
                       "a value set again is no change, and the seventh account's initials are not the user's")
    }

    func testTheLaunchSaysHowTheAppLooksAndHowManyAccountsOfEachKind() throws {
        try startAnalytics()
        Analytics.setMode(demo: true)
        Analytics.send(.launched(.init(seconds: 0.62, gmailAccounts: 1, microsoftAccounts: 1, theme: .rain, appearance: .automatic,
                                       density: .standard, textSize: .large, typeface: .newYork)))
        let sent = try XCTUnwrap(recorder.sent.first)
        XCTAssertEqual(sent.name, "App.launched")
        XCTAssertEqual(sent.parameters, ["launchTime": "0.5-1s", "gmailAccounts": "1", "microsoftAccounts": "1", "theme": "rain",
                                         "appearance": "automatic", "density": "standard", "textSize": "large", "font": "newYork",
                                         "mode": "demo"])
        XCTAssertEqual(sent.floatValue, 0.62)
        let started = try XCTUnwrap(Analytics.secondsSinceProcessStart())
        XCTAssertGreaterThan(started, 0, "the kernel's start time of this process")
        XCTAssertLessThan(started, 24 * 3600)
    }

    // MARK: The app's paths

    /// The main window's actions send the catalog's signals, from the way in each took, and carry nothing of the mail.
    func testTheMainWindowsStepsSendTheirSignals() throws {
        try startAnalytics()
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.selectFirst(3)
        XCTAssertTrue(harness.controller.perform(.archive))
        harness.controller.performUndo(harness.controller.zTarget)
        let first = harness.list.conversations[0].id
        let second = harness.list.conversations[1].id
        XCTAssertTrue(Analytics.from(.drag) { harness.controller.drop([first], onto: .trash) })
        harness.controller.handle(.archive(second))
        Analytics.from(.toast) { harness.controller.performUndo(harness.controller.zTarget) }
        XCTAssertEqual(recorder.sent.map(\.name), ["Mail.action", "Undo.used", "Mail.action", "Mail.action", "Undo.used"])
        XCTAssertEqual(recorder.sent.map { $0.parameters["action"] ?? "-" }, ["archive", "-", "trash", "archive", "-"])
        // A step with no way in of its own is a menu's, unless a key is being handled (the last event a test ran may be one).
        let plain = Analytics.isHandlingKey ? "key" : "menu"
        XCTAssertEqual(recorder.sent.map { $0.parameters["trigger"] }, [plain, plain, "drag", "toolbar", "toast"])
        XCTAssertEqual(recorder.sent.first?.parameters["conversations"], "2-5")
        assertNothingOfTheMail(in: harness)
    }

    func testSearchesComposersAndReaderWindowsSendTheirSignals() throws {
        try startAnalytics()
        Analytics.searchSettleDelay = 0.05
        let harness = try MainWindowHarness()
        defer {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            harness.close()
        }
        harness.controller.listPane.runSearch("is:unread thread")
        harness.spin(until: { self.recorder.sent.contains { $0.name == "Search.local" } })
        let search = try XCTUnwrap(recorder.sent.first { $0.name == "Search.local" })
        XCTAssertEqual(search.parameters["operators"], "1")
        harness.controller.listPane.clearSearch(notify: true)
        harness.spin(until: { harness.list.query.search == nil })
        let id = harness.list.conversations[0].id
        _ = Analytics.from(.click) { harness.controller.openInNewWindow(id) }
        harness.controller.readerWindows.last?.close()
        harness.controller.composeNew()
        XCTAssertEqual(recorder.sent.filter { $0.name != "Search.local" && !$0.name.hasPrefix("Performance.") }.map(\.name),
                       ["Reader.windowOpened", "Compose.started"])
        XCTAssertEqual(recorder.sent.first { $0.name == "Reader.windowOpened" }?.parameters["trigger"], "click")
        XCTAssertEqual(recorder.sent.first { $0.name == "Compose.started" }?.parameters, ["kind": "new", "origin": "app", "mode": "accounts"])
        assertNothingOfTheMail(in: harness)
    }

    /// No value sent names an account, an address, a subject or a word of a body.
    private func assertNothingOfTheMail(in harness: MainWindowHarness, file: StaticString = #filePath, line: UInt = #line) {
        let store = harness.environment.store
        var words = Set<String>()
        for account in (try? store.accounts()) ?? [] {
            words.insert(account.email.lowercased())
            words.insert(account.displayName.lowercased())
        }
        for row in harness.list.conversations {
            words.insert(row.subject.lowercased())
        }
        words = words.filter { $0.count >= 3 }
        for sent in recorder.sent {
            for value in sent.parameters.values {
                XCTAssertFalse(words.contains(value.lowercased()), "\(sent.name) carries \(value)", file: file, line: line)
            }
        }
    }

    // MARK: What the SDK keeps on this Mac

    func testStoppingDeletesOnlyThisAppsQueuedSignals() throws {
        let caches = try throwawayDirectory()
        let file = TelemetryDeckTransport.queueFile(in: caches)
        XCTAssertEqual(file.lastPathComponent, "telemetrysignalcache", "the 2.x SDK's file")
        let queued: [[String: Any]] = [
            ["appID": "OURS", "type": "Mail.action", "payload": ["action": "archive"]],
            ["appID": "ANOTHER-APP", "type": "Something.else", "payload": [:]],
            ["appID": "OURS", "type": "Undo.used", "payload": [:]],
        ]
        try JSONSerialization.data(withJSONObject: queued).write(to: file)
        TelemetryDeckTransport.deleteQueuedSignals(of: "OURS", from: file)
        let left = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        XCTAssertEqual(left.compactMap { $0["appID"] as? String }, ["ANOTHER-APP"], "another app's signals are its own")
        TelemetryDeckTransport.deleteQueuedSignals(of: "ANOTHER-APP", from: file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "nothing left, no file")
        try Data("not json".utf8).write(to: file)
        TelemetryDeckTransport.deleteQueuedSignals(of: "OURS", from: file)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "a file nothing in which can be told to be ours stays")
    }

    func testStoppingDeletesTheSDKsIdentifierAndSessionCounts() throws {
        XCTAssertEqual(TelemetryDeckTransport.statsSuiteName(for: "abc"), "com.telemetrydeck.ff61f20015ad",
                       "the SDK's suite: the last 12 hex digits of SHA-256 of the app ID")
        let caches = try throwawayDirectory()
        try JSONSerialization.data(withJSONObject: [["appID": "OURS"]]).write(to: TelemetryDeckTransport.queueFile(in: caches))
        var removed: [String] = []
        TelemetryDeckTransport.deleteLeftovers(of: "OURS", caches: caches) { removed.append($0) }
        XCTAssertEqual(removed, [TelemetryDeckTransport.statsSuiteName(for: "OURS")], "the SDK's identifier and session counts go")
        XCTAssertFalse(FileManager.default.fileExists(atPath: TelemetryDeckTransport.queueFile(in: caches).path))
    }

    // MARK: Settings › General

    func testOneToggleNamesWhatThisBuildSendsTo() {
        typealias R = ReportServices
        XCTAssertEqual(R(crashReports: true, analytics: true).toggleTitle, "Send to Sentry and TelemetryDeck")
        XCTAssertEqual(R(crashReports: true, analytics: false).toggleTitle, "Send to Sentry")
        XCTAssertEqual(R(crashReports: false, analytics: true).toggleTitle, "Send to TelemetryDeck")
        XCTAssertFalse(R(crashReports: false, analytics: false).isConfigured)
        XCTAssertTrue(R(crashReports: false, analytics: true).isConfigured, "the switch governs the one this build has")
    }

    /// The caption says what goes and what never does in one line, as the crash reports caption did.
    func testTheCaptionIsOneLine() {
        func height(_ text: String) -> CGFloat {
            // As General's grid lays it out: across both columns, inset to the field column, at most 360 pt wide.
            let view = NSHostingView(rootView: QuireThemeRoot(Grid { QuireSettingsCaption(text) }.frame(width: Quire.Layout.Settings.width)))
            view.layoutSubtreeIfNeeded()
            return view.fittingSize.height
        }
        XCTAssertTrue(GeneralSettingsView.reportsCaption.contains("Never your mail or addresses"))
        XCTAssertEqual(height(GeneralSettingsView.reportsCaption), height("Not set up in this build."), accuracy: 0.5)
        XCTAssertGreaterThan(height("Crashes, hangs and which features you use. Never your mail or addresses."),
                             height(GeneralSettingsView.reportsCaption) + 1, "a longer caption would take two lines")
    }
}

/// Stands in for TelemetryDeck: what was started, sent and stopped, in order.
@MainActor
final class RecordingAnalyticsTransport: AnalyticsTransport {
    struct Sent: Equatable {
        var name: String
        var parameters: [String: String]
        var floatValue: Double?
    }

    private(set) var started: [AnalyticsSetup] = []
    private(set) var sent: [Sent] = []
    private(set) var stops: [String?] = []

    nonisolated init() {}

    func start(_ setup: AnalyticsSetup) { started.append(setup) }

    func send(_ name: String, parameters: [String: String], floatValue: Double?) {
        sent.append(Sent(name: name, parameters: parameters, floatValue: floatValue))
    }

    func stop(deleting appID: String?) { stops.append(appID) }
}
