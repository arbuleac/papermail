import XCTest
import SSCore
@testable import SSAI

/// Claude Code through a fake `claude` that checks what it is handed and replays the recorded runs (cli.md §B).
final class ClaudeCodeProviderTests: XCTestCase {
    private var fake: CLIFakeTool!
    private let request = AIWriteRequest(
        instructions: "You write the reply body only.\nPlain text, no \"Markdown\".",
        transcript: "<<<CONVERSATION 1a2b3c4d>>>\nDana: MAIL-MARKER-4711 Can we meet Thursday?\n<<<END CONVERSATION 1a2b3c4d>>>",
        task: "Instruction: TASK-MARKER-0815 say Thursday works", model: "haiku")

    override func setUpWithError() throws {
        fake = try CLIFakeTool()
    }

    override func tearDown() {
        fake.remove()
        fake = nil
    }

    private func provider(model: String? = "haiku", chosen: String? = nil,
                          limits: CLILimits = CLIFakeTool.fastLimits) -> ClaudeCodeProvider {
        ClaudeCodeProvider(model: model, executablePath: chosen, runner: fake.runner(limits: limits))
    }

    private func install(main: String, version: String = "2.1.322 (Claude Code)") throws {
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.version = "printf '%s\\n' \(CLIFakeTool.quoted(version)); exit 0"
        behaviour.authStatus = CLIFakeTool.replay("cli/claude-auth-status.json")
        behaviour.main = main
        try fake.install("claude", behaviour)
    }

    private func write(_ provider: ClaudeCodeProvider, _ request: AIWriteRequest? = nil) async -> ([AIWriteEvent], AIError?) {
        let (events, error) = await collectCLIWrite(provider.write(request ?? self.request, action: pressedWrite))
        return (events, error.map { $0 as? AIError ?? .badResponse(code: -1) })
    }

    // MARK: The recipe

    func testTheVerifiedRecipeStreamsTheRecordedReply() async throws {
        try install(main: try fake.replayIsolated("cli/claude-stream.jsonl"))
        let (events, error) = await write(provider())
        XCTAssertNil(error)
        XCTAssertEqual(events, [
            .text("Thanks, Thursday"), .text(" works."),
            .usage(AIUsage(inputTokens: 687, outputTokens: 13)),
            .finished(.done),
        ], "the assistant and result lines repeat the text: no replace")
        XCTAssertEqual(try fake.arguments(), [
            "-p", "--output-format", "stream-json", "--verbose", "--include-partial-messages",
            "--model", "haiku",
            "--restricted", "--setting-sources", "",
            "--tools", "",
            "--strict-mcp-config", "--mcp-config", #"{"mcpServers":{}}"#,
            "--safe-mode", "--disable-slash-commands",
            "--permission-mode", "dontAsk", "--permission-prompts", "none",
            "--no-session-persistence",
            "--max-turns", "1", "--max-budget-usd", "0.25",
            "--system-prompt", request.instructions,
            "--input-format", "text",
        ])
        XCTAssertEqual(fake.recorded("stdin"), request.userTurn)
        XCTAssertFalse(try fake.arguments().contains { $0.contains("MARKER") }, "the mail and the ask never go in argv")
        let environment = try fake.environment()
        for name in ["DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING", "DISABLE_AUTOUPDATER", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] {
            XCTAssertEqual(environment[name], "1", name)
        }
        XCTAssertEqual(environment["USER"], "someone")
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertEqual(fake.calls(), ["--version", "auth status", "-p --output-format"], "the sign-in is checked before each send")
        XCTAssertEqual(fake.invocations()[1], "--restricted --setting-sources  auth status",
                       "the sign-in is read with the run's isolation: a settings file's Bedrock or key never counts")
        XCTAssertEqual(fake.leftoverFolders(), [])
    }

    func testWithoutAModelTheCLIChooses() async throws {
        try install(main: try fake.replayIsolated("cli/claude-stream.jsonl"))
        var request = request
        request.model = nil
        _ = await write(provider(model: nil), request)
        XCTAssertFalse(try fake.arguments().contains("--model"))
    }

    func testTheRequestsModelWins() async throws {
        try install(main: try fake.replayIsolated("cli/claude-stream.jsonl"))
        var request = request
        request.model = "opus"
        _ = await write(provider(model: "haiku"), request)
        let arguments = try fake.arguments()
        XCTAssertEqual(arguments[arguments.firstIndex(of: "--model")! + 1], "opus")
    }

