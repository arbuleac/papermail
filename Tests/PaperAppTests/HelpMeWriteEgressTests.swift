import AppKit
import PaperAI
import PaperCore
import XCTest
@testable import PaperApp

/// The hard rule (spec §3b): nothing reaches Anthropic or OpenAI, and none of the user's CLIs starts, unless the user acts.
/// The app runs here with the real providers (`AIProviderFactory`), their HTTP routed to a recording `URLProtocol` and
/// their CLI a fake `claude` that logs each launch, so every contact is seen three ways: the stub, the fake's log and
/// `AIEgress`. Launch, opening Settings › AI, choosing a provider (its sheet and Turn On), typing notes, the ghost, the
/// pill, opening the prompt line, the text's menu showing, switching conversations, opening a composer and quitting make
/// none; each allowed action exactly its own.
@MainActor
final class HelpMeWriteEgressTests: XCTestCase {
    private var folder: URL!
    private var contacts: [String] { EgressRecorder.shared.contacts }

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("HelpMeWriteEgress-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("bin"), withIntermediateDirectories: true)
        MainActor.assumeIsolated { ComposeDraftStore.shared.useDirectory(folder.appendingPathComponent("drafts")) }
        EgressRecorder.shared.reset()
        EgressStubProtocol.reset()
        AIEgress.observe { contact, action in EgressRecorder.shared.record("\(action.kind.rawValue): \(contact)") }
    }

    override func tearDown() {
        AIEgress.observe(nil)
        MainActor.assumeIsolated {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: The app with real providers, watched

    /// A fake `claude` in a folder of its own: it logs every launch's arguments, says it is 2.1.322 and signed in with
    /// claude.ai, and fails a write (exit 3) after reading the request, so nothing needs a model.
    private func installFakeClaude() throws -> URL {
        let log = folder.appendingPathComponent("launches.log")
        let script = """
        #!/bin/sh
        printf 'launch %s\n' "$1" >> '\(log.path)'
        printf '%s ' "$@" >> '\(log.path).argv'
        if [ "$1" = "--version" ]; then echo "2.1.322 (Claude Code)"; exit 0; fi
        for argument in "$@"; do
          if [ "$argument" = "auth" ]; then echo '{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty"}'; exit 0; fi
        done
        cat > /dev/null
        exit 3
        """
        let tool = folder.appendingPathComponent("bin/claude")
        try Data(script.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return log
    }

    /// Each launch's first argument, one line per launch.
    private func launches(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map { String($0.dropFirst("launch ".count)) }
    }

    /// Every argument of every launch, as one text.
    private func arguments(_ log: URL) -> String {
        (try? String(contentsOf: URL(fileURLWithPath: log.path + ".argv"), encoding: .utf8)) ?? ""
    }

    /// Help me write with the real factory: an in-memory key store, HTTP to `EgressStubProtocol`, CLIs from the fake's
    /// folder only.
    private func realCenter(keys: InMemoryAIKeyStore = InMemoryAIKeyStore()) -> HelpMeWrite {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EgressStubProtocol.self]
        let factory = AIProviderFactory(keys: keys, session: URLSession(configuration: configuration),
                                        runner: CLIProcessRunner(searchFolders: [folder.appendingPathComponent("bin")]))
        let runner = factory.runner
        return HelpMeWrite(keys: keys, isDemo: false, demoScript: nil, endProcesses: { await runner.endAll() }) {
            factory.provider(for: $0)
        }
    }

    private func settingsModel(_ harness: MainWindowHarness) -> AISettingsModel {
        let center = harness.environment.helpMeWrite
        center.presentAlert = { _, _, done in done(1) }
        let model = AISettingsModel(settings: harness.settings, center: center)
        model.locateExecutable = { [folder] kind, chosen in
            AISettingsModel.locateLikeTheProviders(kind, chosen: chosen, searchFolders: [folder!.appendingPathComponent("bin")])
        }
        return model
    }

    private func select(_ thread: String, _ harness: MainWindowHarness) throws {
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == thread }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentConversationID == id }
    }

