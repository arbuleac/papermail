import AppKit
import SSAI
import SSCore
import XCTest
@testable import SuperSparrowApp

/// The hard rule (spec §3b): nothing reaches Anthropic or OpenAI, and none of the user's CLIs starts, unless the user acts.
/// The app runs here with the real providers (`AIProviderFactory`), their HTTP routed to a recording `URLProtocol` and
/// their CLI a fake `claude` that logs each launch, so every contact is seen three ways: the stub, the fake's log and
/// `AIEgress`. Launch, opening Settings › AI, choosing a provider (its sheet and Turn On), typing notes, the hint,
/// switching conversations, opening a composer and quitting make none; each allowed action exactly its own.
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

    func testNothingReachesAProviderOrStartsACLIUnlessTheUserActs() throws {
        let log = try installFakeClaude()
        let center = realCenter(keys: InMemoryAIKeyStore([.claudeAPI: "sk-ant-test-key"]))
        // Launch.
        let harness = try MainWindowHarness(helpMeWrite: center)
        var closed = false
        defer { if !closed { harness.close() } }

        // Settings › AI opened, as the window shows it, then providers chosen: each sheet answered Turn On.
        let settings = SettingsWindowController(environment: harness.environment, settings: harness.settings,
                                                mailtoHandler: FakeMailtoHandler(), loginItem: FakeLoginItem())
        settings.window?.setFrameAutosaveName("")
        settings.window?.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        settings.ai.locateExecutable = { [folder] kind, chosen in
            AISettingsModel.locateLikeTheProviders(kind, chosen: chosen, searchFolders: [folder!.appendingPathComponent("bin")])
        }
        var sheets = 0
        center.presentAlert = { _, _, done in
            sheets += 1
            done(1)
        }
        settings.show(tab: .ai)
        ListTestSupport.spin(for: 0.3)
        settings.ai.refresh()
        settings.ai.setProvider(.claudeAPI)
        settings.ai.setProvider(.claudeCode)
        XCTAssertEqual(sheets, 2, "each choice showed its sheet")
        XCTAssertEqual(harness.settings.aiProvider, .claudeCode)
        XCTAssertEqual(settings.ai.status, .ready("Claude Code found"), "from this Mac: the file, not its answer")
        settings.tearDown()

        // Typing notes, the hint, switching conversations, a composer opened and typed in.
        try select("thread-2", harness)
        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        let field = harness.reader.quickReplyBar.writingTextView
        field.insertText("tue 10 ok", replacementRange: NSRange(location: 0, length: 0))
        let control = harness.reader.quickReplyBar.writeControl
        XCTAssertEqual(control.availability, .ready(writer: "Claude", source: "Claude Code \u{00b7} Anthropic"))
        XCTAssertTrue(control.showsHint, "the hint is local")
        let validate = NSMenuItem(title: "", action: #selector(ConversationViewController.helpMeWrite(_:)), keyEquivalent: "j")
        XCTAssertTrue(harness.reader.validateMenuItem(validate), "menu validation reaches nothing either")
        try select("thread-4", harness)
        try select("thread-2", harness)
        let accounts = harness.controller.accounts
        let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                       mode: .reply(MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-2-2"),
                                                                    all: false))
        composer.window?.makeFirstResponder(composer.bodyEditor)
        composer.bodyEditor.insertText("will read tonight", replacementRange: NSRange(location: 0, length: 0))
        XCTAssertTrue(composer.validateMenuItem(validate))
        ListTestSupport.spin(for: 0.5)
        composer.closeWithoutSaving()

        XCTAssertEqual(contacts, [], "no contact recorded")
        XCTAssertEqual(EgressStubProtocol.requests, [], "no request to Anthropic or OpenAI")
        XCTAssertEqual(launches(log), [], "no CLI started")

        // Quitting.
        harness.close()
        closed = true
        ListTestSupport.spin(for: 0.3)
        XCTAssertEqual(contacts, [])
        XCTAssertEqual(EgressStubProtocol.requests, [])
        XCTAssertEqual(launches(log), [])
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
        model.commitKey()
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

    /// Only the user's own actions make the token every request and launch needs: Write and its siblings in the reply's
    /// session, Check and a saved key in Settings › AI. A new call site elsewhere fails here.
    func testOnlyTheUsersActionsMakeTheToken() throws {
        var makers: [String: Int] = [:]
        for file in try sources(under: "Sources") {
            let code = file.text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            let count = code.reduce(0) { $0 + $1.components(separatedBy: "AIUserAction(userPressed:").count - 1 }
            if count > 0 { makers[file.name] = count }
        }
        XCTAssertEqual(makers, [
            "Sources/SuperSparrowApp/AI/WriteSession.swift": 1,
            "Sources/SuperSparrowApp/AI/AISettingsModel.swift": 2,
        ])
    }

    /// The adapters reach the network and start processes in three places only, and each records the contact against
    /// its user action first.
    func testEveryRequestAndLaunchGoesThroughTheGate() throws {
        var network: Set<String> = []
        var processes: Set<String> = []
        for file in try sources(under: "Sources/SSAI") {
            if file.text.contains("session.bytes(") || file.text.contains("session.data(") || file.text.contains(".dataTask(") {
                network.insert(file.name)
                XCTAssertTrue(file.text.contains("AIEgress.record("), "\(file.name) records before it sends")
            }
            if file.text.contains("Process()") { processes.insert(file.name) }
        }
        XCTAssertEqual(network, Set(["Sources/SSAI/HTTPStreamingWrite.swift", "Sources/SSAI/HTTPKeyCheck.swift"]))
        XCTAssertEqual(processes, ["Sources/SSAI/CLIProcess.swift"], "one process launcher")
        let runner = try XCTUnwrap(try sources(under: "Sources/SSAI").first { $0.name.hasSuffix("CLIProcessRunner.swift") })
        XCTAssertTrue(runner.text.contains("AIEgress.record(.launch("), "every launch is recorded before it starts")
        let command = try XCTUnwrap(try sources(under: "Sources/SSAI").first { $0.name.hasSuffix("CLICommand.swift") })
        XCTAssertTrue(command.text.contains("var action: AIUserAction"), "no command without the user's action")
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
