import AppKit
import CryptoKit
import PaperCore
import PaperDesign
import SwiftUI
import XCTest
@testable import PaperApp

/// Analytics (docs/ARCHITECTURE.md, "Analytics"; the catalog in docs/ANALYTICS-AND-REPORTS.md): every signal's
/// parameters come from closed sets, the one switch stops it at once, a snapshot or a build without an app ID never
/// starts it, and the app's own paths send what the catalog says. Nothing here starts TelemetryDeck: `Analytics` sends to
/// a recorder, and `TelemetryDeckTransport` to a stand-in for the SDK over a throwaway caches folder, so no test process
/// sends a signal or touches the SDK's files or the user's preferences.
@MainActor
final class AnalyticsTests: XCTestCase {
    private var recorder = RecordingAnalyticsTransport()
    /// The app's own defaults for these tests: where the started app ID is kept.
    private var appDefaults = UserDefaults.standard
    private var suites: [String] = []
    private var directories: [URL] = []
    private var draftFolder: URL?
    private var productionHooks: (active: () -> Bool, key: () -> Bool)?

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            productionHooks = (Analytics.appIsActive, Analytics.keyIsBeingHandled)
            recorder = RecordingAnalyticsTransport()
            let suite = "PaperAppTests.Analytics.\(UUID().uuidString)"
            suites.append(suite)
            appDefaults = UserDefaults(suiteName: suite) ?? .standard
            // The app is active and no key is being handled, whatever the test host's last event was.
            Analytics.reset(transport: recorder, defaults: appDefaults)
            // Timings are sampled at random; tests that want them ask.
            Analytics.performanceSampleRate = 0
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            Analytics.reset(transport: TelemetryDeckTransport(), defaults: .standard)
            if let productionHooks {
                Analytics.appIsActive = productionHooks.active
                Analytics.keyIsBeingHandled = productionHooks.key
            }
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            suites = []
            for directory in directories { try? FileManager.default.removeItem(at: directory) }
            directories = []
            if draftFolder != nil {
                for panel in ComposeWindowRegistry.shared.livePanels { panel.orderOut(nil); ComposeWindowRegistry.shared.unregister(panel) }
                for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
                ComposeDraftStore.shared.waitForWrites()
                ComposeDraftStore.shared.useDemoDirectory(false)
                draftFolder = nil
            }
        }
        super.tearDown()
    }

    private func throwawayDefaults() throws -> UserDefaults {
        let suite = "PaperAppTests.Analytics.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    /// Composers keep their drafts in a throwaway folder.
    private func useThrowawayDrafts() throws {
        let folder = try throwawayDirectory()
        draftFolder = folder
        ComposeDraftStore.shared.useDirectory(folder)
    }

    private func throwawayDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaperAppTests-Analytics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        directories.append(directory)
        return directory
    }

    /// A launch with an app ID of its own, as `--telemetry-app-id` gives one.
    private func configuredLaunch() -> LaunchOptions {
        var launch = LaunchOptions(arguments: ["Paper"])
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
                [S.SettingChange.accountFaces(on), .remoteImages(on), .notifications(on), .notificationPreviews(on),
                 .adaptMailColours(on), .launchAtLogin(on), .offerReaderMode(on), .blockTrackers(on)]
            }
            + [S.SettingChange.defaultMailApp]
            + ([5, 10, 20, 7, 0, -3, 1e9] as [TimeInterval]).map(S.SettingChange.undoSend)
            + MailRetention.allCases.map(S.SettingChange.keepMail)
            + QuireTheme.allCases.map(S.SettingChange.theme)
            + AppAppearance.allCases.map(S.SettingChange.appearance)
            + QuireFont.Typeface.allCases.map(S.SettingChange.font)
            + QuireFont.TextSize.allCases.map(S.SettingChange.textSize)
            + SendAction.allCases.map(S.SettingChange.sendAction)
            + (S.Writer.allCases.map(Optional.some) + [nil]).map(S.SettingChange.aiProvider)
            + [AccountFace.automatic, .monogram, .paper("fox")].map(S.SettingChange.accountFace)
            + S.Trigger.allCases.flatMap { [S.SettingChange.railNames(true, $0), .railNames(false, $0)] }
        signals += changes.map(S.settingChanged)
        for action in S.MailAction.allCases {
            for trigger in S.Trigger.allCases {
                for count in counts { signals.append(.mailAction(action, trigger, conversations: count)) }
            }
        }
        for kind in S.ComposeKind.allCases {
            for origin in S.ComposeOrigin.allCases {
                signals.append(.composeStarted(kind, origin, nil))
                for trigger in S.Trigger.allCases { signals.append(.composeStarted(kind, origin, trigger)) }
            }
            signals += [.messageSent(kind, archives: true), .messageSent(kind, archives: false)]
        }
        for source in S.SendSource.allCases { signals += [.sendLaterScheduled(source), .sendUndone(source)] }
        for all in [true, false] {
            for archives in [true, false] { signals.append(.quickReplySent(replyAll: all, archives: archives)) }
        }
        for count in counts {
            for operators in counts {
                signals.append(.localSearch(operators: operators, results: count))
                for outcome in S.ServerSearchOutcome.allCases {
                    signals.append(.serverSearch(outcome, operators: operators, found: count, seconds: Double(count) / 10))
                }
            }
        }
        for seconds in [-1, 0, 0.49, 0.5, 1, 2, 5, 10, 600, .infinity] as [Double] {
            signals.append(.serverSearch(.found, operators: 1, found: 3, seconds: seconds))
        }
        for trigger in S.Trigger.allCases {
            signals += [.readerWindowOpened(trigger), .dayColumn(shown: true, trigger), .dayColumn(shown: false, trigger),
                        .weekOpened(trigger), .timeBlocked(trigger), .undo(trigger)]
            for view in MailboxView.allCases { signals += [.viewOpened(view, unified: true, trigger), .viewOpened(view, unified: false, trigger)] }
        }
        signals += S.InvitationAnswer.allCases.map(S.invitationAnswered)
        for provider in S.Provider.allCases { signals += [.accountAdded(provider), .accountRemoved(provider)] }
        for writer in S.Writer.allCases {
            for ending in S.WriteEnding.allCases {
                signals.append(.helpMeWriteUsed(writer, ending, nil))
                for draft in S.WriteDraft.allCases {
                    for source in S.SendSource.allCases {
                        // What was being written is one of the composers' kinds, never a kept draft's `draft`.
                        for kind in S.ComposeKind.allCases where kind != .draft {
                            for flags in [(false, false), (true, false), (false, true), (true, true)] {
                                for subject in [false, true] {
                                    signals.append(.helpMeWriteUsed(writer, ending, .init(draft: draft, instruction: flags.0,
                                                                                          retry: flags.1, source: source, kind: kind,
                                                                                          subject: subject)))
                                }
                            }
                        }
                    }
                }
            }
        }
        // A selection's rewrite: whether the draft around it went, and how the words beside it came out (only with the
        // draft, on a finished write). Apart from the loop above, which it would multiply.
        for writer in S.Writer.allCases {
            for ending in S.WriteEnding.allCases {
                for around in S.WriteAround.allCases {
                    signals.append(.helpMeWriteUsed(writer, ending, .init(draft: .selection, instruction: false, retry: false,
                                                                          source: .quickReply, kind: .reply, subject: false,
                                                                          around: around)))
                }
            }
            for join in S.WriteJoinResult.allCases {
                signals.append(.helpMeWriteUsed(writer, .finished, .init(draft: .selection, instruction: true, retry: false,
                                                                         source: .composer, kind: .new, subject: false,
                                                                         around: .draft, join: join)))
            }
        }
        for trigger in S.Trigger.allCases {
            signals += [.readerModeSwitched(on: true, trigger), .readerModeSwitched(on: false, trigger),
                        .quotedText(shown: true, trigger), .quotedText(shown: false, trigger)]
            signals += S.AttachmentAction.allCases.map { S.attachmentUsed($0, trigger) }
        }
        signals += S.ReaderLine.allCases.map(S.readerVersionSwitched)
        signals += counts.map { S.trackersBlocked(count: $0) }
        signals.append(.linkCleaned)
        for provider in S.Provider.allCases {
            signals.append(.senderRuleRemoved(provider))
            for permission in S.Permission.allCases {
                signals += [.permissionAsked(permission, granted: true, provider), .permissionAsked(permission, granted: false, provider)]
            }
        }
        return signals
    }

    func testTheSamplesCoverEveryNameInTheCatalog() {
        XCTAssertEqual(Set(Self.everySignal.map(\.name)), Set(AnalyticsSignal.Name.allCases))
        XCTAssertEqual(AnalyticsSignal.Name.allCases.count, 32, "the catalog the doc lists")
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

    /// Help me write's kinds and endings are the writer's own: the four kinds Settings › AI offers (the demo's made-up
    /// writer is none) and every milestone but the start.
    func testHelpMeWritesValuesAreTheWritersOwn() {
        XCTAssertEqual(AIProviderKind.allCases.compactMap { AnalyticsSignal.Writer($0)?.rawValue }, AIProviderKind.selectable.map(\.rawValue))
        XCTAssertNil(AnalyticsSignal.Writer(.demo))
        XCTAssertEqual(AIWriteMilestone.allCases.compactMap { AnalyticsSignal.WriteEnding($0)?.rawValue }, ["finished", "failed", "stopped"])
    }

    /// Writes Help me write's tests started and saw end.
    private var writesEnded = 0

    /// Starts a write with `configuration` through `center`'s writer, counted in `writesEnded` once its stream is over, a
    /// failure included (the test reads that from the signal instead).
    private func write(_ center: HelpMeWrite, _ configuration: AIProviderConfiguration) {
        let request = AIWriteRequest(kind: .reply, instructions: "Write the reply.", transcript: "Lunch in Lisbon on Thursday?",
                                     task: "Say yes")
        let stream = center.writer.write(request, using: configuration, in: AIFieldID(name: "analytics"),
                                         action: AIUserAction(userPressed: .write))
        Task { @MainActor [weak self] in
            do { for try await _ in stream {} } catch {}
            self?.writesEnded += 1
        }
    }

    /// Help me write counts a write once, as it ends: the kind of provider and how it ended, never the instruction, the
    /// conversation or a word of the reply. The scripted writer stands in for Claude here.
    func testAHelpMeWriteIsCountedAsItEndsWithItsProviderKindOnly() throws {
        try startAnalytics()
        let script = DemoAIScript()
        script.delay = .zero
        script.reply = "Thursday works for me."
        let center = HelpMeWrite(keys: InMemoryAIKeyStore(), isDemo: false, demoScript: script) { _ in DemoAIProvider(script: script) }
        center.consentOverride = [.claudeAPI]
        let claude = AIProviderConfiguration(kind: .claudeAPI)
        writesEnded = 0
        write(center, claude)
        XCTAssertTrue(ListTestSupport.spin(until: { self.writesEnded == 1 && self.recorder.sent.count == 1 }, timeout: 5), "a finished write")
        script.failure = .offline
        write(center, claude)
        XCTAssertTrue(ListTestSupport.spin(until: { self.writesEnded == 2 && self.recorder.sent.count == 2 }, timeout: 5), "a failed write")
        XCTAssertEqual(recorder.sent.map(\.name), ["HelpMeWrite.used", "HelpMeWrite.used"])
        XCTAssertEqual(recorder.sent.map { $0.parameters["aiProvider"] }, ["claudeAPI", "claudeAPI"])
        XCTAssertEqual(recorder.sent.map { $0.parameters["ending"] }, ["finished", "failed"])
        XCTAssertEqual(Set(recorder.sent.flatMap(\.parameters.keys)), ["aiProvider", "ending", "mode"])
        XCTAssertEqual(script.requests.count, 2, "both writes reached the writer")
    }

    /// A write's signal says what was being written, what it worked from and where, as `WriteSession` set it when it
    /// started, by kind only, and the field forgets it once the write is over.
    func testAHelpMeWriteSaysWhatItWorkedFromAndWhere() throws {
        try startAnalytics()
        let script = DemoAIScript()
        script.delay = .zero
        script.reply = "Thursday works for me."
        let center = HelpMeWrite(keys: InMemoryAIKeyStore(), isDemo: false, demoScript: script) { _ in DemoAIProvider(script: script) }
        center.consentOverride = [.claudeAPI]
        let field = AIFieldID(name: "analytics")
        center.writeDetails[field] = .init(WriteAsk(instruction: "warmer", draft: .notes("yes thursday")), retry: true, source: .quickReply,
                                           kind: .new, subject: true)
        writesEnded = 0
        write(center, AIProviderConfiguration(kind: .claudeAPI))
        XCTAssertTrue(ListTestSupport.spin(until: { self.writesEnded == 1 && self.recorder.sent.count == 1 }, timeout: 5))
        let sent = try XCTUnwrap(recorder.sent.first)
        XCTAssertEqual(sent.parameters["draft"], "notes")
        XCTAssertEqual(sent.parameters["instruction"], "on")
        XCTAssertEqual(sent.parameters["retry"], "on")
        XCTAssertEqual(sent.parameters["source"], "quickReply")
        XCTAssertEqual(sent.parameters["kind"], "new", "the composers' own word for a new message")
        XCTAssertEqual(sent.parameters["subject"], "on", "a subject was asked for: on or off, never the subject")
        XCTAssertEqual(Set(sent.parameters.keys), ["aiProvider", "ending", "draft", "instruction", "retry", "source", "kind", "subject", "mode"])
        XCTAssertFalse(sent.parameters.values.contains { $0.contains("warmer") || $0.contains("thursday") }, "never the words")
        XCTAssertNil(center.writeDetails[field], "forgotten once the write is over")
    }

    /// What was being written is said in the composers' kinds, so a write lines up with `Compose.started` and
    /// `Compose.sent`: every kind a composer opens as, and never `draft`, which a write's field cannot say.
    func testAHelpMeWritesKindIsOneAComposerOpensAs() throws {
        let id = MessageID(accountID: AccountID("a"), providerID: "m")
        let opened = [ComposeMode.new, .reply(id, all: false), .reply(id, all: true), .forward(id)].map { AnalyticsSignal.ComposeKind($0) }
        XCTAssertEqual(opened.map(\.rawValue), ["new", "reply", "replyAll", "forward"])
        XCTAssertFalse(opened.contains(.draft))
        for kind in opened {
            let details = AnalyticsSignal.WriteDetails(draft: .empty, instruction: false, retry: false, source: .composer, kind: kind,
                                                       subject: false)
            let parameters = AnalyticsSignal.helpMeWriteUsed(.claudeAPI, .finished, details).parameters
            XCTAssertEqual(parameters["kind"], kind.rawValue)
            XCTAssertEqual(parameters["subject"], "off")
        }
    }

    /// The quick reply's and a reply composer's writes say what they are as they end: a reply, where it ran, and that no
    /// subject was asked for. Through the window's own session, to the scripted writer.
    func testAWriteInTheWindowSaysItIsAReply() throws {
        try startAnalytics()
        try useThrowawayDrafts()
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.settings.aiProvider = .claudeAPI
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        let script = try XCTUnwrap(harness.environment.helpMeWrite.demoScript)
        script.delay = .zero
        script.reply = "Tuesday at ten works."
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentMessages.count == 3 }
        func used() -> [RecordingAnalyticsTransport.Sent] { recorder.sent.filter { $0.name == "HelpMeWrite.used" } }

        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        let field = harness.reader.quickReplyBar.writingTextView
        field.insertText("tue 10 ok", replacementRange: NSRange(location: 0, length: 0))
        harness.reader.helpMeWrite(nil)
        XCTAssertTrue(ListTestSupport.spin(until: { used().count == 1 }, timeout: 5), "the quick reply's write ends")
        XCTAssertEqual(used().last?.parameters["kind"], "reply")
        XCTAssertEqual(used().last?.parameters["subject"], "off")
        XCTAssertEqual(used().last?.parameters["source"], "quickReply")
        XCTAssertEqual(used().last?.parameters["draft"], "notes")

        let accounts = harness.controller.accounts
        let original = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-2-2")
        let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                       mode: .reply(original, all: true))
        defer { composer.closeWithoutSaving() }
        composer.window?.makeFirstResponder(composer.bodyEditor)
        composer.helpMeWrite(nil)
        XCTAssertTrue(ListTestSupport.spin(until: { used().count == 2 }, timeout: 5), "the composer's write ends")
        XCTAssertEqual(used().last?.parameters["kind"], "replyAll", "a reply to all, as `Compose.sent` says it")
        XCTAssertEqual(used().last?.parameters["subject"], "off")
        XCTAssertEqual(used().last?.parameters["source"], "composer")
        XCTAssertEqual(used().last?.parameters["draft"], "empty")
        XCTAssertFalse(used().flatMap(\.parameters.values).contains { $0.contains("tue") || $0.contains("Tuesday") }, "never the words")
        XCTAssertFalse(used().contains { $0.parameters["around"] != nil || $0.parameters["join"] != nil },
                       "whole writes carry neither of a rewrite's parameters")
    }

    /// A selection's rewrite says whether the user's draft around it went with it and, when it did and the write
    /// finished, how the words beside it came out (§5.56): from the writer's milestone, as the write ends. Never a word.
    func testARewriteSaysWhetherItsDraftWentAndHowItJoined() throws {
        try startAnalytics()
        try useThrowawayDrafts()
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.settings.aiProvider = .claudeAPI
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        let script = try XCTUnwrap(harness.environment.helpMeWrite.demoScript)
        script.delay = .zero
        script.reply = "Priya and Ben\n<<<AFTER {fence}>>>are coming tomorrow<<<END AFTER {fence}>>>"
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentMessages.count == 3 }
        func used() -> [RecordingAnalyticsTransport.Sent] { recorder.sent.filter { $0.name == "HelpMeWrite.used" } }

        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        let field = harness.reader.quickReplyBar.writingTextView
        field.insertText("John is coming tomorrow.", replacementRange: NSRange(location: 0, length: 0))
        field.setSelectedRange(NSRange(location: 0, length: 4))
        harness.reader.helpMeWrite(nil)
        XCTAssertTrue(ListTestSupport.spin(until: { used().count == 1 }, timeout: 5))
        XCTAssertEqual(used().last?.parameters["draft"], "selection")
        XCTAssertEqual(used().last?.parameters["around"], "draft")
        XCTAssertEqual(used().last?.parameters["join"], "after")
        XCTAssertEqual(field.string, "Priya and Ben are coming tomorrow.")

        script.reply = "Priya and Ben"
        field.undoManager?.undo()
        field.setSelectedRange(NSRange(location: 0, length: 4))
        harness.reader.helpMeWrite(nil)
        XCTAssertTrue(ListTestSupport.spin(until: { used().count == 2 }, timeout: 5))
        XCTAssertEqual(used().last?.parameters["join"], "none", "no seam line came")

        script.failure = .offline
        field.undoManager?.undo()
        field.setSelectedRange(NSRange(location: 0, length: 4))
        harness.reader.helpMeWrite(nil)
        XCTAssertTrue(ListTestSupport.spin(until: { used().count == 3 }, timeout: 5))
        XCTAssertEqual(used().last?.parameters["ending"], "failed")
        XCTAssertEqual(used().last?.parameters["around"], "draft")
        XCTAssertNil(used().last?.parameters["join"], "said only of a finished write")
        XCTAssertFalse(used().flatMap(\.parameters.values).contains { $0.contains("John") || $0.contains("Priya") }, "never the words")

        // The selection alone: `alone`, and no join, as the writer reads nothing beside it.
        let center = harness.environment.helpMeWrite
        script.failure = nil
        let alone = AIFieldID(name: "alone")
        center.writeDetails[alone] = .init(WriteAsk(draft: .selection("see u thurs")), retry: false, source: .composer, kind: .reply,
                                           subject: false)
        let request = AIWriteRequest(kind: .reply, instructions: "", transcript: "", task: "part", isRewrite: true, fence: "1a2b3c4d")
        let stream = center.writer.write(request, using: AIProviderConfiguration(kind: .claudeAPI), in: alone,
                                         action: AIUserAction(userPressed: .write))
        Task { do { for try await _ in stream {} } catch {} }
        XCTAssertTrue(ListTestSupport.spin(until: { used().count == 4 }, timeout: 5))
        XCTAssertEqual(used().last?.parameters["around"], "alone")
        XCTAssertNil(used().last?.parameters["join"])
    }

    /// Block trackers' link cleaning (§5.60) counts a link only when it lost something, and only while the setting is on.
    func testALinkCountsWhenItLosesItsTrackingParameters() throws {
        try startAnalytics()
        let policy = ConversationNavigationPolicy()
        policy.stripsTrackingParameters = true
        let tracked = try XCTUnwrap(URL(string: "https://shop.test/item?id=4&utm_source=news&fbclid=abc"))
        XCTAssertEqual(policy.outgoing(tracked).absoluteString, "https://shop.test/item?id=4")
        _ = policy.outgoing(try XCTUnwrap(URL(string: "https://shop.test/item?id=4")))
        policy.stripsTrackingParameters = false
        _ = policy.outgoing(tracked)
        XCTAssertEqual(recorder.sent.map(\.name), ["Trackers.linkCleaned"])
        XCTAssertEqual(recorder.sent.first?.parameters.keys.sorted(), ["mode"], "nothing of the link")
    }

    /// The demo's sheet and Settings › AI say a reply it makes up sends nothing: such a write sends no signal, whichever
    /// provider the demo's Settings chose. A demo CLI run for real (`--live-ai-clis`) sends its conversation, and counts.
    func testAReplyTheDemoMakesUpSendsNoSignal() throws {
        try startAnalytics()
        let center = HelpMeWrite.demo(isDemo: true)
        let script = try XCTUnwrap(center.demoScript)
        script.delay = .zero
        let settings = AppSettings(defaults: try throwawayDefaults())
        center.settings = settings
        writesEnded = 0
        for (index, kind) in AIProviderKind.selectable.enumerated() {
            settings.setAIProvider(kind, demo: true)
            settings.setAIConsent(true, for: kind, demo: true)
            let configuration = try XCTUnwrap(center.configuration)
            XCTAssertEqual(configuration.kind, kind, "the demo's own choice, never the demo writer's kind")
            write(center, configuration)
            XCTAssertTrue(ListTestSupport.spin(until: { self.writesEnded == index + 1 }, timeout: 5), "\(kind): the write ended")
        }
        XCTAssertEqual(script.requests.count, AIProviderKind.selectable.count, "every write was made up on this Mac")
        ListTestSupport.spin(for: 0.1)
        XCTAssertEqual(recorder.sent.map(\.name), [], "and none of them was counted")
        for milestone in AIWriteMilestone.allCases {
            XCTAssertNil(center.analyticsSignal(milestone, .demo))
        }

        let live = HelpMeWrite.demo(isDemo: true, liveCLIs: true)
        XCTAssertEqual(live.analyticsSignal(.finished, .claudeCode), .helpMeWriteUsed(.claudeCode, .finished, nil))
        XCTAssertNil(live.analyticsSignal(.finished, .claudeAPI), "the demo's API providers still make replies up")
        XCTAssertNil(live.analyticsSignal(.started, .claudeCode), "a write counts as it ends")
    }

    /// A drop on the quick reply opens its composer from a drag; Open in Composer, a button in the reader, from the toolbar.
    func testAQuickReplyDropOpensItsComposerFromADrag() throws {
        try startAnalytics()
        try useThrowawayDrafts()
        let harness = try MainWindowHarness()
        defer {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            harness.close()
        }
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentMessages.count == 3 }
        let bar = harness.reader.quickReplyBar
        bar.onOpenInComposer?("", .reply)
        try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.first).closeWithoutSaving()
        XCTAssertFalse(bar.isComposerOpen)

        let file = try throwawayDirectory().appendingPathComponent("brief.txt")
        try Data("brief".utf8).write(to: file)
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AnalyticsTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        let drag = FakeDraggingInfo(pasteboard: pasteboard, source: nil, mask: .copy)
        XCTAssertEqual(bar.draggingEntered(drag), .copy)
        XCTAssertTrue(bar.performDragOperation(drag))
        XCTAssertEqual(ComposeWindowRegistry.shared.openControllers.first?.contents.attachments.map(\.filename), ["brief.txt"])
        let started = recorder.sent.filter { $0.name == "Compose.started" }
        XCTAssertEqual(started.map { $0.parameters["kind"] }, ["reply", "reply"])
        XCTAssertEqual(started.map { $0.parameters["trigger"] }, ["toolbar", "drag"])
        assertNothingOfTheMail(in: harness)
    }

    func testCountsAndDurationsAreBucketed() {
        typealias C = AnalyticsSignal.CountBuckets
        XCTAssertEqual([0, 1, 2, 5, 6, 20, 21, 400].map(C.conversations.label), ["0", "1", "2-5", "2-5", "6-20", "6-20", "21+", "21+"],
                       "0 is its own: Always Archive sends it for a sender no Inbox holds")
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
        let search = AnalyticsSignal.serverSearch(.nothing, operators: 0, found: 0, seconds: 1.234_56)
        XCTAssertEqual(search.parameters["searchTime"], "1-2s")
        XCTAssertEqual(search.floatValue, 1.235, "seconds to the millisecond")
        XCTAssertNil(AnalyticsSignal.performance(.search, seconds: .infinity).floatValue, "a number the SDK could not encode is none")
        XCTAssertEqual(AnalyticsSignal.composeStarted(.reply, .mailLink, .key).parameters["trigger"], nil,
                       "a mail link comes from another app")
        XCTAssertEqual(AnalyticsSignal.composeStarted(.reply, .app, .toolbar).parameters["trigger"], "toolbar")
    }

    func testOperatorsAreCountedAndTheWordsNeverKept() {
        func operators(_ text: String) -> Int { AnalyticsSignal.operators(in: SearchQuery(parsing: text)) }
        XCTAssertEqual(operators("lisbon trip"), 0)
        XCTAssertEqual(operators("\"lisbon trip\""), 0)
        XCTAssertEqual(operators("from:ana lisbon"), 1)
        XCTAssertEqual(operators("is:unread has:attachment -lisbon"), 3, "a negated word is an operator")
        XCTAssertEqual(AnalyticsSignal.operators(in: nil), 0)
        let signal = AnalyticsSignal.serverSearch(.found, operators: operators("from:ana@contoso.test lisbon"), found: 4, seconds: 0.3)
        XCTAssertEqual(signal.parameters, ["outcome": "found", "operators": "1", "results": "1-10", "searchTime": "<0.5s"])
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
        XCTAssertFalse(Analytics.start(launch: LaunchOptions(arguments: ["Paper"]), defaults: defaults, bundle: bundle),
                       "the test bundle has no TelemetryDeckAppID")
        XCTAssertNil(Analytics.appID(launch: LaunchOptions(arguments: ["Paper"]), info: [Analytics.appIDInfoKey: " \n"]), "blank is none")
        XCTAssertEqual(Analytics.appID(launch: LaunchOptions(arguments: ["Paper"]), info: [Analytics.appIDInfoKey: " ABC-1\n"]), "ABC-1")
        XCTAssertEqual(Analytics.appID(launch: configuredLaunch(), info: [Analytics.appIDInfoKey: "ABC-1"]), "TEST-APP-ID",
                       "the launch option wins")
        defaults.set(false, forKey: CrashReporting.enabledDefaultsKey)
        XCTAssertFalse(Analytics.start(launch: configuredLaunch(), defaults: defaults, bundle: bundle), "turned off in Settings")
        defaults.set(true, forKey: CrashReporting.enabledDefaultsKey)
        for snapshot in ["--snapshot=/tmp/never.png", "--snapshot-settings=/tmp/never.png", "--snapshot-alerts=/tmp/never.png",
                         "--snapshot-compose=/tmp/never.png"] {
            var launch = LaunchOptions(arguments: ["Paper", snapshot])
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
        XCTAssertFalse(Analytics.start(launch: configuredLaunch(), defaults: try throwawayDefaults()), "once is enough")

        Analytics.reset(transport: recorder, defaults: appDefaults)
        try startAnalytics(defaults: appDefaults)
        XCTAssertEqual(recorder.started.last?.baseURL, nil, "TelemetryDeck's own server")
        XCTAssertEqual(recorder.started.last?.transmitInterval, 60, "never a timer faster than the background poll")
        XCTAssertEqual(appDefaults.string(forKey: Analytics.startedAppIDDefaultsKey), "TEST-APP-ID", "kept, for a later clean-up")
    }

    /// (b) The switch off stops sending at once and deletes what is queued. On again in the same run, it waits for the next
    /// launch: the SDK's session counts outlive its stop in the process, and would come back under a new identifier.
    func testTurningTheSwitchOffStopsSendingAtOnce() throws {
        let defaults = try throwawayDefaults()
        let settings = AppSettings(defaults: defaults)
        let launch = configuredLaunch()
        settings.onAnalyticsAndReportsChanged = { Analytics.setEnabled($0) }
        XCTAssertTrue(Analytics.start(launch: launch, defaults: defaults, bundle: Bundle(for: Self.self)))
        Analytics.send(.settingsOpened)
        XCTAssertEqual(recorder.sent.map(\.name), ["Settings.opened"])

        Analytics.searchSettleDelay = 0.05
        Analytics.searchSettled(operators: 0, results: 3)
        settings.sendsAnalyticsAndReports = false
        XCTAssertFalse(Analytics.isRunning)
        XCTAssertEqual(recorder.stops, 1, "the transport drops its queue and deletes TEST-APP-ID's leftovers")
        XCTAssertTrue(recorder.deleted.isEmpty, "the running app ID's are the stop's")
        XCTAssertNil(defaults.string(forKey: Analytics.startedAppIDDefaultsKey), "nothing left to clean up after")
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
        XCTAssertFalse(Analytics.isRunning, "on again: from the next launch")
        XCTAssertTrue(Analytics.resumesAtNextLaunch)
        Analytics.send(.settingsOpened)
        XCTAssertEqual(recorder.sent.count, 1)
        XCTAssertEqual(recorder.started.count, 1, "the SDK starts once a process")
    }

    /// The SDK starts once the app is active, so its session begins in front; signals sent before then follow it, and a
    /// switch turned off and on before then starts it at once, the SDK never having started.
    func testTheSDKStartsOnceTheAppIsActiveAndWhatCameBeforeFollows() throws {
        Analytics.appIsActive = { false }
        try startAnalytics()
        XCTAssertTrue(Analytics.isRunning)
        XCTAssertTrue(recorder.started.isEmpty, "not before the app is active")
        Analytics.send(.settingsOpened)
        Analytics.setEnabled(false)
        XCTAssertEqual(recorder.stops, 0, "nothing had started")
        Analytics.setEnabled(true)
        XCTAssertTrue(Analytics.isRunning, "on again at once: no SDK has run in this process")
        for _ in 0..<(Analytics.heldLimit + 20) { Analytics.send(.undo(.key)) }
        XCTAssertTrue(recorder.sent.isEmpty)

        Analytics.appBecameActive()
        XCTAssertEqual(recorder.started.count, 1)
        XCTAssertEqual(recorder.sent.count, Analytics.heldLimit, "held until then, at most so many; the turned-off one never")
        Analytics.send(.settingsOpened)
        XCTAssertEqual(recorder.sent.last?.name, "Settings.opened", "sent straight on from then")
        Analytics.appBecameActive()
        XCTAssertEqual(recorder.started.count, 1, "once")
    }

    /// A launch with the switch off deletes what analytics left before: for the build's app ID and the one it last
    /// started with (a stop that came as the app quit, or a write of the SDK's that landed after a stop).
    func testALaunchWithTheSwitchOffDeletesWhatEarlierRunsLeft() throws {
        let defaults = try throwawayDefaults()
        defaults.set(false, forKey: CrashReporting.enabledDefaultsKey)
        defaults.set("EARLIER-APP-ID", forKey: Analytics.startedAppIDDefaultsKey)
        XCTAssertFalse(Analytics.start(launch: configuredLaunch(), defaults: defaults, bundle: Bundle(for: Self.self)))
        XCTAssertEqual(recorder.deleted, ["EARLIER-APP-ID", "TEST-APP-ID"])
        XCTAssertNil(defaults.string(forKey: Analytics.startedAppIDDefaultsKey))
        XCTAssertTrue(recorder.started.isEmpty)
    }

    /// A build that sends to another app ID, or to none, deletes what the last one left; the switch on, it keeps the new.
    func testABuildWithAnotherAppIDOrNoneDeletesWhatTheLastOneLeft() throws {
        let defaults = try throwawayDefaults()
        defaults.set("EARLIER-APP-ID", forKey: Analytics.startedAppIDDefaultsKey)
        XCTAssertFalse(Analytics.start(launch: LaunchOptions(arguments: ["Paper"]), defaults: defaults, bundle: Bundle(for: Self.self)))
        XCTAssertEqual(recorder.deleted, ["EARLIER-APP-ID"], "a build without an app ID")
        XCTAssertNil(defaults.string(forKey: Analytics.startedAppIDDefaultsKey))

        Analytics.reset(transport: recorder, defaults: appDefaults)
        defaults.set("EARLIER-APP-ID", forKey: Analytics.startedAppIDDefaultsKey)
        XCTAssertTrue(Analytics.start(launch: configuredLaunch(), defaults: defaults, bundle: Bundle(for: Self.self)))
        XCTAssertEqual(recorder.deleted, ["EARLIER-APP-ID", "EARLIER-APP-ID"], "a build sending to another")
        XCTAssertEqual(defaults.string(forKey: Analytics.startedAppIDDefaultsKey), "TEST-APP-ID")
    }

    func testTheSettingIsTheCrashReportsKeySoAnEarlierOptOutHolds() throws {
        let defaults = try throwawayDefaults()
        defaults.set(false, forKey: "sendsCrashReports")
        XCTAssertFalse(AppSettings(defaults: defaults).sendsAnalyticsAndReports)
        XCTAssertFalse(Analytics.start(launch: configuredLaunch(), defaults: defaults, bundle: Bundle(for: Self.self)))
        XCTAssertTrue(AppSettings(defaults: try throwawayDefaults()).sendsAnalyticsAndReports, "on unless turned off")
    }

    /// The SDK's own signals (the session, a new install) carry `mode` too, through its default parameters.
    func testTheSDKsOwnSignalsSayWhichMailboxIsOnScreen() {
        Analytics.setMode(demo: true)
        XCTAssertEqual(Analytics.sdkParameters(), ["mode": "demo"])
        Analytics.setMode(demo: false)
        XCTAssertEqual(Analytics.sdkParameters(), ["mode": "accounts"])
        var launch = configuredLaunch()
        launch.demo = true
        Analytics.start(launch: launch, defaults: appDefaults, bundle: Bundle(for: Self.self))
        XCTAssertEqual(Analytics.sdkParameters(), ["mode": "demo"], "from the launch, before the demo's window says so")
    }

    // MARK: Sending

    func testTheTriggerIsAKeyElseTheWayInElseAMenu() throws {
        XCTAssertEqual(Analytics.trigger, .menu)
        XCTAssertEqual(Analytics.from(.swipe) { Analytics.trigger }, .swipe)
        XCTAssertEqual(Analytics.from(.toolbar) { Analytics.from(.drag) { Analytics.trigger } }, .toolbar, "the outermost way in wins")
        XCTAssertEqual(Analytics.trigger, .menu, "only for the step")
        Analytics.keyIsBeingHandled = { true }
        XCTAssertEqual(Analytics.from(.drag) { Analytics.trigger }, .key, "a key being handled wins over the way in")
        XCTAssertEqual(Analytics.trigger, .key)
    }

    func testAStepTheAppTakesOnItsOwnSendsNothing() throws {
        try startAnalytics()
        Analytics.quietly { Analytics.send(.settingsOpened) }
        Analytics.send(.undo(.key))
        XCTAssertEqual(recorder.sent.map(\.name), ["Undo.used"])
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

    /// One in twenty, at most twenty of each kind an hour: a run left open for days is measured all along.
    func testTimingsAreSampledAndCappedEachHour() throws {
        try startAnalytics()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        Analytics.now = { now }
        Analytics.performanceSampleRate = 0
        for _ in 0..<50 { Analytics.sample(.listRefresh, seconds: 0.004) }
        XCTAssertTrue(recorder.sent.isEmpty)
        Analytics.performanceSampleRate = 1
        for _ in 0..<50 { Analytics.sample(.listRefresh, seconds: 0.004) }
        Analytics.sample(.search, seconds: 0.03)
        let refreshes = { self.recorder.sent.filter { $0.name == "Performance.listRefresh" }.count }
        XCTAssertEqual(refreshes(), Analytics.performanceSamplesPerHour)
        XCTAssertEqual(recorder.sent.last?.parameters["duration"], "16-50ms")
        XCTAssertEqual(recorder.sent.last?.floatValue, 30)
        now += 3599
        Analytics.sample(.listRefresh, seconds: 0.004)
        XCTAssertEqual(refreshes(), Analytics.performanceSamplesPerHour, "still the same hour")
        now += 1
        for _ in 0..<50 { Analytics.sample(.listRefresh, seconds: 0.004) }
        XCTAssertEqual(refreshes(), 2 * Analytics.performanceSamplesPerHour, "the next hour's")
    }

    func testASettingTheUserChangesIsSentWithItsNewValue() throws {
        try startAnalytics()
        let settings = AppSettings(defaults: try throwawayDefaults())
        settings.listDensity = .compact
        settings.listDensity = .compact
        settings.undoSendDelay = 20
        settings.keepMail = .threeMonths
        settings.setShowAccountFacesByUser(true)
        settings.accountWasAdded(totalAccounts: 9)
        XCTAssertEqual(recorder.sent.map(\.parameters).map { [$0["setting"], $0["value"]] },
                       [["listDensity", "compact"], ["undoSend", "20s"], ["keepMail", "threeMonths"], ["accountFaces", "on"]],
                       "a value set again is no change, and the seventh account's initials are not the user's")
    }

    /// Settings › Experimental (§5.58): each experiment is sent with its new value only; reader mode switched from the reader
    /// is a signal of its own with its way in, moved by its gate it is the gate's change alone, and a value a snapshot holds
    /// in memory is never sent.
    func testTheExperimentsAreSentWithTheirNewValueOnly() throws {
        try startAnalytics()
        let settings = AppSettings(defaults: try throwawayDefaults())
        settings.offersReaderMode = true
        settings.readerModeOn = false
        Analytics.from(.toolbar) { settings.readerModeOn = true }
        settings.offersReaderMode = false
        settings.blocksTrackers = true
        settings.blocksTrackers = true
        XCTAssertEqual(recorder.sent.map(\.name), ["Settings.changed", "ReaderMode.switched", "ReaderMode.switched", "Settings.changed",
                                                   "Settings.changed"])
        XCTAssertEqual(recorder.sent.map(\.parameters).map { [$0["setting"], $0["value"], $0["trigger"]] },
                       [["offerReaderMode", "on", nil], [nil, "off", "menu"], [nil, "on", "toolbar"], ["offerReaderMode", "off", nil],
                        ["blockTrackers", "on", nil]])

        let held = AppSettings(defaults: try throwawayDefaults())
        held.keepsExperimentsInMemory = true
        held.offersReaderMode = true
        held.readerModeOn = false
        held.blocksTrackers = true
        XCTAssertEqual(recorder.sent.count, 5, "a snapshot's held values are never sent")
    }

    /// The rail's names (§5.2) are the one setting changed outside Settings in two ways, View › Show Names in Rail and a
    /// drag of the rail's edge, so its change says which. A drag counts once, as it ends, and only if it left the rail
    /// another way than it found it; no other setting carries a trigger.
    func testTheRailsNamesAreSentWithTheWayTheyWereAsked() throws {
        try startAnalytics()
        let harness = try MainWindowHarness()
        defer {
            harness.close()
            // The rail changed width: the split's autosave is the test process's own, and forgotten.
            UserDefaults.standard.removeObject(forKey: "NSSplitView Subview Frames MainSplit")
        }
        let controller = harness.controller
        let split = try XCTUnwrap(controller.splitView as? HairlineSplitView)
        controller.toggleRailNames(nil)
        XCTAssertTrue(controller.showsRailNames)
        // The edge dragged past halfway, back, and let go where it began: the rail followed, and nothing changed.
        split.onRailEdgeDrag?(false)
        XCTAssertFalse(controller.showsRailNames)
        split.onRailEdgeDrag?(true)
        split.onRailEdgeDragEnd?()
        XCTAssertEqual(recorder.sent.count, 1, "a drag that ends where it began is no change")
        split.onRailEdgeDrag?(false)
        XCTAssertEqual(recorder.sent.count, 1, "a drag still held is not a choice yet")
        split.onRailEdgeDragEnd?()
        Analytics.keyIsBeingHandled = { true }
        controller.toggleRailNames(nil)
        Analytics.keyIsBeingHandled = { false }
        XCTAssertEqual(recorder.sent.map(\.name), ["Settings.changed", "Settings.changed", "Settings.changed"])
        XCTAssertEqual(recorder.sent.map(\.parameters).map { [$0["setting"], $0["value"], $0["trigger"]] },
                       [["railNames", "on", "menu"], ["railNames", "off", "drag"], ["railNames", "on", "key"]])
        XCTAssertEqual(recorder.sent.last?.parameters.keys.sorted(), ["mode", "setting", "trigger", "value"])
        harness.settings.listDensity = .compact
        XCTAssertNil(recorder.sent.last?.parameters["trigger"], "the other settings say only their new value")
        XCTAssertEqual(AnalyticsSignal.SettingChange.values(of: .railNames), ["on", "off"])
        assertNothingOfTheMail(in: harness)
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
        // A step with no way in of its own is a menu's (no key is being handled here).
        XCTAssertEqual(recorder.sent.map { $0.parameters["trigger"] }, ["menu", "menu", "drag", "toolbar", "toast"])
        XCTAssertEqual(recorder.sent.first?.parameters["conversations"], "2-5")
        assertNothingOfTheMail(in: harness)
    }

    /// Always Archive Mail from This Sender counts the conversations it took out of every Inbox, both accounts' (spec
    /// §5.52), bucketed, none included ("0", the rule set for a sender no Inbox holds), and nothing of the sender.
    func testAlwaysArchiveSendsTheConversationsItArchived() throws {
        try startAnalytics()
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let accounts = [ListTestSupport.accountA, ListTestSupport.accountB]
        func mail(_ index: Int, from sender: String, roles: Set<MailboxRole>) -> MessageMetadata {
            let account = accounts[index % 2]
            return MessageMetadata(id: MessageID(accountID: account.id, providerID: "\(sender)-\(index)"),
                                   conversationID: ConversationID(accountID: account.id, providerID: "\(sender)-\(index)"),
                                   subject: "Issue \(index)", snippet: "", from: EmailAddress(name: "Weekly", address: "\(sender)@letter.example"),
                                   date: Date().addingTimeInterval(-Double(index) - 5), roles: roles, isRead: false, isStarred: false,
                                   hasAttachments: false)
        }
        try harness.environment.store.upsertMessages((0..<3).map { mail($0, from: "news", roles: [.inbox]) } + [mail(0, from: "quiet", roles: [])])
        func open(_ id: ConversationID) {
            harness.spin { harness.list.conversations.contains { $0.id == id } }
            harness.list.selectedConversationID = id
            harness.list.onSelectionChange?(id)
            harness.spin { harness.reader.currentConversationID == id && !harness.reader.currentMessages.isEmpty }
        }
        func lastAction() -> [String: String]? { recorder.sent.last { $0.name == "Mail.action" }?.parameters }

        open(ConversationID(accountID: accounts[0].id, providerID: "news-0"))
        harness.controller.alwaysArchiveSender(nil)
        harness.spin { lastAction() != nil }
        XCTAssertEqual(lastAction()?["action"], "alwaysArchiveSender")
        XCTAssertEqual(lastAction()?["conversations"], "2-5", "three conversations, in both accounts")
        XCTAssertEqual(lastAction()?["trigger"], "menu")

        // A sender whose only mail is archived already: the rule is set, and archived none.
        XCTAssertTrue(harness.controller.perform(.goTo(.all)))
        open(ConversationID(accountID: accounts[0].id, providerID: "quiet-0"))
        let count = recorder.sent.count
        harness.controller.alwaysArchiveSender(nil)
        harness.spin { self.recorder.sent.count > count && lastAction()?["conversations"] == "0" }
        XCTAssertEqual(lastAction()?["action"], "alwaysArchiveSender")
        XCTAssertEqual(lastAction()?["conversations"], "0")

        // A sender whose other Inbox mail sits beside someone else's: that row stays in the Inbox, so it is not counted.
        let solo = ConversationID(accountID: accounts[0].id, providerID: "solo-0")
        let mixed = ConversationID(accountID: accounts[1].id, providerID: "solo-mixed")
        try harness.environment.store.upsertMessages([
            mail(0, from: "solo", roles: [.inbox]),
            MessageMetadata(id: MessageID(accountID: mixed.accountID, providerID: "solo-mixed-1"), conversationID: mixed, subject: "Hi",
                            snippet: "", from: EmailAddress(address: "solo@letter.example"), date: Date().addingTimeInterval(-30),
                            roles: [.inbox], isRead: false, isStarred: false, hasAttachments: false),
            MessageMetadata(id: MessageID(accountID: mixed.accountID, providerID: "solo-mixed-2"), conversationID: mixed, subject: "Hi",
                            snippet: "", from: EmailAddress(address: "ben@example.com"), date: Date().addingTimeInterval(-40),
                            roles: [.inbox], isRead: false, isStarred: false, hasAttachments: false),
        ])
        XCTAssertTrue(harness.controller.perform(.goTo(.inbox)))
        open(solo)
        let before = recorder.sent.count
        harness.controller.alwaysArchiveSender(nil)
        harness.spin { self.recorder.sent.count > before && lastAction()?["conversations"] == "1" }
        XCTAssertEqual(lastAction()?["conversations"], "1", "the open conversation alone left the Inbox")
        for sent in recorder.sent {
            XCTAssertFalse(sent.parameters.values.contains { $0.contains("letter") || $0.contains("@") }, "\(sent.name) names no sender")
        }
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
        XCTAssertEqual(recorder.sent.first { $0.name == "Compose.started" }?.parameters,
                       ["kind": "new", "origin": "app", "trigger": "menu", "mode": "accounts"])
        assertNothingOfTheMail(in: harness)
    }

    /// Where people go: a view or scope the user picks counts when it moves the window, with whether it is All Inboxes or
    /// one account, never which; picking where the window already is, or the rail's own fall-back, does not.
    func testMovingToAnotherViewOrScopeSendsWhereAndHow() throws {
        try startAnalytics()
        let harness = try MainWindowHarness()
        defer { harness.close() }
        XCTAssertTrue(harness.controller.perform(.goTo(.starred)))
        XCTAssertTrue(harness.controller.perform(.goTo(.starred)))
        Analytics.from(.rail) { harness.controller.strip.selectShortcut(1) }
        Analytics.from(.rail) { harness.controller.strip.selectShortcut(1) }
        Analytics.keyIsBeingHandled = { true }
        harness.controller.strip.selectShortcut(0)
        Analytics.keyIsBeingHandled = { false }
        Analytics.quietly { harness.controller.goTo(.sent) }
        let opened = recorder.sent.filter { $0.name == "View.opened" }
        XCTAssertEqual(opened.map(\.parameters), [
            ["view": "starred", "scope": "unified", "trigger": "menu", "mode": "accounts"],
            ["view": "starred", "scope": "account", "trigger": "rail", "mode": "accounts"],
            ["view": "starred", "scope": "unified", "trigger": "key", "mode": "accounts"],
        ])
        assertNothingOfTheMail(in: harness)
    }

    /// A reader window's menu items (the menu bar's, its context menu's) are a menu's steps, not its buttons'.
    func testAReaderWindowsMenuItemsAreAMenusSteps() throws {
        try startAnalytics()
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = harness.list.conversations[0].id
        let reader = try XCTUnwrap(harness.controller.openInNewWindow(id))
        reader.toggleStarSelection(nil)
        let starred = recorder.sent.last { $0.name == "Mail.action" }?.parameters["action"] == "star"
        reader.conversation.onAction?(.star(id, !starred))
        let actions = recorder.sent.filter { $0.name == "Mail.action" }
        XCTAssertEqual(actions.map { $0.parameters["action"] }, starred ? ["star", "unstar"] : ["unstar", "star"])
        XCTAssertEqual(actions.map { $0.parameters["trigger"] }, ["menu", "toolbar"], "the menu item, then the header's button")
    }

    /// A composer counts as it opens: a kept reply reopened is a draft, and one already open only brought forward is none.
    func testAComposerCountsOnceAsItOpens() throws {
        try useThrowawayDrafts()
        try startAnalytics()
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.selectFirst(1)
        let reply = #selector(MainWindowController.replyToSelection(_:))
        NSApp.sendAction(reply, to: harness.controller, from: nil)
        let composer = try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.last)
        composer.bodyEditor.insertText("Sounds good", replacementRange: NSRange(location: 0, length: 0))
        composer.window?.performClose(nil)
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertTrue(ComposeWindowRegistry.shared.openControllers.isEmpty, "closed, its draft kept")
        NSApp.sendAction(reply, to: harness.controller, from: nil)
        NSApp.sendAction(reply, to: harness.controller, from: nil)
        XCTAssertEqual(ComposeWindowRegistry.shared.openControllers.count, 1)
        XCTAssertEqual(recorder.sent.filter { $0.name == "Compose.started" }.map { $0.parameters["kind"] }, ["reply", "draft"])
    }

    /// A quick reply's countdown moved to the undo panel and undone there is still the quick reply's send.
    func testAQuickReplyUndoneFromThePanelIsTheQuickReplys() throws {
        try useThrowawayDrafts()
        try startAnalytics()
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let message = OutgoingMessage(accountID: ListTestSupport.accountA.id, to: [EmailAddress(name: "Ben", address: "ben@example.com")],
                                      subject: "Lisbon", html: "<p>See you there</p>", text: "See you there")
        let draft = ComposeDraft(id: UUID(), mode: .new, account: ListTestSupport.accountA, to: message.to, cc: [], bcc: [],
                                 subject: "Lisbon", body: ComposeTextView.plainBody("See you there"), attachments: [], quoted: nil,
                                 threading: nil)
        for source in [AnalyticsSignal.SendSource.quickReply, .composer] {
            let sendID = try harness.environment.engine.send(message, undoWindow: 600)
            let panel = UndoSendPanel.show(client: harness.environment.engine, accounts: harness.controller.accounts, sendID: sendID,
                                           draft: draft, undoWindow: 600, source: source)
            panel.undo()
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
        }
        XCTAssertEqual(recorder.sent.filter { $0.name == "Compose.sendUndone" }.map { $0.parameters["source"] }, ["quickReply", "composer"])
        XCTAssertFalse(recorder.sent.contains { $0.name == "Compose.started" }, "an undone send reopened is no composer started")
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
        XCTAssertEqual(try queuedAppIDs(file), ["ANOTHER-APP"], "another app's signals are its own")
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

    private func queuedAppIDs(_ file: URL) throws -> [String] {
        let queued = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        return queued.compactMap { $0["appID"] as? String }
    }

    private static let setup = AnalyticsSetup(appID: "OURS", baseURL: nil, testMode: true, transmitInterval: 60)

    /// The SDK reads only Paper's signals from the shared queue file; other apps' are put back after it has read
    /// it, and what other apps have there as the app quits goes back after the SDK's own write replaced the file.
    func testTheSDKNeverTakesAnotherAppsQueuedSignals() throws {
        let caches = try throwawayDirectory()
        let file = TelemetryDeckTransport.queueFile(in: caches)
        try JSONSerialization.data(withJSONObject: [["appID": "ANOTHER-APP"], ["appID": "OURS"], ["appID": "THIRD"]]).write(to: file)
        let sdk = FakeTelemetryDeck(queueFile: file)
        let transport = TelemetryDeckTransport(sdk: sdk, caches: caches, removeDomain: { _ in }, sessionStartDelay: 0)
        transport.start(Self.setup)
        XCTAssertEqual(sdk.read, ["OURS"], "the SDK read Paper's own")
        XCTAssertEqual(try queuedAppIDs(file), ["ANOTHER-APP", "THIRD"], "the others are back at once")
        transport.send("Undo.used", parameters: [:], floatValue: nil)
        // Meanwhile another app took its own, and a fourth quit with one of its own.
        try JSONSerialization.data(withJSONObject: [["appID": "THIRD"], ["appID": "FOURTH"]]).write(to: file)
        sdk.queued.append("OURS")
        transport.appBeginsToQuit()
        sdk.writeQueue()
        transport.appWillTerminate()
        XCTAssertEqual(try queuedAppIDs(file), ["OURS", "OURS", "THIRD", "FOURTH"], "what the others had as the app quit, beside its own")
        XCTAssertEqual(sdk.calls, ["initialize OURS", "signal Undo.used"])
    }

    /// A stop drops the SDK and deletes its leftovers at once, and its defaults once more after any write it began; the
    /// transport never starts it again.
    func testAStopDropsTheSDKAndDeletesWhatItLeft() throws {
        let caches = try throwawayDirectory()
        let file = TelemetryDeckTransport.queueFile(in: caches)
        let sdk = FakeTelemetryDeck(queueFile: file)
        var removed: [String] = []
        let transport = TelemetryDeckTransport(sdk: sdk, caches: caches, removeDomain: { removed.append($0) }, sessionStartDelay: 0)
        transport.start(Self.setup)
        // As another app's quit and an earlier stop's leave the shared file.
        try JSONSerialization.data(withJSONObject: [["appID": "ANOTHER-APP"], ["appID": "OURS"]]).write(to: file)
        transport.stop()
        XCTAssertEqual(sdk.calls, ["initialize OURS", "disable", "terminate"])
        XCTAssertEqual(try queuedAppIDs(file), ["ANOTHER-APP"], "Paper's own go, another app's stay")
        let suite = TelemetryDeckTransport.statsSuiteName(for: "OURS")
        XCTAssertEqual(removed, [suite])
        ListTestSupport.spin(for: TelemetryDeckTransport.secondSweepDelay + 0.2)
        XCTAssertEqual(removed, [suite, suite], "once more, after a write the SDK began before the stop")
        transport.send("Undo.used", parameters: [:], floatValue: nil)
        transport.start(Self.setup)
        transport.appWillTerminate()
        XCTAssertEqual(sdk.calls, ["initialize OURS", "disable", "terminate"], "nothing sent, never started again")
    }

    /// A stop before the SDK's first session turns it off at once and drops it once the session has started, or as the
    /// app quits, after the SDK has written its queue.
    func testAStopBeforeTheSDKsSessionWaitsForIt() throws {
        let caches = try throwawayDirectory()
        let file = TelemetryDeckTransport.queueFile(in: caches)
        for quits in [false, true] {
            let sdk = FakeTelemetryDeck(queueFile: file)
            let transport = TelemetryDeckTransport(sdk: sdk, caches: caches, removeDomain: { _ in }, sessionStartDelay: 0.3)
            transport.start(Self.setup)
            transport.stop()
            transport.send("Undo.used", parameters: [:], floatValue: nil)
            XCTAssertEqual(sdk.calls, ["initialize OURS", "disable"], "off at once, the shared manager kept for the session")
            XCTAssertTrue(transport.isStopping)
            if quits {
                try JSONSerialization.data(withJSONObject: [["appID": "ANOTHER-APP"]]).write(to: file)
                sdk.queued.append("OURS")
                transport.appBeginsToQuit()
                sdk.writeQueue()
                transport.appWillTerminate()
                XCTAssertEqual(try queuedAppIDs(file), ["ANOTHER-APP"], "what the SDK wrote as the app quit is deleted, another app's kept")
            } else {
                ListTestSupport.spin(for: 0.4)
            }
            XCTAssertEqual(sdk.calls, ["initialize OURS", "disable", "terminate"], quits ? "as the app quits" : "once the session started")
            XCTAssertFalse(transport.isStopping)
        }
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

    /// The caption says what this build sends, literally, and what never goes, in one line, as the crash reports caption
    /// did: a build with crash reports alone never speaks of features, nor one with analytics alone of crashes.
    func testTheCaptionSaysWhatThisBuildSendsInOneLine() {
        func height(_ text: String) -> CGFloat {
            // As General's grid lays it out: across both columns, inset to the field column, at most 360 pt wide.
            let view = NSHostingView(rootView: QuireThemeRoot(Grid { QuireSettingsCaption(text) }.frame(width: Quire.Layout.Settings.width)))
            view.layoutSubtreeIfNeeded()
            return view.fittingSize.height
        }
        typealias R = ReportServices
        XCTAssertEqual(R(crashReports: true, analytics: true).caption, "Crashes, hangs and features used. Never your mail or addresses.")
        XCTAssertEqual(R(crashReports: true, analytics: false).caption, "Crashes and hangs. Never your mail or addresses.")
        XCTAssertEqual(R(crashReports: false, analytics: true).caption, "Features used. Never your mail or addresses.")
        XCTAssertEqual(R(crashReports: false, analytics: false).caption, "Not set up in this build.")
        let oneLine = height(R.unavailableCaption)
        for caption in [R.bothCaption, R.crashReportsCaption, R.analyticsCaption] {
            XCTAssertTrue(caption.hasSuffix("Never your mail or addresses."))
            XCTAssertEqual(height(caption), oneLine, accuracy: 0.5, caption)
        }
        XCTAssertGreaterThan(height("Crashes, hangs and which features you use. Never your mail or addresses."), oneLine + 1,
                             "a longer caption would take two lines")
    }

    /// The welcome screen's privacy line is literal in every build: it promises nothing about analytics.
    func testTheWelcomeScreenPromisesOnlyWhatHolds() {
        XCTAssertEqual(WelcomeView.privacyNote, "Your mail is stored on this Mac and travels only between this Mac and Google or Microsoft.")
        XCTAssertFalse(WelcomeView.privacyNote.lowercased().contains("analytics"))
    }
}

/// Stands in for TelemetryDeck: what was started, sent, stopped and cleaned up after, in order.
@MainActor
final class RecordingAnalyticsTransport: AnalyticsTransport {
    struct Sent: Equatable {
        var name: String
        var parameters: [String: String]
        var floatValue: Double?
    }

    private(set) var started: [AnalyticsSetup] = []
    private(set) var sent: [Sent] = []
    private(set) var stops = 0
    private(set) var deleted: [String] = []

    nonisolated init() {}

    func start(_ setup: AnalyticsSetup) { started.append(setup) }

    func send(_ name: String, parameters: [String: String], floatValue: Double?) {
        sent.append(Sent(name: name, parameters: parameters, floatValue: floatValue))
    }

    func stop() { stops += 1 }

    func deleteLeftovers(of appID: String) { deleted.append(appID) }
}

/// Stands in for TelemetryDeck's SDK under `TelemetryDeckTransport`: its calls, and its queue file as the SDK treats it
/// (read whole and deleted as it starts, written whole as the app quits). Entries are only app IDs here.
@MainActor
final class FakeTelemetryDeck: TelemetryDeckSDK {
    private let queueFile: URL
    private(set) var calls: [String] = []
    /// What `initialize` read from the queue file.
    private(set) var read: [String] = []
    /// What it holds in memory, written by `writeQueue`.
    var queued: [String] = []

    init(queueFile: URL) {
        self.queueFile = queueFile
    }

    func initialize(_ setup: AnalyticsSetup) {
        calls.append("initialize \(setup.appID)")
        if let data = try? Data(contentsOf: queueFile),
           let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            read = entries.compactMap { $0["appID"] as? String }
        }
        try? FileManager.default.removeItem(at: queueFile)
        queued = read
    }

    func signal(_ name: String, parameters: [String: String], floatValue: Double?) { calls.append("signal \(name)") }

    func disable() { calls.append("disable") }

    func terminate() { calls.append("terminate") }

    /// The SDK's own write as the app quits: everything it holds, over whatever the file held.
    func writeQueue() {
        let entries = queued.map { ["appID": $0] }
        if let data = try? JSONSerialization.data(withJSONObject: entries) { try? data.write(to: queueFile) }
    }
}