    /// Settings, opened on its AI tab as the window shows it, finding CLIs in the fake's folder only.
    private func openSettings(_ harness: MainWindowHarness) -> SettingsWindowController {
        let settings = SettingsWindowController(environment: harness.environment, settings: harness.settings,
                                                mailtoHandler: FakeMailtoHandler(), loginItem: FakeLoginItem())
        settings.window?.setFrameAutosaveName("")
        settings.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        settings.ai.locateExecutable = { [folder] kind, chosen in
            AISettingsModel.locateLikeTheProviders(kind, chosen: chosen, searchFolders: [folder!.appendingPathComponent("bin")])
        }
        settings.show(tab: .ai)
        ListTestSupport.spin(for: 0.3)
        return settings
    }

    /// Settings › AI's API key field, the AppKit field the user types in.
    private func keyField(in settings: SettingsWindowController) -> NSSecureTextField? {
        var found: NSSecureTextField?
        XCTAssertTrue(ListTestSupport.spin(until: {
            found = Self.first(NSSecureTextField.self, in: settings.window?.contentView)
            return found != nil
        }, timeout: 3), "the key field shows")
        return found
    }

    private static func first<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for subview in view.subviews { if let match = first(type, in: subview) { return match } }
        return nil
    }

    /// Types `text` into the key field as the user would, the keyboard left there.
    private func type(_ text: String, into field: NSSecureTextField, in settings: SettingsWindowController) {
        XCTAssertTrue(settings.window?.makeFirstResponder(field) ?? false)
        let editor = field.currentEditor() as? NSTextView
        XCTAssertNotNil(editor, "the field edits")
        editor?.insertText(text, replacementRange: NSRange(location: 0, length: (editor?.string as NSString?)?.length ?? 0))
        ListTestSupport.spin(for: 0.1)
    }

    /// Quits as the app does (`AppDelegate.prepareToQuit`, Settings' field ending its editing first), then lets the
    /// window and the store's folder go.
    private func quit(_ harness: MainWindowHarness, settings: SettingsWindowController?) {
        var finished = false
        Task { @MainActor in
            await AppDelegate.prepareToQuit(settings: settings, environments: [harness.environment])
            finished = true
        }
        XCTAssertTrue(ListTestSupport.spin(until: { finished }, timeout: 10), "quitting finishes")
        settings?.tearDown()
        settings?.window?.close()
        harness.controller.tearDown()
        harness.controller.close()
        ListTestSupport.spin(for: 0.3)
        try? FileManager.default.removeItem(at: harness.directory)
    }

    private func assertNoContact(_ log: URL, _ moment: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(contacts, [], "\(moment): no contact recorded", file: file, line: line)
        XCTAssertEqual(EgressStubProtocol.requests, [], "\(moment): no request to Anthropic or OpenAI", file: file, line: line)
        XCTAssertEqual(launches(log), [], "\(moment): no CLI started", file: file, line: line)
    }

    func testNothingReachesAProviderOrStartsACLIUnlessTheUserActs() throws {
        let log = try installFakeClaude()
        let center = realCenter(keys: InMemoryAIKeyStore([.claudeAPI: "sk-ant-test-key"]))
        // Launch.
        let harness = try MainWindowHarness(helpMeWrite: center)
        var quitting = false
        defer { if !quitting { harness.close() } }
        ListTestSupport.spin(for: 0.3)
        assertNoContact(log, "launch")

        // Settings › AI opened, as the window shows it, then providers chosen: each sheet answered Turn On.
        var sheets = 0
        center.presentAlert = { _, _, done in
            sheets += 1
            done(1)
        }
        let settings = openSettings(harness)
        settings.ai.refresh()
        settings.ai.setProvider(.claudeAPI)
        settings.ai.setProvider(.claudeCode)
        XCTAssertEqual(sheets, 2, "each choice showed its sheet")
        XCTAssertEqual(harness.settings.aiProvider, .claudeCode)
        XCTAssertEqual(settings.ai.status, .ready("Claude Code found"), "from this Mac: the file, not its answer")
        settings.tearDown()

        // An empty reply's ghost, typing notes, the notes ghost, a selection's pill, the prompt line opened and closed, the
        // text's menu shown, switching conversations, a composer opened and typed in, its ghost and its prompt line.
        try select("thread-2", harness)
        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        let session = try XCTUnwrap(harness.reader.quickReplyWriteSession)
        session.assumesKeyWindow = true
        XCTAssertNotNil(session.layer.state.ghost, "the empty reply's ghost is local")
        let field = harness.reader.quickReplyBar.writingTextView
        field.insertText("tue 10 ok", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(session.availability, .ready(writer: "Claude", source: "Claude Code \u{00b7} Anthropic"))
        XCTAssertTrue(ListTestSupport.spin(until: { session.layer.state.ghost?.words == WriteWords.ghostNotes }, timeout: 3),
                      "the notes ghost, after its pause, is local")
        field.setSelectedRange(NSRange(location: 0, length: 3))
        XCTAssertNotNil(session.layer.state.pill, "the pill is local")
        let menu = NSMenu()
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                     windowNumber: field.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                                     clickCount: 1, pressure: 1))
        let shown = harness.reader.quickReplyBar.textView(field, menu: menu, for: event, at: 0)
        XCTAssertEqual(shown?.items.first?.title, "Rewrite Selection", "the text's menu shows Help me write's group, locally")
        harness.reader.helpMeWriteWithInstructions(nil)
        XCTAssertTrue(session.isPromptShown, "opening the prompt line is local")
        session.layer.prompt.instruction = "Warmer"
        session.closePrompt(focusText: true)
        let validate = NSMenuItem(title: "", action: #selector(ConversationViewController.helpMeWrite(_:)), keyEquivalent: "j")
        XCTAssertTrue(harness.reader.validateMenuItem(validate), "menu validation reaches nothing either")
        try select("thread-4", harness)
        try select("thread-2", harness)
        let accounts = harness.controller.accounts
        let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                       mode: .reply(MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-2-2"),
                                                                    all: false))
        composer.window?.makeFirstResponder(composer.bodyEditor)
        let composed = try XCTUnwrap(composer.bodyWriteSession)
        composed.assumesKeyWindow = true
        composer.bodyEditor.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertNotNil(composed.layer.state.ghost, "the composer's ghost is local")
        composer.bodyEditor.insertText("will read tonight", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(composer.validateMenuItem(validate))
        composer.helpMeWriteWithInstructions(nil)
        XCTAssertTrue(composed.isPromptShown)
        ListTestSupport.spin(for: 0.9)
        composer.closeWithoutSaving()

        assertNoContact(log, "typing, the ghost, the pill, the prompt line, the text's menu, switching, a composer")

        // Quitting as the app does, with Settings › AI open again.
        let reopened = openSettings(harness)
        assertNoContact(log, "Settings › AI reopened with Claude Code on")
        quitting = true
        quit(harness, settings: reopened)
        assertNoContact(log, "quitting")
    }

    /// Launched with a provider already on (Claude Code turned on, or Claude's API with a key stored), Settings › AI
    /// opened and reopened, a reply typed in: nothing is sent, nothing started, and quitting with Settings open sends
    /// nothing either. The status comes from this Mac.
    func testLaunchingAndReopeningSettingsWithAProviderOnReachNothing() throws {
        for kind in [AIProviderKind.claudeCode, .claudeAPI] {
            EgressRecorder.shared.reset()
            EgressStubProtocol.reset()
            let log = try installFakeClaude()
            try? FileManager.default.removeItem(at: log)
            let keys = InMemoryAIKeyStore(kind == .claudeAPI ? [.claudeAPI: "sk-ant-test-key"] : [:])
            let center = realCenter(keys: keys)
            let appSettings = ListTestSupport.settings()
            appSettings.aiProvider = kind
            appSettings.setAIConsent(true, for: kind, demo: false)
            // Launch.
            let harness = try MainWindowHarness(settings: appSettings, helpMeWrite: center)
            var quitting = false
            defer { if !quitting { harness.close() } }
            ListTestSupport.spin(for: 0.3)
            assertNoContact(log, "\(kind) launch")

            try select("thread-2", harness)
            XCTAssertTrue(harness.reader.focusQuickReply(all: false))
            harness.reader.quickReplyBar.writingTextView.insertText("tue 10 ok", replacementRange: NSRange(location: 0, length: 0))
            let session = try XCTUnwrap(harness.reader.quickReplyWriteSession)
            XCTAssertEqual(session.availability, .ready(writer: "Claude", source: kind == .claudeCode
                ? "Claude Code \u{00b7} Anthropic" : "Claude Opus 5.5 \u{00b7} Anthropic"))
            assertNoContact(log, "\(kind) typing")

            for opening in ["first", "second"] {
                let settings = openSettings(harness)
                XCTAssertEqual(settings.ai.provider, kind)
                XCTAssertEqual(settings.ai.status.isReady, true, "\(kind): ready, from this Mac")
                assertNoContact(log, "\(kind) Settings › AI opened, \(opening) time")
                if opening == "second" {
                    quitting = true
                    quit(harness, settings: settings)
                } else {
                    settings.tearDown()
                    settings.window?.close()
                }
            }
            assertNoContact(log, "\(kind) quitting")
        }
    }

    /// The key field saves on leaving it, but only Return checks the key with Anthropic: a click elsewhere, Settings
    /// closing and quitting with a key typed send nothing (the key is saved all the same).
    func testOnlyReturnInTheKeyFieldChecksTheKeyNeverLeavingItOrQuitting() throws {
        let log = try installFakeClaude()
        let keys = InMemoryAIKeyStore()
        let center = realCenter(keys: keys)
        let appSettings = ListTestSupport.settings()
        appSettings.aiProvider = .claudeAPI
        appSettings.setAIConsent(true, for: .claudeAPI, demo: false)
        let harness = try MainWindowHarness(settings: appSettings, helpMeWrite: center)
        var quitting = false
        defer { if !quitting { harness.close() } }
        let settings = openSettings(harness)
        let field = try XCTUnwrap(keyField(in: settings))

        // Return: saved and checked, once.
        type("sk-ant-first", into: field, in: settings)
        XCTAssertEqual(settings.ai.keyText, "sk-ant-first")
        field.currentEditor()?.insertNewline(nil)
        XCTAssertTrue(ListTestSupport.spin(until: { EgressStubProtocol.requests.count == 1 && settings.ai.status != .checking },
                                           timeout: 10), "Return checks the key")
        XCTAssertEqual(try keys.key(for: .claudeAPI), "sk-ant-first")
        XCTAssertEqual(contacts, ["check: GET api.anthropic.com/v1/models"])

        // A click elsewhere: saved, not checked.
        EgressRecorder.shared.reset()
        EgressStubProtocol.reset()
        type("sk-ant-second", into: field, in: settings)
        settings.endEditing()
        ListTestSupport.spin(for: 0.3)
        XCTAssertEqual(try keys.key(for: .claudeAPI), "sk-ant-second", "saved as the field lost the keyboard")
        assertNoContact(log, "leaving the key field")

        // Quitting with a key typed: saved, not checked.
        type("sk-ant-third", into: field, in: settings)
        quitting = true
        quit(harness, settings: settings)
        XCTAssertEqual(try keys.key(for: .claudeAPI), "sk-ant-third", "saved as quitting ended its editing")
        XCTAssertFalse(center.writer.isChecking)
        assertNoContact(log, "quitting with a key typed")
    }

    /// A check under way when the environment goes away is cancelled, and none starts after: quitting never reaches a
    /// provider.
    func testShuttingDownCancelsACheckAndRefusesLaterOnes() throws {
        let log = try installFakeClaude()
        let center = realCenter(keys: InMemoryAIKeyStore([.claudeAPI: "sk-ant-test-key"]))
        let configuration = AIProviderConfiguration(kind: .claudeAPI)
        var finished = false
        Task { @MainActor in
            await center.shutdown()
            let health = await center.writer.check(configuration, action: AIUserAction(userPressed: .check))
            XCTAssertTrue(health.isReady, "after shutdown a check answers from this Mac: \(health)")
            finished = true
        }
        XCTAssertTrue(ListTestSupport.spin(until: { finished }, timeout: 5))
        assertNoContact(log, "a check after shutdown")
    }

    /// Runs a write of `writing` through `center`'s writer to its end: the error it ended with, if any.
    private func failure(of writing: WriteKind, _ center: HelpMeWrite, _ configuration: AIProviderConfiguration) -> AIError? {
        let request = AIWriteRequest(kind: writing, instructions: "Write it.", transcript: "", task: "Say yes")
        let stream = center.writer.write(request, using: configuration, in: AIFieldID(name: "egress"),
                                         action: AIUserAction(userPressed: .write))
        var failure: AIError?
        var isOver = false
        Task { @MainActor in
            do { for try await _ in stream {} } catch { failure = AIError.from(error) }
            isOver = true
        }
        XCTAssertTrue(ListTestSupport.spin(until: { isOver }, timeout: 10), "\(writing): the write ends")
        return failure
    }

    /// A Turn On from before the sheet named new messages and forwards never sends one (§5.56). With the real providers
    /// on that permission alone, a new message's or a forward's request handed to the writer reaches nothing and starts
    /// nothing, whatever asked for it; the reply's request, on the same permission, goes as it always did.
    func testANewMessageOrAForwardOnAnEarlierTurnOnReachesNothing() throws {
        let log = try installFakeClaude()
        for kind in [AIProviderKind.claudeCode, .claudeAPI] {
            let suite = "HelpMeWriteEgress.earlier.\(UUID().uuidString)"
            addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            // As a version before 1.21 left them: chosen, and turned on past the sheet that asked about replies.
            defaults.set(kind.rawValue, forKey: "aiProvider")
            defaults.set([kind.rawValue], forKey: "aiConsent")
            let settings = AppSettings(defaults: defaults)
            let center = realCenter(keys: InMemoryAIKeyStore([.claudeAPI: "sk-ant-test-key"]))
            center.settings = settings
            let configuration = try XCTUnwrap(center.configuration)
            XCTAssertEqual(configuration.kind, kind)
            XCTAssertTrue(center.availability(for: .reply).isReady, "\(kind): replies are ready, from this Mac")
            for writing in [WriteKind.newMessage, .forward] {
                XCTAssertEqual(center.availability(for: writing), .unavailable(reason: "Help Me Write is on for replies only"),
                               "\(kind) \(writing)")
                XCTAssertEqual(failure(of: writing, center, configuration), .consentRequired, "\(kind) \(writing): refused by the writer")
            }
            ListTestSupport.spin(for: 0.2)
            assertNoContact(log, "\(kind): a new message and a forward on a Turn On given for replies")

            guard kind == .claudeAPI else { continue }
            XCTAssertNotEqual(failure(of: .reply, center, configuration), .consentRequired, "the reply is allowed")
            XCTAssertEqual(contacts, ["write: POST api.anthropic.com/v1/messages"], "and is the one contact")
            XCTAssertEqual(launches(log), [], "no CLI for the API")
        }
    }

    func testEachAllowedActionMakesExactlyItsOwnContacts() throws {
        let log = try installFakeClaude()
        let keys = InMemoryAIKeyStore()
        let center = realCenter(keys: keys)
        let harness = try MainWindowHarness(helpMeWrite: center)
        defer { harness.close() }
        let model = settingsModel(harness)

        // Claude Code: ⌘J runs its version and sign-in check right before the request, then the request.
        model.setProvider(.claudeCode)
        XCTAssertEqual(contacts, [], "choosing it, sheet and Turn On, reached nothing")
        try select("thread-2", harness)
        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        harness.reader.quickReplyBar.writingTextView.insertText("tue 10 ok", replacementRange: NSRange(location: 0, length: 0))
        harness.reader.helpMeWrite(nil)
        let session = try XCTUnwrap(harness.reader.writeSession)
        XCTAssertTrue(ListTestSupport.spin(until: { if case .failed = session.phase { return true } else { return false } }, timeout: 10),
                      "the fake fails the write, inline")
        XCTAssertEqual(contacts, ["write: claude --version", "write: claude auth", "write: claude -p"])
        XCTAssertEqual(launches(log).count, 3)
        XCTAssertEqual(launches(log), ["--version", "--restricted", "-p"])
        XCTAssertFalse(arguments(log).contains("tue 10 ok"), "the request goes to stdin, never argv")

        // Check: the sign-in (the version is known for this file now).
        EgressRecorder.shared.reset()
        model.check()
        XCTAssertTrue(ListTestSupport.spin(until: { model.status != .checking }, timeout: 10))
        XCTAssertEqual(contacts, ["check: claude auth"])
        XCTAssertEqual(model.status, .ready("Claude Code 2.1.322 \u{00b7} signed in with claude.ai"))

        // Claude's API: choosing it reaches nothing; saving a key checks it once; ⌘J sends once; Check once.
        EgressRecorder.shared.reset()
        EgressStubProtocol.reset()
        model.setProvider(.claudeAPI)
        XCTAssertEqual(contacts, [])
        model.keyText = "sk-ant-test-key"
        model.commitKey(checking: true)
        XCTAssertTrue(ListTestSupport.spin(until: { model.status != .checking }, timeout: 10))
        XCTAssertEqual(contacts, ["check: GET api.anthropic.com/v1/models"])
        XCTAssertEqual(EgressStubProtocol.requests, ["GET api.anthropic.com/v1/models"])
        harness.controller.window?.makeFirstResponder(harness.reader.quickReplyBar.writingTextView)
        session.refresh()
        harness.reader.helpMeWrite(nil)
        XCTAssertTrue(ListTestSupport.spin(until: { session.phase == .failed(reason: "The Anthropic API key was refused", offersSettings: true) },
                                           timeout: 10))
        XCTAssertEqual(contacts.last, "write: POST api.anthropic.com/v1/messages")
        XCTAssertEqual(EgressStubProtocol.requests, ["GET api.anthropic.com/v1/models", "POST api.anthropic.com/v1/messages"])
        model.check()
        XCTAssertTrue(ListTestSupport.spin(until: { EgressStubProtocol.requests.count == 3 && model.status != .checking }, timeout: 10))
        XCTAssertEqual(contacts.filter { $0.hasPrefix("check:") }.count, 2)
        XCTAssertEqual(launches(log).count, 4, "no CLI for the API")
    }

    // MARK: One gate in code

    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func sources(under path: String) throws -> [(name: String, text: String)] {
        let base = root.appendingPathComponent(path)
        let files = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? []
        return try files.filter { $0.pathExtension == "swift" }.map { url in
            (String(url.path.dropFirst(root.path.count + 1)), try String(contentsOf: url, encoding: .utf8))
        }
    }

    /// `text` without its comments: `//` to the end of a line (outside a string's quotes, as far as a scan can tell)
    /// and `/* … */` blocks, so a doc comment that names an API is not a call to it.
    private static func code(_ text: String) -> String {
        let withoutBlocks = text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        return withoutBlocks.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var inString = false
            var previous: Character = " "
            var kept = ""
            for character in line {
                if character == "\"" && previous != "\\" { inString.toggle() }
                if !inString, character == "/", previous == "/" {
                    kept.removeLast()
                    break
                }
                kept.append(character)
                previous = character
            }
            return kept
        }.joined(separator: "\n")
    }

    /// Where `pattern` matches in `text`, each with the name of the function it sits in (the last `func` before it).
    private static func matches(of pattern: String, in text: String) throws -> [String] {
        let expression = try NSRegularExpression(pattern: pattern)
        let functions = try NSRegularExpression(pattern: #"\bfunc\s+([A-Za-z_][A-Za-z0-9_]*)"#)
        let whole = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: whole.length)).map { match in
            let before = NSRange(location: 0, length: match.range.location)
            let enclosing = functions.matches(in: text, range: before).last.map { whole.substring(with: $0.range(at: 1)) }
            return enclosing ?? "(top level)"
        }
    }

    /// A `URLSession` send in any of its spellings (or the old `NSURLConnection`), but not a call through the gate itself.
    private static let sends = #"(?<!ProviderHTTP)\.(data|bytes|upload|download)\s*\(\s*(for|from|with)\b"#
        + #"|\b(dataTask|uploadTask|downloadTask|webSocketTask|streamTask)\s*\(|URLSession\s*\.\s*shared|NSURLConnection"#

    /// Every Swift file under Sources, comments left out, keyed by its path from the package root.
    private func allSources() throws -> [(name: String, code: String)] {
        try sources(under: "Sources").map { ($0.name, Self.code($0.text)) }
    }

    /// Only the user's own actions make the token every request and launch needs: Write and its siblings in the reply's
    /// session (`start`), Return on a typed key and Check in Settings › AI. Any spelling counts (`AIUserAction(userPressed:`,
    /// `.init(userPressed:`, `AIUserAction.init(…)`), and so does a new initializer in an extension: a new call site
    /// anywhere in the app fails here.
    func testOnlyTheUsersActionsMakeTheToken() throws {
        var makers: [String] = []
        var extensions: [String] = []
        for file in try allSources() where file.name != "Sources/PaperCore/AI/AIUserAction.swift" {
            makers += try Self.matches(of: #"userPressed\s*:|AIUserAction\s*\.\s*init\b"#, in: file.code).map { "\(file.name) \($0)" }
            if try !Self.matches(of: #"extension\s+AIUserAction\b"#, in: file.code).isEmpty { extensions.append(file.name) }
        }
        XCTAssertEqual(makers.sorted(), [
            "Sources/PaperApp/AI/AISettingsModel.swift check",
            "Sources/PaperApp/AI/AISettingsModel.swift commitKey",
            "Sources/PaperApp/AI/WriteSession.swift start",
        ])
        XCTAssertEqual(extensions, [], "no other way to make one")
        let token = try XCTUnwrap(try allSources().first { $0.name == "Sources/PaperCore/AI/AIUserAction.swift" })
        XCTAssertEqual(try Self.matches(of: #"\binit\s*\("#, in: token.code).count, 1, "one initializer")
    }

    /// The scan finds a token made in any of the spellings Swift allows.
    func testTheTokenScanSeesEverySpelling() throws {
        for line in ["func a() { _ = AIUserAction(userPressed: .write) }",
                     "func a() { writer.check(config, action: .init(userPressed: .check)) }",
                     "func a() { _ = AIUserAction.init(userPressed: .write) }",
                     "func a() { let make = AIUserAction.init; _ = make(.write) }",
                     "func a() { _ = AIUserAction(userPressed\n: .write) }"] {
            let found = try Self.matches(of: #"userPressed\s*:|AIUserAction\s*\.\s*init\b"#, in: Self.code(line))
            XCTAssertFalse(found.isEmpty, line)
            XCTAssertEqual(Set(found), ["a"], line)
        }
        let commented = Self.code("/// AIUserAction(userPressed: .write)\nlet x = 1 // userPressed: no")
        XCTAssertEqual(try Self.matches(of: #"userPressed\s*:"#, in: commented), [], "comments are not code")
    }

    /// Every HTTP send to Anthropic or OpenAI goes through `ProviderHTTP`, which records it against the user's action
    /// first; no other PaperAI file calls a `URLSession` send, and no module but PaperAI names their hosts. Every CLI launch is
    /// one `CLIProcess`, made only by `CLIProcessRunner.run` after it records the launch; nothing else in the app starts a
    /// process.
    func testEveryRequestAndLaunchGoesThroughTheGate() throws {
        let all = try allSources()
        let sends = Self.sends
        var ssaiSenders: [String: Int] = [:]
        for file in all where file.name.hasPrefix("Sources/PaperAI/") {
            let found = try Self.matches(of: sends, in: file.code)
            if !found.isEmpty { ssaiSenders[file.name] = found.count }
        }
        XCTAssertEqual(ssaiSenders, ["Sources/PaperAI/ProviderHTTP.swift": 2], "one place sends")
        let gate = try XCTUnwrap(all.first { $0.name == "Sources/PaperAI/ProviderHTTP.swift" })
        for function in ["data", "bytes"] {
            let body = try XCTUnwrap(gate.code.components(separatedBy: "static func \(function)(").dropFirst().first)
            let record = try XCTUnwrap(body.range(of: "AIEgress.record("), "\(function) records")
            let send = try XCTUnwrap(body.range(of: "session.\(function)(for:"))
            XCTAssertLessThan(record.lowerBound, send.lowerBound, "\(function) records before it sends")
        }

        let hosts = #"api\.anthropic\.com|api\.openai\.com"#
        let naming = try all.filter { try !Self.matches(of: hosts, in: $0.code).isEmpty }.map(\.name)
        XCTAssertEqual(Set(naming), ["Sources/PaperAI/AnthropicMessagesProvider.swift", "Sources/PaperAI/OpenAIResponsesProvider.swift"],
                       "only the providers know where to send")

        let launching = #"\bProcess\s*\(|\bProcess\s*\.\s*(run|launchedProcess)\b|\bposix_spawn|\bNSTask\b"#
            + #"|\bexecv[pe]?\s*\(|\bfork\s*\(\s*\)"#
        let launchers = try all.filter { try !Self.matches(of: launching, in: $0.code).isEmpty }.map(\.name)
        XCTAssertEqual(launchers, ["Sources/PaperAI/CLIProcess.swift"], "one process launcher")
        let process = try XCTUnwrap(all.first { $0.name == "Sources/PaperAI/CLIProcess.swift" })
        XCTAssertEqual(try Self.matches(of: #"\bprocess\s*\.\s*run\s*\("#, in: process.code), ["start"], "it starts in one place")
        let makers = try all.flatMap { file in try Self.matches(of: #"\bCLIProcess\s*\("#, in: file.code).map { "\(file.name) \($0)" } }
        XCTAssertEqual(makers, ["Sources/PaperAI/CLIProcessRunner.swift run"], "made only to run a command")
        let runner = try XCTUnwrap(all.first { $0.name == "Sources/PaperAI/CLIProcessRunner.swift" })
        let run = try XCTUnwrap(runner.code.components(separatedBy: "func run(_ command: CLICommand)").dropFirst().first)
        let record = try XCTUnwrap(run.range(of: "AIEgress.record(.launch("), "every launch is recorded")
        let make = try XCTUnwrap(run.range(of: "CLIProcess("))
        XCTAssertLessThan(record.lowerBound, make.lowerBound, "before it starts")
        let command = try XCTUnwrap(all.first { $0.name == "Sources/PaperAI/CLICommand.swift" })
        XCTAssertTrue(command.code.contains("var action: AIUserAction"), "no command without the user's action")
    }

    /// The send scan sees the spellings a new call site could use.
    func testTheSendScanSeesEverySpelling() throws {
        let sends = Self.sends
        for line in ["func a() async { _ = try? await session.data(for: request) }",
                     "func a() async { _ = try? await URLSession.shared.data(from: url) }",
                     "func a() async { _ = try? await session.upload(for: request, from: body) }",
                     "func a() async { _ = try? await session.download(for: request) }",
                     "func a() { session.dataTask(with: request).resume() }",
                     "func a() { session.webSocketTask(with: url).resume() }",
                     "func a() async { _ = try? await session.bytes(for: request) }"] {
            XCTAssertFalse(try Self.matches(of: sends, in: line).isEmpty, line)
        }
        let gated = "func a() async { _ = try? await ProviderHTTP.data(for: request, on: session, by: action) }"
        XCTAssertTrue(try Self.matches(of: sends, in: gated).isEmpty,
                      "the gate's own callers are not sends")
    }
}

/// Every contact `AIEgress` saw, from any thread.
final class EgressRecorder: @unchecked Sendable {
    static let shared = EgressRecorder()
    private let lock = NSLock()
    private var recorded: [String] = []

    var contacts: [String] { lock.withLock { recorded } }

    func record(_ contact: String) { lock.withLock { recorded.append(contact) } }

    func reset() { lock.withLock { recorded = [] } }
}

/// Answers every request 401 (the API's “invalid key”, which nothing retries), recording its method, host and path.
final class EgressStubProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [String] = []

    static var requests: [String] { lock.withLock { seen } }

    static func reset() { lock.withLock { seen = [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let line = "\(request.httpMethod ?? "GET") \(request.url?.host ?? "")\(request.url?.path ?? "")"
        Self.lock.withLock { Self.seen.append(line) }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: "HTTP/1.1",
                                             headerFields: ["content-type": "application/json"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
