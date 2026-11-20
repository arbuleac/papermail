import AppKit
import SSCore
@testable import SSDesign
import SwiftUI
import XCTest
@testable import SuperSparrowApp

/// Settings › AI (spec §5.40, §5.55): the fifth tab, its rows per provider within its height cap, the key saved to and
/// removed from the key store (an in-memory one: never the Keychain), the model and the CLI chosen, the permission and
/// its Forget, and the choices kept in AppSettings. The demo writer answers every health check.
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
        let suite = "SuperSparrowAppTests.AI.\(UUID().uuidString)"
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func environment() throws -> AppEnvironment {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AISettingsTests-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try AppEnvironment.makeScratch(in: directory)
    }

    private func model(_ settings: AppSettings, _ environment: AppEnvironment) -> AISettingsModel {
        environment.helpMeWrite.settings = settings
        let model = AISettingsModel(settings: settings, center: environment.helpMeWrite)
        model.locateExecutable = { kind, chosen in chosen ?? (kind == .claudeCode ? "/opt/homebrew/bin/claude" : nil) }
        return model
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
        XCTAssertEqual(tabs.tabViewItems.last?.label, "AI", "appended, so no tab a user knows moves")
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
        model.commitKey()
        XCTAssertFalse(try keys.hasKey(for: .claudeAPI), "an empty field changes nothing")

        model.keyText = "  sk-ant-test-1234  "
        model.commitKey()
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

        XCTAssertEqual(AISettingsModel.locateLikeTheProviders(.claudeCode, chosen: tool.path), tool.path, "the chosen one wins")
        XCTAssertNotEqual(AISettingsModel.locateLikeTheProviders(.claudeCode, chosen: notATool.path), notATool.path,
                          "a chosen file that can't run is passed over, as the provider passes it over")
        XCTAssertNil(AISettingsModel.locateLikeTheProviders(.claudeAPI, chosen: tool.path), "an API provider has no CLI")
    }

    func testTheCaptionSaysWhereMailGoesAndForgetAsksAgain() throws {
        let settings = AppSettings(defaults: try throwawayDefaults())
        let environment = try environment()
        let model = model(settings, environment)
        XCTAssertNil(model.caption)
        model.setProvider(.codex)
        XCTAssertEqual(model.caption, "When you use Help Me Write, the conversation you\u{2019}re replying to goes to OpenAI. Nothing is sent otherwise.")
        XCTAssertFalse(model.hasConsent)
        settings.setAIConsent(true, for: .codex, demo: false)
        model.refresh()
        XCTAssertTrue(model.hasConsent)
        model.forgetConsent()
        XCTAssertFalse(settings.hasAIConsent(for: .codex, demo: false), "the sheet asks again next time")
        XCTAssertFalse(model.hasConsent)
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