    func testAStreamLetGoUnreadNeverStarts() async throws {
        try install(main: try fake.replayIsolated("cli/claude-stream.jsonl"))
        do {
            _ = provider().write(request, action: pressedWrite)
        }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(fake.calls(), [], "no --version, no auth status, no run: nothing starts before the first read")
        XCTAssertNil(fake.recorded("stdin"))
    }

    // MARK: Failures

    func testSignedOutSaysSoAndShowsNothing() async throws {
        try install(main: try fake.replayIsolated("cli/claude-signed-out.jsonl", status: 1))
        let (events, error) = await write(provider())
        XCTAssertEqual(error, .signedOut)
        XCTAssertEqual(events, [], "the synthetic line's “Not logged in” is the CLI's, never the reply")
    }

    func testABadModelIsUnavailable() async throws {
        try install(main: try fake.replayIsolated("cli/claude-bad-model.jsonl", stderr: "cli/claude-bad-model.stderr.txt", status: 1))
        let (events, error) = await write(provider())
        XCTAssertEqual(error, .modelUnavailable)
        XCTAssertEqual(events, [])
    }

    func testThePlansLimit() async throws {
        try install(main: CLIFakeTool.emit([
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour"}}"#,
            #"{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"You've hit your limit"}]},"error":"rate_limit","is_api_error_message":true,"api_error_status":429}"#,
            #"{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":429,"result":"You've hit your limit"}"#,
        ], status: 1))
        let (events, error) = await write(provider())
        XCTAssertEqual(error, .planLimit)
        XCTAssertEqual(events, [])
    }

    func testOverloaded() async throws {
        try install(main: CLIFakeTool.emit([
            #"{"type":"assistant","message":{"model":"<synthetic>","content":[{"type":"text","text":"Overloaded"}]},"error":"unknown","is_api_error_message":true,"api_error_status":529}"#,
            #"{"type":"result","subtype":"success","is_error":true,"terminal_reason":"api_error","api_error_status":529}"#,
        ], status: 1))
        let (_, error) = await write(provider())
        XCTAssertEqual(error, .overloaded)
    }

