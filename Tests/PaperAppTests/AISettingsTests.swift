import AppKit
import PaperCore
@testable import PaperDesign
import SwiftUI
import XCTest
@testable import PaperApp

/// Settings › AI (spec §5.40, §5.56): the fifth tab, its rows per provider within its height cap, the privacy sheet as a
/// provider is chosen (Turn On keeps it, Cancel puts the popup back, Off withdraws), a provider never turned on, one
/// turned on before the sheet named new messages and forwards (on for replies only until its Turn On…), the key saved to
/// and removed from the key store (an in-memory one: never the Keychain), the model and the CLI chosen, and the choices
/// kept in AppSettings. The demo writer answers every health check.
@MainActor
final class AISettingsTests: XCTestCase {
    /// The tab's height cap: well under Accounts' 760 pt, so it never scrolls whatever the provider shows.
    static let heightCap: CGFloat = 420

    private var suites: [String] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        }
        super.tearDown()
    }

    private func throwawayDefaults() throws -> UserDefaults {
        let suite = "PaperAppTests.AI.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func environment() throws -> AppEnvironment {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AISettingsTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try AppEnvironment.makeScratch(in: directory)
    }

    /// The tab's model; the privacy sheet is answered `choice` (1 Turn On, 0 Cancel), each sheet recorded in `sheets`.
    private func model(_ settings: AppSettings, _ environment: AppEnvironment, choice: Int = 1) -> AISettingsModel {
        environment.helpMeWrite.settings = settings
        let model = AISettingsModel(settings: settings, center: environment.helpMeWrite)
        model.locateExecutable = { kind, chosen in chosen ?? (kind == .claudeCode ? "/opt/homebrew/bin/claude" : nil) }
        environment.helpMeWrite.presentAlert = { [weak self] alert, _, done in
            self?.sheets.append(alert)
            done(self?.answer ?? choice)
        }
        answer = choice
        return model
    }

    private var sheets: [AppAlert] = []
    private var answer = 1

    /// The privacy sheet's body before a CLI's own sentence, word for word (§5.33).
    private static func sheetBody(company: String) -> String {
        "When you press Write, what the draft is written from goes to \(company): for a reply, the conversation you\u{2019}re "
            + "replying to (newest messages first, older ones shortened); for a new message, its subject and the first names of "
            + "the people in To; for a forward, the same and the message you\u{2019}re forwarding. Your notes go with each, and "
            + "your first name when Paper knows it. Email addresses from your mail, your recipients\u{2019} addresses, "
            + "attachments and any other mail are never sent. Nothing is sent until you press Write."
    }

    /// Defaults as a version before 1.21 left them: `kind` chosen and turned on past the sheet that asked about replies,
    /// which wrote `aiConsent` and nothing else. No code writes that key alone any more, so it is put there by hand.
    private func defaultsTurnedOnForRepliesOnly(_ kind: AIProviderKind = .claudeAPI) throws -> UserDefaults {
        let defaults = try throwawayDefaults()
        defaults.set(kind.rawValue, forKey: "aiProvider")
        defaults.set([kind.rawValue], forKey: "aiConsent")
        return defaults
    }

    /// Runs a write of `writing` through `center`'s writer to its end: how it stopped, or the error it ended with.
    private func ending(of writing: WriteKind, _ center: HelpMeWrite, _ configuration: AIProviderConfiguration) -> Result<AIStop, AIError>? {
        let request = AIWriteRequest(kind: writing, instructions: "Write it.", transcript: "", task: "Say yes")
        let field = AIFieldID(name: "settings")
        let stream = center.writer.write(request, using: configuration, in: field, action: AIUserAction(userPressed: .write))
        var ending: Result<AIStop, AIError>?
        var isOver = false
        Task { @MainActor in
            do {
                for try await event in stream {
                    if case .finished(let stop) = event { ending = .success(stop) }
                }
            } catch {
                ending = .failure(AIError.from(error))
            }
            isOver = true
        }
        // The stream ends a turn before the writer lets go of the field: the next write here waits for both.
        XCTAssertTrue(ListTestSupport.spin(until: { isOver && !center.writer.isWriting(in: field) }, timeout: 5),
                      "\(writing): the write ends")
        return ending
    }

    // MARK: The tab

    func testTheFifthTabIsAIAndNeverScrolls() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        let environment = try environment()
        let controller = SettingsWindowController(environment: environment, settings: settings, mailtoHandler: FakeMailtoHandler(),
                                                  loginItem: FakeLoginItem())
        defer { controller.tearDown() }
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        controller.show(tab: .ai)
        let tabs = try XCTUnwrap(window.contentViewController as? NSTabViewController)
        XCTAssertEqual(tabs.tabViewItems[4].label, "AI", "appended after Appearance, so no tab a user knows moves")
        XCTAssertEqual(tabs.selectedTabViewItemIndex, 4)
        XCTAssertNotNil(tabs.tabViewItems[4].image, "the tab's symbol draws")
        tabs.selectedTabViewItemIndex = 2
        XCTAssertEqual(controller.model.tab, .general)
        tabs.selectedTabViewItemIndex = 4
        XCTAssertEqual(controller.model.tab, .ai)
    }

    /// Every provider's rows fit the cap at 560 pt, with at most six controls and twelve at the very most (§5.40).
    func testEachProvidersRowsFitWithinTheCap() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        let environment = try environment()
        let model = model(settings, environment)
        let view = NSHostingView(rootView: QuireThemeRoot(AISettingsView(model: model)))
        let window = host(view)
        defer { close(window) }
        var heights: [String: CGFloat] = [:]
        for kind in [nil] + AIProviderKind.selectable.map(Optional.some) {
            model.showForSnapshot(provider: kind, status: .ready("Ready"), hasKey: true, hasConsent: true, cliPath: "/opt/homebrew/bin/codex")
            fit(view)
            let height = view.fittingSize.height
            heights[AISettingsView.title(for: kind)] = height
            XCTAssertLessThanOrEqual(height, Self.heightCap, "\(AISettingsView.title(for: kind)) never scrolls: \(height) pt")
            XCTAssertEqual(view.fittingSize.width, Quire.Layout.Settings.width, accuracy: 0.5, "captions wrap rather than widen")
            let controls = focusables(in: view).count
            XCTAssertLessThanOrEqual(controls, 7, "\(AISettingsView.title(for: kind)): \(controls) controls")
        }
        XCTAssertLessThan(heights["Off"] ?? 0, heights["Claude (API key)"] ?? 0, "Off shows only the popup and its caption")
    }

    // MARK: The rows

    func testTheKeyIsSavedWhenCommittedAndRemovedWithoutBeingRead() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        let environment = try environment()
        let keys = try XCTUnwrap(environment.helpMeWrite.keys as? InMemoryAIKeyStore)
        let model = model(settings, environment)
        model.setProvider(.claudeAPI)
        XCTAssertEqual(settings.aiProvider, .claudeAPI)
        XCTAssertFalse(model.hasKey)
        XCTAssertEqual(model.keyPrompt, AISettingsModel.keyPrompt)

        model.keyText = ""
        model.commitKey(checking: true)
        XCTAssertFalse(try keys.hasKey(for: .claudeAPI), "an empty field changes nothing")

        model.keyText = "  sk-ant-test-1234  "
        model.commitKey(checking: true)
        XCTAssertTrue(try keys.hasKey(for: .claudeAPI))
        XCTAssertEqual(try keys.key(for: .claudeAPI), "sk-ant-test-1234", "trimmed")
        XCTAssertEqual(model.keyText, "", "the field never holds the stored key")
        XCTAssertEqual(model.keyPrompt, AISettingsModel.keySavedPrompt)
        let readsBefore = keys.reads(of: .claudeAPI)
        model.refresh()
        XCTAssertEqual(keys.reads(of: .claudeAPI), readsBefore, "opening the tab reads only whether there is a key")
        XCTAssertTrue(model.hasKey)

        model.removeKey()
        XCTAssertFalse(try keys.hasKey(for: .claudeAPI))
        XCTAssertFalse(model.hasKey)
    }

    func testTheStatusLineFollowsTheProvidersHealth() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        let environment = try environment()
        let script = try XCTUnwrap(environment.helpMeWrite.demoScript)
        script.health = .needsSetup(reason: "Add your API key")
        let model = model(settings, environment)
        model.setProvider(.openAIAPI)
        XCTAssertTrue(ListTestSupport.spin(until: { model.status == .needsSetup("Add your API key") }, timeout: 3))
        script.health = .ready(detail: "Ready · GPT-6.1 Terra")
        model.check()
        XCTAssertTrue(ListTestSupport.spin(until: { model.status == .ready("Ready · GPT-6.1 Terra") }, timeout: 3))
        model.setProvider(nil)
        XCTAssertEqual(model.status, .none, "Off checks nothing")
        XCTAssertNil(settings.aiProvider)
    }

    func testTheModelAndTheCommandAreKeptPerProvider() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        let environment = try environment()
        let model = model(settings, environment)
        model.setProvider(.claudeCode)
        XCTAssertNil(model.model, "the CLI's own default")
        XCTAssertEqual(model.cliPath, "/opt/homebrew/bin/claude", "the one found in the standard folders")
        model.setModel("haiku")
        XCTAssertEqual(settings.aiConfiguration, AIProviderConfiguration(kind: .claudeCode, model: "haiku"))

        model.chooseExecutable = { _, done in done(URL(fileURLWithPath: "/usr/local/opt/claude/bin/claude")) }
        model.chooseCLI()
        XCTAssertEqual(settings.aiCLIPaths[.claudeCode], "/usr/local/opt/claude/bin/claude")
        XCTAssertEqual(model.cliPath, "/usr/local/opt/claude/bin/claude", "the chosen one wins")

        model.setProvider(.claudeAPI)
        XCTAssertEqual(model.model, "claude-opus-5-5", "the API's default")
        model.setModel("claude-haiku-5-5")
        model.setProvider(.claudeCode)
        XCTAssertEqual(model.model, "haiku", "each provider keeps its own model")
        XCTAssertEqual(settings.aiModels[.claudeAPI], "claude-haiku-5-5")
    }

    /// The row's default finder is the CLI providers' own (`CLIProcessRunner.locate`): it shows the CLI Help Me Write
    /// runs, so a chosen path that is no longer an executable file is not shown as if it were used. Runs nothing.
    func testTheCommandRowFindsWhatTheProviderRuns() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AISettingsTests-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let tool = folder.appendingPathComponent("claude")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let notATool = folder.appendingPathComponent("notes.txt")
        try Data("not a tool".utf8).write(to: notATool)

        let empty = folder.appendingPathComponent("empty-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let nowhere = [empty]
        let here = [empty, folder]
        XCTAssertEqual(AISettingsModel.locateLikeTheProviders(.claudeCode, chosen: tool.path, searchFolders: nowhere), tool.path,
                       "the chosen one wins")
        XCTAssertNil(AISettingsModel.locateLikeTheProviders(.claudeCode, chosen: notATool.path, searchFolders: nowhere),
                     "a chosen file that can't run is passed over, as the provider passes it over")
        XCTAssertEqual(AISettingsModel.locateLikeTheProviders(.claudeCode, chosen: notATool.path, searchFolders: here), tool.path,
                       "and the folders are searched in order")
        XCTAssertNil(AISettingsModel.locateLikeTheProviders(.claudeCode, chosen: nil, searchFolders: nowhere))
        XCTAssertNil(AISettingsModel.locateLikeTheProviders(.claudeAPI, chosen: tool.path, searchFolders: here), "an API provider has no CLI")
    }

    func testChoosingAProviderShowsItsPrivacySheetAndTurnOnKeepsIt() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        let environment = try environment()
        let model = model(settings, environment)
        XCTAssertNil(model.caption)
        model.setProvider(.claudeAPI)
        let sheet = try XCTUnwrap(sheets.last, "the notice shows as the provider is chosen")
        XCTAssertEqual(sheet.title, "Use Claude to help you write?")
        XCTAssertEqual(sheet.buttons.map(\.title), ["Cancel", "Turn On"], "Cancel is the default: ↩ turns nothing on")
        XCTAssertEqual(sheet.escapeIndex, 0)
        XCTAssertEqual(sheet.body, Self.sheetBody(company: "Anthropic"), "what goes for each kind of write, what never does, and when")
        XCTAssertEqual(settings.aiProvider, .claudeAPI)
        XCTAssertTrue(settings.hasAIConsent(for: .claudeAPI, demo: false), "Turn On gives the permission")
        for writing in WriteKind.allCases {
            XCTAssertTrue(settings.hasAIConsent(for: .claudeAPI, writing: writing, demo: false), "for everything the sheet names: \(writing)")
        }
        XCTAssertTrue(model.hasConsent)
        XCTAssertFalse(model.needsTurnOn)
        XCTAssertFalse(model.offersTurnOn, "nothing is left to ask")
        XCTAssertEqual(model.caption, "Only when you press Write, the message you\u{2019}re writing and the mail it answers or forwards "
            + "go to Anthropic. Choose Off to stop.")

        // Another provider: its own sheet; Turn On moves the permission to it.
        model.setProvider(.codex)
        XCTAssertEqual(sheets.last?.title, "Use Codex to help you write?")
        XCTAssertTrue(sheets.last?.body.hasPrefix("When you press Write, what the draft is written from goes to OpenAI: ") ?? false)
        XCTAssertTrue(sheets.last?.body.hasSuffix("Through Codex, under your OpenAI account\u{2019}s privacy settings.") ?? false)
        XCTAssertEqual(settings.aiProvider, .codex)
        XCTAssertTrue(settings.hasAIConsent(for: .codex, demo: false))
        XCTAssertFalse(settings.hasAIConsent(for: .claudeAPI, demo: false), "the one it replaced is withdrawn")

        // Off withdraws, with no sheet.
        let shown = sheets.count
        model.setProvider(nil)
        XCTAssertEqual(sheets.count, shown)
        XCTAssertNil(settings.aiProvider)
        XCTAssertFalse(settings.hasAIConsent(for: .codex, demo: false), "Turn Off is how permission is withdrawn")
    }

    func testCancelPutsThePopupBack() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        let environment = try environment()
        let model = model(settings, environment)
        model.setProvider(.claudeCode)
        answer = 0
        model.setProvider(.openAIAPI)
        XCTAssertEqual(sheets.last?.title, "Use OpenAI to help you write?")
        XCTAssertEqual(model.provider, .claudeCode, "Cancel puts the popup back to what it was")
        XCTAssertEqual(settings.aiProvider, .claudeCode)
        XCTAssertTrue(settings.hasAIConsent(for: .claudeCode, demo: false), "and leaves its permission")
        XCTAssertFalse(settings.hasAIConsent(for: .openAIAPI, demo: false))
        XCTAssertTrue(sheets.last?.body.hasSuffix("Through Claude Code, under your Claude plan\u{2019}s privacy settings.") == false)
        XCTAssertTrue(AppAlert.helpMeWriteTurnOn(.claudeCode).body.hasSuffix("Through Claude Code, under your Claude plan\u{2019}s privacy settings."))
    }

    /// A provider chosen before 1.12 and never confirmed: Settings says so and offers Turn On…, which shows its sheet.
    func testAProviderNeverTurnedOnSaysSoAndOffersTheSheet() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        settings.aiProvider = .claudeAPI
        let environment = try environment()
        let model = model(settings, environment, choice: 0)
        model.refresh()
        XCTAssertTrue(model.needsTurnOn)
        XCTAssertEqual(model.status, .needsSetup(AISettingsModel.notTurnedOnWords))
        XCTAssertTrue(sheets.isEmpty, "opening the tab shows no sheet")
        model.turnOnChosenProvider()
        XCTAssertEqual(sheets.count, 1)
        XCTAssertTrue(model.needsTurnOn, "Cancel leaves it as it was")
        answer = 1
        model.turnOnChosenProvider()
        XCTAssertFalse(model.needsTurnOn)
        XCTAssertTrue(settings.hasAIConsent(for: .claudeAPI, demo: false))
        XCTAssertNotEqual(model.status, .needsSetup(AISettingsModel.notTurnedOnWords))
    }

    // MARK: Turned on before the sheet named new messages and forwards

    /// Permission is by what is written (§5.56). A Turn On from before the sheet named new messages and forwards keeps
    /// replies ready and makes nothing else ready; nothing is carried over to the new key. Settings › AI says “On for
    /// replies only” with Turn On…, which shows the sheet as it reads now: Cancel leaves replies on, Turn On gives the rest.
    func testAnEarlierTurnOnStandsForRepliesOnlyUntilTheNewSheetsTurnOn() throws {
        let defaults = try defaultsTurnedOnForRepliesOnly()
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(settings.hasAIConsent(for: .claudeAPI, demo: false))
        XCTAssertTrue(settings.hasAIConsent(for: .claudeAPI, writing: .reply, demo: false), "a reply needs what it always did")
        XCTAssertFalse(settings.hasAIConsent(for: .claudeAPI, writing: .newMessage, demo: false))
        XCTAssertFalse(settings.hasAIConsent(for: .claudeAPI, writing: .forward, demo: false))
        XCTAssertNil(defaults.object(forKey: "aiConsent.2"), "nothing is carried over: absence means not given")

        let environment = try environment()
        let center = environment.helpMeWrite
        let model = model(settings, environment, choice: 0)
        model.refresh()
        XCTAssertEqual(model.status, .needsSetup("On for replies only"))
        XCTAssertTrue(model.isOnForRepliesOnly)
        XCTAssertTrue(model.offersTurnOn, "Turn On… beside the words, as beside “Not turned on yet”")
        XCTAssertFalse(model.needsTurnOn, "it was turned on")
        XCTAssertTrue(model.hasConsent)
        XCTAssertTrue(sheets.isEmpty, "opening the tab shows no sheet")
        XCTAssertTrue(center.availability(for: .reply).isReady, "replies are written as they were")
        for writing in [WriteKind.newMessage, .forward] {
            XCTAssertEqual(center.availability(for: writing), .unavailable(reason: "Help Me Write is on for replies only"), "\(writing)")
        }

        // Cancel leaves replies on, and the rest as it was.
        model.turnOnChosenProvider()
        XCTAssertEqual(sheets.count, 1)
        XCTAssertEqual(sheets.last?.title, "Use Claude to help you write?")
        XCTAssertEqual(sheets.last?.body, Self.sheetBody(company: "Anthropic"), "the sheet as it reads now")
        XCTAssertEqual(model.status, .needsSetup("On for replies only"))
        XCTAssertEqual(model.provider, .claudeAPI)
        XCTAssertEqual(settings.aiProvider, .claudeAPI)
        XCTAssertTrue(settings.hasAIConsent(for: .claudeAPI, writing: .reply, demo: false), "Cancel leaves replies on")
        XCTAssertFalse(settings.hasAIConsent(for: .claudeAPI, writing: .newMessage, demo: false))
        XCTAssertNil(defaults.object(forKey: "aiConsent.2"))
        XCTAssertTrue(center.availability(for: .reply).isReady)

        // Turn On: everything the sheet names, kept under both keys.
        answer = 1
        model.turnOnChosenProvider()
        XCTAssertEqual(sheets.count, 2)
        XCTAssertFalse(model.isOnForRepliesOnly)
        XCTAssertFalse(model.offersTurnOn)
        XCTAssertTrue(model.status.isReady, "“Ready · …”, as before")
        for writing in WriteKind.allCases {
            XCTAssertTrue(settings.hasAIConsent(for: .claudeAPI, writing: writing, demo: false), "\(writing)")
            XCTAssertTrue(center.availability(for: writing).isReady, "\(writing)")
        }
        XCTAssertEqual(defaults.stringArray(forKey: "aiConsent"), ["claudeAPI"])
        XCTAssertEqual(defaults.stringArray(forKey: "aiConsent.2"), ["claudeAPI"])
        model.turnOnChosenProvider()
        XCTAssertEqual(sheets.count, 2, "there is nothing left to ask")
        let relaunched = AppSettings(defaults: defaults)
        XCTAssertTrue(relaunched.hasAIConsent(for: .claudeAPI, writing: .forward, demo: false), "kept across launches")
    }

    /// “On for replies only” stands where “Ready · …” would, a Check's good answer included. A provider that cannot write
    /// says why first, as it always did (replies wait on that too), and Turn On… waits until it can.
    func testOnForRepliesOnlyStandsWhereReadyWouldAndNeverHidesWhatKeepsRepliesFromBeingWritten() throws {
        let settings = AppSettings(defaults: try defaultsTurnedOnForRepliesOnly())
        let environment = try environment()
        let script = try XCTUnwrap(environment.helpMeWrite.demoScript)
        let model = model(settings, environment)
        model.refresh()
        XCTAssertEqual(model.status, .needsSetup("On for replies only"))
        model.check()
        XCTAssertEqual(model.status, .checking)
        XCTAssertTrue(model.offersTurnOn, "Turn On… stays beside a check")
        XCTAssertTrue(ListTestSupport.spin(until: { model.status != .checking }, timeout: 3))
        XCTAssertEqual(model.status, .needsSetup("On for replies only"), "a check that finds it ready changes nothing")

        script.health = .needsSetup(reason: "Add your API key")
        model.check()
        XCTAssertTrue(ListTestSupport.spin(until: { model.status != .checking }, timeout: 3))
        XCTAssertEqual(model.status, .needsSetup("Add your API key"), "what keeps replies from being written is said first")
        XCTAssertTrue(model.isOnForRepliesOnly)
        XCTAssertFalse(model.offersTurnOn, "and Turn On… waits for it")
        model.turnOnChosenProvider()
        XCTAssertTrue(sheets.isEmpty)
        model.refresh()
        XCTAssertEqual(model.status, .needsSetup("Add your API key"), "as the tab opens again too")

        script.health = .ready(detail: "Ready \u{00b7} Claude Opus 5.5")
        model.check()
        XCTAssertTrue(ListTestSupport.spin(until: { model.status != .checking }, timeout: 3))
        XCTAssertEqual(model.status, .needsSetup("On for replies only"))
        XCTAssertTrue(model.offersTurnOn)
        model.turnOnChosenProvider()
        XCTAssertEqual(sheets.count, 1)
        XCTAssertEqual(model.status, .ready("Ready \u{00b7} Claude Opus 5.5"), "after Turn On, “Ready · …” as before")

        // A provider never turned on says only that, whatever its state: nothing can be written.
        let never = AppSettings(defaults: try throwawayDefaults())
        never.aiProvider = .openAIAPI
        script.health = .needsSetup(reason: "Add your API key")
        let neverModel = self.model(never, environment, choice: 0)
        neverModel.refresh()
        XCTAssertEqual(neverModel.status, .needsSetup("Not turned on yet"))
        XCTAssertTrue(neverModel.offersTurnOn)
    }

    /// Off, or another provider turned on in its place, takes back everything a Turn On gave: both keys, so nothing of a
    /// withdrawn provider is left standing for a new message or a forward.
    func testOffAndAReplacementWithdrawBothKeys() throws {
        let defaults = try throwawayDefaults()
        let settings = AppSettings(defaults: defaults)
        let environment = try environment()
        let model = model(settings, environment)
        model.setProvider(.claudeAPI)
        XCTAssertEqual(defaults.stringArray(forKey: "aiConsent"), ["claudeAPI"])
        XCTAssertEqual(defaults.stringArray(forKey: "aiConsent.2"), ["claudeAPI"], "Turn On writes both")

        model.setProvider(.openAIAPI)
        XCTAssertEqual(defaults.stringArray(forKey: "aiConsent"), ["openAIAPI"])
        XCTAssertEqual(defaults.stringArray(forKey: "aiConsent.2"), ["openAIAPI"], "the one it replaced leaves both")
        for writing in WriteKind.allCases {
            XCTAssertFalse(settings.hasAIConsent(for: .claudeAPI, writing: writing, demo: false), "\(writing)")
            XCTAssertTrue(settings.hasAIConsent(for: .openAIAPI, writing: writing, demo: false), "\(writing)")
        }

        model.setProvider(nil)
        XCTAssertEqual(defaults.stringArray(forKey: "aiConsent"), [])
        XCTAssertEqual(defaults.stringArray(forKey: "aiConsent.2"), [], "Off clears both")
        for writing in WriteKind.allCases {
            XCTAssertFalse(settings.hasAIConsent(for: .openAIAPI, writing: writing, demo: false), "\(writing)")
            XCTAssertEqual(environment.helpMeWrite.availability(for: writing), .off, "\(writing)")
        }
        XCTAssertFalse(AppSettings(defaults: defaults).hasAIConsent(for: .openAIAPI, writing: .reply, demo: false), "and stays off")

        // One on for replies only: Off takes that too, and another provider chosen in its place is asked for everything.
        let earlier = try defaultsTurnedOnForRepliesOnly()
        let earlierSettings = AppSettings(defaults: earlier)
        let earlierModel = self.model(earlierSettings, try self.environment())
        earlierModel.refresh()
        earlierModel.setProvider(.claudeCode)
        XCTAssertEqual(earlier.stringArray(forKey: "aiConsent"), ["claudeCode"], "the earlier Turn On goes with its provider")
        XCTAssertEqual(earlier.stringArray(forKey: "aiConsent.2"), ["claudeCode"])
        XCTAssertFalse(earlierModel.offersTurnOn)
        earlierModel.setProvider(nil)
        XCTAssertFalse(earlierSettings.hasAIConsent(for: .claudeCode, demo: false))

        // The second key alone gives nothing: a new message or a forward needs both.
        let odd = try throwawayDefaults()
        odd.set(["codex"], forKey: "aiConsent.2")
        for writing in WriteKind.allCases {
            XCTAssertFalse(AppSettings(defaults: odd).hasAIConsent(for: .codex, writing: writing, demo: false), "\(writing)")
        }
    }

    /// The writer checks again, with the request's own kind: no path sends a new message or a forward on a Turn On
    /// given for replies, whatever asked for it. A reply goes as it always did.
    func testTheWriterRefusesMoreThanARepliesTurnOnAllows() throws {
        let settings = AppSettings(defaults: try defaultsTurnedOnForRepliesOnly())
        let environment = try environment()
        let center = environment.helpMeWrite
        center.settings = settings
        let script = try XCTUnwrap(center.demoScript)
        script.delay = .zero
        let configuration = try XCTUnwrap(center.configuration)
        XCTAssertEqual(configuration.kind, .claudeAPI)
        for writing in [WriteKind.newMessage, .forward] {
            XCTAssertEqual(ending(of: writing, center, configuration), .failure(.consentRequired), "\(writing)")
            XCTAssertEqual(center.consentReason(for: .claudeAPI, writing: writing), "Help Me Write is on for replies only")
            XCTAssertEqual(center.consentReason(for: .codex, writing: writing), "Turn it on in Settings \u{203a} AI",
                           "one never turned on says that instead")
        }
        XCTAssertTrue(script.requests.isEmpty, "nothing reached the provider")
        XCTAssertEqual(ending(of: .reply, center, configuration), .success(.done))
        XCTAssertEqual(script.requests.map(\.kind), [.reply])

        settings.setAIConsent(true, for: .claudeAPI, demo: false)
        XCTAssertEqual(ending(of: .newMessage, center, configuration), .success(.done), "after the new sheet's Turn On")
        XCTAssertEqual(ending(of: .forward, center, configuration), .success(.done))
        XCTAssertEqual(script.requests.map(\.kind), [.reply, .newMessage, .forward])
    }

    /// The demo sends nothing whatever it writes, so a Turn On given there before stands for all of it: it is not asked
    /// again, and it never stands for the user's real mail.
    func testTheDemoIsNotAskedAgain() throws {
        let defaults = try throwawayDefaults()
        defaults.set("claudeAPI", forKey: "aiProvider.demo")
        defaults.set(["claudeAPI"], forKey: "aiConsent.demo")
        let settings = AppSettings(defaults: defaults)
        let demo = HelpMeWrite.demo(isDemo: true)
        demo.settings = settings
        demo.presentAlert = { [weak self] alert, _, done in
            self?.sheets.append(alert)
            done(1)
        }
        let model = AISettingsModel(settings: settings, center: demo)
        model.locateExecutable = { _, _ in nil }
        model.refresh()
        XCTAssertEqual(model.provider, .claudeAPI)
        XCTAssertFalse(model.isOnForRepliesOnly)
        XCTAssertFalse(model.offersTurnOn)
        XCTAssertTrue(model.status.isReady)
        for writing in WriteKind.allCases {
            XCTAssertTrue(demo.availability(for: writing).isReady, "\(writing)")
            XCTAssertTrue(settings.hasAIConsent(for: .claudeAPI, writing: writing, demo: true), "\(writing)")
            XCTAssertFalse(settings.hasAIConsent(for: .claudeAPI, writing: writing, demo: false), "never for real mail: \(writing)")
        }
        model.turnOnChosenProvider()
        XCTAssertTrue(sheets.isEmpty, "no sheet, at the tab's opening or after")
    }

    /// A render of “On for replies only” runs in the demo, which never has that state: its caption reads as the app's
    /// does for a provider that sends. Every other state the demo is shown in keeps the demo's caption.
    func testARenderOfOnForRepliesOnlySaysWhatIsSent() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        let demo = HelpMeWrite.demo(isDemo: true)
        demo.settings = settings
        let model = AISettingsModel(settings: settings, center: demo)
        model.showForSnapshot(provider: .claudeAPI, status: .ready("Ready \u{00b7} Claude Opus 5.5"), hasKey: true)
        XCTAssertEqual(model.caption, AISettingsModel.demoCaption)
        model.showForSnapshot(provider: .claudeAPI, status: .needsSetup(AISettingsModel.repliesOnlyWords), hasKey: true, repliesOnly: true)
        XCTAssertEqual(model.caption, "Only when you press Write, the message you\u{2019}re writing and the mail it answers or forwards "
            + "go to Anthropic. Choose Off to stop.")
        model.showForSnapshot(provider: .claudeAPI, status: .needsSetup(AISettingsModel.notTurnedOnWords), hasKey: true, hasConsent: false)
        XCTAssertEqual(model.caption, AISettingsModel.demoCaption, "the next state is the demo's again")
    }

    /// “On for replies only” has the shape “Not turned on yet” has: its words with Turn On… beside them on one row, so the
    /// tab is laid out exactly as it is for a provider never turned on, within its cap and its width.
    func testOnForRepliesOnlyHasTheShapeOfNotTurnedOnYet() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        let environment = try environment()
        let model = model(settings, environment)
        let view = NSHostingView(rootView: QuireThemeRoot(AISettingsView(model: model)))
        let window = host(view)
        defer { close(window) }
        model.showForSnapshot(provider: .claudeAPI, status: .needsSetup(AISettingsModel.notTurnedOnWords), hasKey: true, hasConsent: false)
        fit(view)
        XCTAssertTrue(model.needsTurnOn)
        XCTAssertTrue(model.offersTurnOn)
        let neverTurnedOn = view.fittingSize

        model.showForSnapshot(provider: .claudeAPI, status: .needsSetup(AISettingsModel.repliesOnlyWords), hasKey: true, repliesOnly: true)
        fit(view)
        XCTAssertTrue(model.isOnForRepliesOnly)
        XCTAssertFalse(model.needsTurnOn, "it was turned on, for replies")
        XCTAssertTrue(model.offersTurnOn, "Turn On… shows beside the words")
        XCTAssertEqual(model.status.words, "On for replies only")
        XCTAssertEqual(view.fittingSize.height, neverTurnedOn.height, accuracy: 0.5, "the same rows")
        XCTAssertLessThanOrEqual(view.fittingSize.height, Self.heightCap)
        XCTAssertEqual(view.fittingSize.width, Quire.Layout.Settings.width, accuracy: 0.5, "the words and the button fit the column")

        model.showForSnapshot(provider: .claudeAPI, status: .ready("Ready \u{00b7} Claude Opus 5.5"), hasKey: true)
        XCTAssertFalse(model.offersTurnOn, "turned on for everything: nothing to ask")
        XCTAssertFalse(model.isOnForRepliesOnly)
    }

    /// The words Settings › AI says of what is sent, word for word (§5.40), none of them about replies alone.
    func testTheCaptionsSayWhatIsSentForEveryKindOfWrite() throws {
        XCTAssertEqual(AISettingsView.offCaption, "Off: Help Me Write sends nothing anywhere. Choose a provider to draft messages with \u{2318}J.")
        XCTAssertEqual(AISettingsModel.demoCaption, "In the demo, Help Me Write makes drafts up on this Mac. Nothing is sent.")
        XCTAssertEqual(AISettingsModel.repliesOnlyWords, "On for replies only")
        let settings = AppSettings(defaults: try throwawayDefaults())
        let model = model(settings, try environment())
        model.setProvider(.openAIAPI)
        XCTAssertEqual(model.caption, "Only when you press Write, the message you\u{2019}re writing and the mail it answers or forwards "
            + "go to OpenAI. Choose Off to stop.")
        for kind in AIProviderKind.selectable {
            let sheet = AppAlert.helpMeWriteTurnOn(kind)
            XCTAssertEqual(sheet.title, "Use \(kind.displayName) to help you write?")
            XCTAssertTrue(sheet.body.hasPrefix(Self.sheetBody(company: kind.destination.displayName)), "\(kind)")
            XCTAssertFalse(sheet.body.contains("to draft a reply"), "the sheet no longer asks about replies alone")
        }
        XCTAssertEqual(AppAlert.helpMeWriteTurnOn(.claudeAPI).body, Self.sheetBody(company: "Anthropic"))
        XCTAssertEqual(AppAlert.helpMeWriteTurnOn(.claudeCode).body,
                       Self.sheetBody(company: "Anthropic") + " Through Claude Code, under your Claude plan\u{2019}s privacy settings.")
        XCTAssertEqual(AppAlert.helpMeWriteTurnOn(.codex).body,
                       Self.sheetBody(company: "OpenAI") + " Through Codex, under your OpenAI account\u{2019}s privacy settings.")
    }

    func testTheDemosSheetSaysNothingIsSent() throws {
        let demo = AppAlert.helpMeWriteTurnOn(.claudeAPI, demo: true)
        XCTAssertEqual(demo.title, "Try Help Me Write?")
        XCTAssertEqual(demo.body, "In the demo, drafts are made up on this Mac. Nothing is sent.")
        XCTAssertEqual(demo.buttons.map(\.title), ["Cancel", "Turn On"])
        XCTAssertTrue(AppAlert.specimens.contains { $0.title == "Use Claude to help you write?" })
        XCTAssertTrue(AppAlert.specimens.contains { $0.title == "Try Help Me Write?" })
    }

    // MARK: AppSettings

    func testTheChoicesAreKeptAndTheDemosConsentIsApart() throws {
        let defaults = try throwawayDefaults()
        let settings = AppSettings(defaults: defaults)
        XCTAssertNil(settings.aiProvider, "off by default")
        XCTAssertNil(settings.aiConfiguration)
        settings.aiProvider = .openAIAPI
        settings.setAIModel("gpt-6.2-sol", for: .openAIAPI)
        settings.setAICLIPath("/opt/homebrew/bin/codex", for: .codex)
        settings.setAIConsent(true, for: .claudeCode, demo: true)

        let again = AppSettings(defaults: defaults)
        XCTAssertEqual(again.aiConfiguration, AIProviderConfiguration(kind: .openAIAPI, model: "gpt-6.2-sol"))
        XCTAssertEqual(again.aiCLIPaths[.codex], "/opt/homebrew/bin/codex")
        XCTAssertTrue(again.hasAIConsent(for: .claudeCode, demo: true))
        XCTAssertFalse(again.hasAIConsent(for: .claudeCode, demo: false), "an Allow in the demo never stands for real mail")

        // The demo's provider, model and CLI are its own: trying the demo never turns Help Me Write on for real mail.
        let freshDefaults = try throwawayDefaults()
        let fresh = AppSettings(defaults: freshDefaults)
        fresh.setAIProvider(.claudeCode, demo: true)
        fresh.setAIModel("haiku", for: .claudeCode, demo: true)
        fresh.setAICLIPath("/tmp/claude", for: .claudeCode, demo: true)
        XCTAssertNil(fresh.aiProvider, "the user's own mail stays Off")
        XCTAssertNil(fresh.aiConfiguration)
        XCTAssertNil(fresh.aiModels[.claudeCode])
        XCTAssertNil(fresh.aiCLIPaths[.claudeCode])
        XCTAssertEqual(fresh.aiConfiguration(demo: true),
                       AIProviderConfiguration(kind: .claudeCode, model: "haiku", cliPath: "/tmp/claude"))
        let freshAgain = AppSettings(defaults: freshDefaults)
        XCTAssertNil(freshAgain.aiConfiguration(demo: false))
        XCTAssertEqual(freshAgain.aiProvider(demo: true), .claudeCode, "kept across launches, apart")

        defaults.set("someLaterProvider", forKey: "aiProvider")
        XCTAssertNil(AppSettings(defaults: defaults).aiProvider, "a provider this version does not know is Off")
        again.aiProvider = .demo
        XCTAssertNil(defaults.string(forKey: "aiProvider"), "the demo writer is never stored")
    }

    // MARK: Support

    private func host(_ view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: view.fittingSize), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        fit(view)
        return window
    }

    private func fit(_ view: NSView) {
        ListTestSupport.spin(for: 0.05)
        view.window?.setContentSize(view.fittingSize)
        view.layoutSubtreeIfNeeded()
        ListTestSupport.spin(for: 0.05)
    }

    private func close(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentView = nil
        window.close()
    }

    private func focusables(in view: NSView) -> [NSView] {
        view.subviews.filter { String(describing: type(of: $0)).hasSuffix("KeyViewProxy") }
    }
}