    func testAnUnexplainedFailureCarriesTheExitStatus() async throws {
        try install(main: CLIFakeTool.emit([#"{"type":"result","subtype":"error_during_execution","is_error":true}"#], status: 7))
        let (_, error) = await write(provider())
        XCTAssertEqual(error, .badResponse(code: 7))
    }

    func testARejectedFlagMeansThisVersionDoesNotFit() async throws {
        try install(main: "printf '%s\\n' \"error: unknown option '--safe-mode'\" >&2; exit 1", version: "2.4.0 (Claude Code)")
        let (_, error) = await write(provider())
        XCTAssertEqual(error, .newerVersion(found: "2.4.0"), "a flag gone is a newer Claude Code: updating cannot help")
    }

    // MARK: Where it sends

    func testAnotherServiceOrSignInSendsNothing() async throws {
        for status in [#"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"bedrock"}"#,
                       #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"vertex"}"#,
                       #"{"loggedIn":true,"authMethod":"console","apiProvider":"firstParty"}"#,
                       #"{"loggedIn":true,"authMethod":"claude.ai"}"#] {
            fake.remove()
            fake = try CLIFakeTool()
            var behaviour = CLIFakeTool.Behaviour()
            behaviour.authStatus = "printf '%s\\n' \(CLIFakeTool.quoted(status)); exit 0"
            behaviour.main = try fake.replayIsolated("cli/claude-stream.jsonl")
            try fake.install("claude", behaviour)
            let (events, error) = await write(provider())
            XCTAssertEqual(error, .otherSignIn, status)
            XCTAssertEqual(events, [], status)
            XCTAssertEqual(fake.calls(), ["--version", "auth status"], "\(status): never run with the request")
            XCTAssertNil(fake.recorded("stdin"), status)
            let health = await provider().check(pressedCheck)
            XCTAssertEqual(health, .needsSetup(reason: "Claude Code isn't using your claude.ai sign-in"), status)
        }
    }

    func testAnAPIKeyInTheRunEndsItBeforeTheRequest() async throws {
        let signals = CLIFakeTool.quoted(fake.spy.appendingPathComponent("signals").path)
        let initLine = try FixtureFiles.isolatedClaude("cli/claude-stream.jsonl").split(separator: "\n")[1]
            .replacingOccurrences(of: #""apiKeySource":"none""#, with: #""apiKeySource":"ANTHROPIC_API_KEY""#)
        try install(main: #"trap 'echo TERM >> "# + signals + #"; exit 143' TERM; "#
            + "printf '%s\\n' \(CLIFakeTool.quoted(initLine)); while :; do /bin/sleep 0.05; done")
        let (events, error) = await write(provider())
        XCTAssertEqual(error, .otherSignIn)
        XCTAssertEqual(events, [])
        let ended = await fake.wait { fake.recorded("signals") == "TERM\n" && fake.leftoverFolders().isEmpty }
        XCTAssertTrue(ended)
    }

    func testTheUsersOwnPluginsEndTheRun() async throws {
        // As recorded before the isolation joined the recipe: the user's swift-lsp plugin in the init line.
        try install(main: CLIFakeTool.replay("cli/claude-stream.jsonl"))
        let (events, error) = await write(provider())
        XCTAssertEqual(error, .badResponse(code: 0))
        XCTAssertEqual(events, [], "ended at the init line, before any text")
    }

    func testSilenceTimesOut() async throws {
        try install(main: #"printf '{"type":"system","subtype":"init"}\n'; exec /bin/sleep 30"#)
        var limits = CLIFakeTool.fastLimits
        limits.idle = .seconds(2)
        let (_, error) = await write(provider(limits: limits))
        XCTAssertEqual(error, .timedOut)
        XCTAssertEqual(fake.leftoverFolders(), [])
    }

    func testAToolEndsTheRunAtOnce() async throws {
        let signals = CLIFakeTool.quoted(fake.spy.appendingPathComponent("signals").path)
        try install(main: #"trap 'echo TERM >> "# + signals + #"; exit 143' TERM; "#
            + #"printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","name":"Bash"}}}'; "#
            + "while :; do /bin/sleep 0.05; done")
        let (_, error) = await write(provider())
        XCTAssertEqual(error, .badResponse(code: 0))
        let ended = await fake.wait { fake.recorded("signals") == "TERM\n" && fake.leftoverFolders().isEmpty }
        XCTAssertTrue(ended, "the process was ended, not left to run the tool")
    }

    // MARK: The text

    func testTheFinalTextCorrectsWhatStreamed() async throws {
        try install(main: CLIFakeTool.emit([
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}}"#,
            #"{"type":"assistant","message":{"model":"claude-haiku-5-5","content":[{"type":"text","text":"Hello Dana"}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","result":"Hello Dana"}"#,
        ]))
        let (events, error) = await write(provider())
        XCTAssertNil(error)
        XCTAssertEqual(events, [.text("Hel"), .replaceAll("Hello Dana"), .finished(.done)])
    }

    func testThinkingIsNotTheReply() async throws {
        try install(main: CLIFakeTool.emit([
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"They want Thursday."}}}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"thinking","thinking":"They want Thursday."}]}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Thursday works."}}}"#,
            #"{"type":"assistant","message":{"model":"claude-opus-5-5","content":[{"type":"text","text":"Thursday works."}]}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"end_turn","result":"Thursday works."}"#,
        ]))
        let (events, _) = await write(provider())
        XCTAssertEqual(events, [.text("Thursday works."), .finished(.done)])
    }

    func testTheOutputCapAndARefusalEndTheWriteTheirWay() async throws {
        try install(main: CLIFakeTool.emit([
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Thursday"}}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"max_tokens","result":"Thursday"}"#,
        ]))
        let (capped, _) = await write(provider())
        XCTAssertEqual(capped.last, .finished(.maxTokens))

        try install(main: CLIFakeTool.emit([
            #"{"type":"stream_event","event":{"type":"message_delta","delta":{"stop_reason":"refusal"}}}"#,
            #"{"type":"result","subtype":"success","is_error":false,"stop_reason":"refusal","result":"I can't help with that."}"#,
        ]))
        let (refused, _) = await write(provider())
        XCTAssertEqual(refused, [.finished(.refused)], "the refusal's words are never shown")
    }

    func testTheStreamEndsAtTheAnswerAndTheCLIExitsByItself() async throws {
        let finished = CLIFakeTool.quoted(fake.spy.appendingPathComponent("exited-by-itself").path)
        let signals = CLIFakeTool.quoted(fake.spy.appendingPathComponent("signals").path)
        try install(main: #"trap 'echo TERM >> "# + signals + #"; exit 143' TERM; "#
            + #"/bin/cat "# + CLIFakeTool.quoted(try fake.isolatedCopy("cli/claude-stream.jsonl").path)
            + "; /bin/sleep 3; echo yes > \(finished); exit 0")
        let started = Date()
        let (events, error) = await write(provider())
        XCTAssertNil(error)
        XCTAssertEqual(events.last, .finished(.done))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "the answer does not wait for the exit")
        let exited = await fake.wait(timeout: 8) { fake.recorded("exited-by-itself") == "yes\n" && fake.leftoverFolders().isEmpty }
        XCTAssertTrue(exited)
        XCTAssertNil(fake.recorded("signals"), "Claude Code tidies its session files on a normal exit: no SIGTERM")
    }

    // MARK: Through the writer

    @MainActor
    func testTheWritersStopEndsTheProcess() async throws {
        let signals = CLIFakeTool.quoted(fake.spy.appendingPathComponent("signals").path)
        try install(main: #"trap 'echo TERM >> "# + signals + #"; exit 143' TERM; "#
            + #"printf '%s\n' '{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Thurs"}}}'; "#
            + "while :; do /bin/sleep 0.05; done")
        let provider = provider()
        let writer = AIWriter(resolve: { _ in provider }, hasConsent: { _ in true })
        let field = AIFieldID(name: "quick reply")
        var events: [AIWriteEvent] = []
        for try await event in writer.write(request, using: AIProviderConfiguration(kind: .claudeCode, model: "haiku"), in: field, action: pressedWrite) {
            events.append(event)
            if event == .text("Thurs") { writer.stop(field) }
        }
        XCTAssertEqual(events, [.text("Thurs"), .finished(.cancelled)])
        XCTAssertFalse(writer.isWriting(in: field))
        let ended = await fake.wait { fake.recorded("signals") == "TERM\n" && fake.leftoverFolders().isEmpty }
        XCTAssertTrue(ended, "Stop ended the process and its folder went")
    }

    // MARK: Finding and checking the CLI

    func testNotInstalled() async throws {
        let (_, error) = await write(provider())
        XCTAssertEqual(error, .notInstalled)
        let health = await provider().check(pressedCheck)
        XCTAssertEqual(health, .needsSetup(reason: AIHealth.notFoundWords(for: .claudeCode)))
        XCTAssertEqual(health.words.replacingOccurrences(of: "\u{2060}", with: ""),
                       "Claude Code not found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin")
    }

    func testAnOldVersionIsRefusedBeforeAnythingIsSent() async throws {
        try install(main: try fake.replayIsolated("cli/claude-stream.jsonl"), version: "2.0.76 (Claude Code)")
        let provider = provider()
        let (_, error) = await write(provider)
        XCTAssertEqual(error, .unsupportedVersion(found: "2.0.76"))
        XCTAssertEqual(fake.calls(), ["--version"])
        let health = await provider.check(pressedCheck)
        XCTAssertEqual(health, .needsSetup(reason: AIError.unsupportedVersion(found: "2.0.76").message(for: .claudeCode)))
        XCTAssertEqual(fake.calls(), ["--version"], "remembered until the file changes")
    }

    func testTheVersionIsCheckedOncePerExecutableFile() async throws {
        try install(main: try fake.replayIsolated("cli/claude-stream.jsonl"))
        let provider = provider()
        _ = await write(provider)
        _ = await write(provider)
        XCTAssertEqual(fake.calls().filter { $0 == "--version" }.count, 1)
        // An update is a new file.
        try install(main: try fake.replayIsolated("cli/claude-stream.jsonl"), version: "2.1.400 (Claude Code)")
        _ = await write(provider)
        XCTAssertEqual(fake.calls().filter { $0 == "--version" }.count, 2)
    }

    func testAChosenCLIIsUsed() async throws {
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.authStatus = CLIFakeTool.replay("cli/claude-auth-status.json")
        behaviour.main = try fake.replayIsolated("cli/claude-stream.jsonl")
        let chosen = try fake.install("claude-nightly", in: fake.root, behaviour)
        let (events, error) = await write(provider(chosen: chosen.path))
        XCTAssertNil(error)
        XCTAssertEqual(events.last, .finished(.done))
        XCTAssertEqual(try fake.environment()["PATH"], "/usr/bin:/bin:" + fake.root.path)
    }

    func testHealthSaysVersionAndHowItIsSignedIn() async throws {
        try install(main: "exit 0")
        let health = await provider().check(pressedCheck)
        XCTAssertEqual(health, .ready(detail: "Claude Code 2.1.322 · signed in with claude.ai"))
        XCTAssertEqual(fake.calls(), ["--version", "auth status"], "health sends nothing to a model")
    }

    // MARK: Local health (spec §3b): nothing is started

    func testLocalHealthStartsNothingAndReadsTheVersionFromThePath() throws {
        XCTAssertEqual(provider().localHealth(), .needsSetup(reason: AIHealth.notFoundWords(for: .claudeCode)))
        try install(main: "exit 0")
        XCTAssertEqual(provider().localHealth(), .ready(detail: "Claude Code found"), "the file, not its answer")
        // ~/.local/bin/claude leads to …/claude/versions/2.1.322: the version is in the path.
        let versions = fake.root.appendingPathComponent("share/claude/versions", isDirectory: true)
        try FileManager.default.createDirectory(at: versions, withIntermediateDirectories: true)
        let real = versions.appendingPathComponent("2.1.322")
        try FileManager.default.moveItem(at: fake.bin.appendingPathComponent("claude"), to: real)
        try FileManager.default.createSymbolicLink(at: fake.bin.appendingPathComponent("claude"), withDestinationURL: real)
        XCTAssertEqual(provider().localHealth(), .ready(detail: "Claude Code 2.1.322 found"))
        // An old one by its path: refused before anything runs.
        let old = versions.appendingPathComponent("2.0.76")
        try FileManager.default.copyItem(at: real, to: old)
        try FileManager.default.removeItem(at: fake.bin.appendingPathComponent("claude"))
        try FileManager.default.createSymbolicLink(at: fake.bin.appendingPathComponent("claude"), withDestinationURL: old)
        XCTAssertEqual(provider().localHealth(),
                       .needsSetup(reason: AIError.unsupportedVersion(found: "2.0.76").message(for: .claudeCode)))
        XCTAssertEqual(fake.calls(), [], "local health started no process")
    }

    func testCheckRecordsItsLaunchesAgainstTheUsersCheck() async throws {
        try install(main: "exit 0")
        let contacts = ContactLog()
        AIEgress.observe { contact, action in contacts.append("\(action.kind.rawValue): \(contact)") }
        defer { AIEgress.observe(nil) }
        let provider = provider()
        _ = provider.localHealth()
        XCTAssertEqual(contacts.all, [])
        _ = await provider.check(pressedCheck)
        XCTAssertEqual(contacts.all, ["check: claude --version", "check: claude auth"])
        XCTAssertEqual(provider.localHealth(), .ready(detail: "Claude Code 2.1.322 found"), "the version a check found is remembered")
    }

    func testHealthNeverSaysWho() async throws {
        var behaviour = CLIFakeTool.Behaviour()
        let status = #"{"loggedIn":true,"authMethod":"claude.ai","apiProvider":"firstParty","email":"dana@contoso.example","orgName":"Contoso Ltd","orgId":"org-123"}"#
        behaviour.authStatus = "printf '%s\\n' \(CLIFakeTool.quoted(status)); exit 0"
        try fake.install("claude", behaviour)
        let health = await provider().check(pressedCheck)
        XCTAssertEqual(health, .ready(detail: "Claude Code 2.1.322 · signed in with claude.ai"))
        for secret in ["dana", "contoso", "Contoso", "org-123"] {
            XCTAssertFalse(health.words.contains(secret), secret)
        }
    }

    func testHealthWhenSignedOut() async throws {
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.authStatus = CLIFakeTool.replay("cli/claude-auth-status-signed-out.json", status: 1)
        try fake.install("claude", behaviour)
        let health = await provider().check(pressedCheck)
        XCTAssertEqual(health, .needsSetup(reason: "Claude Code is signed out. Run claude in Terminal."))
    }

    func testHealthWhenTheCLIDoesNotAnswer() async throws {
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.authStatus = "exec /bin/sleep 30"
        try fake.install("claude", behaviour)
        var limits = CLIFakeTool.fastLimits
        limits.quick = .seconds(1)
        let health = await provider(limits: limits).check(pressedCheck)
        XCTAssertEqual(health, .unavailable(reason: AIError.timedOut.message(for: .claudeCode)))
    }
}
