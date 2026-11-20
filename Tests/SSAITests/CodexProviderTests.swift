import XCTest
import SSCore
@testable import SSAI

/// Codex through a fake `codex` (cli.md §C): the login check before every send, the feature names checked once per
/// version, the recipe, and the recorded and synthetic runs.
final class CodexProviderTests: XCTestCase {
    private var fake: CLIFakeTool!
    private let request = AIWriteRequest(
        instructions: "You write the reply body only.\nSay \"no\" to nothing \\ invent nothing.\tPlain text.",
        transcript: "<<<CONVERSATION 1a2b3c4d>>>\nDana: MAIL-MARKER-4711 Can we meet Thursday?\n<<<END CONVERSATION 1a2b3c4d>>>",
        task: "Instruction: TASK-MARKER-0815 say Thursday works", model: nil)

    override func setUpWithError() throws {
        fake = try CLIFakeTool()
    }

    override func tearDown() {
        fake.remove()
        fake = nil
    }

    /// Codex as if its version kept no tool on, so the recipe runs against the fake (`toolFree`); the real provider
    /// refuses every version so far (`testNoCodexRunsWhileItKeepsToolsOn`).
    private func provider(model: String? = nil, limits: CLILimits = CLIFakeTool.fastLimits) -> CodexProvider {
        CodexProvider(model: model, executablePath: nil, runner: fake.runner(limits: limits), tool: Self.toolFree)
    }

    private static let toolFree: CLITool = {
        var tool = CodexProvider.tool
        tool.keepsToolsOn = []
        return tool
    }()

    private func behaviour(main: String, version: String = "codex-cli 0.163.0") -> CLIFakeTool.Behaviour {
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.version = "printf '%s\\n' \(CLIFakeTool.quoted(version)); exit 0"
        behaviour.loginStatus = "printf '%s\\n' 'Logged in using ChatGPT' >&2; exit 0"
        behaviour.featuresList = CLIFakeTool.replay("cli/codex-features-list-synthetic.txt")
        behaviour.main = main
        return behaviour
    }

    private func install(main: String, version: String = "codex-cli 0.163.0") throws {
        try fake.install("codex", behaviour(main: main, version: version))
    }

    private func write(_ provider: CodexProvider, _ request: AIWriteRequest? = nil) async -> ([AIWriteEvent], AIError?) {
        let (events, error) = await collectCLIWrite(provider.write(request ?? self.request))
        return (events, error.map { $0 as? AIError ?? .badResponse(code: -1) })
    }

    // MARK: The recipe

    func testTheRecipeAndTheWholeMessageAtTheEnd() async throws {
        try install(main: CLIFakeTool.replay("cli/codex-exec-synthetic.jsonl"))
        let (events, error) = await write(provider())
        XCTAssertNil(error)
        XCTAssertEqual(events, [
            .replaceAll("Thanks, Thursday works."),
            .usage(AIUsage(inputTokens: 2140, outputTokens: 12)),
            .finished(.done),
        ])
        let folder = try XCTUnwrap(fake.recorded("cwd")).trimmingCharacters(in: .newlines)
        var expected = [
            "exec", "--json", "--ephemeral", "--skip-git-repo-check", "--ignore-user-config", "--ignore-rules",
            "--strict-config", "-C", folder, "-s", "read-only",
        ]
        for setting in [
            #"model_reasoning_effort="low""#, #"web_search="disabled""#, "mcp_servers={}", "project_doc_max_bytes=0",
            #"approval_policy="never""#, "analytics.enabled=false", "feedback.enabled=false",
            "check_for_update_on_startup=false", #"history.persistence="none""#, #"otel.exporter="none""#,
            #"shell_environment_policy.inherit="none""#, "include_environment_context=false",
            "include_permissions_instructions=false", "include_apps_instructions=false", "skills.include_instructions=false",
            #"developer_instructions="You write the reply body only.\nSay \"no\" to nothing \\ invent nothing.\tPlain text.""#,
        ] {
            expected += ["-c", setting]
        }
        for feature in CodexProvider.disabledFeatures { expected += ["--disable", feature] }
        expected += ["--output-last-message", folder + "/last-message.txt", "-"]
        var arguments = try fake.arguments()
        // The folder as given (/var/…) and as the fake sees it (/private/var/…) are the same place.
        if let index = arguments.firstIndex(of: "-C") { arguments[index + 1] = CLIFakeTool.realPath(arguments[index + 1]) }
        if let index = arguments.firstIndex(of: "--output-last-message") {
            arguments[index + 1] = CLIFakeTool.realPath((arguments[index + 1] as NSString).deletingLastPathComponent) + "/last-message.txt"
        }
        XCTAssertEqual(arguments, expected)
        XCTAssertEqual(CodexProvider.disabledFeatures.count, 28)
        XCTAssertEqual(fake.recorded("stdin"), request.userTurn)
        XCTAssertFalse(try fake.arguments().contains { $0.contains("MARKER") }, "the mail and the ask never go in argv")
        XCTAssertNil(try fake.environment()["OPENAI_API_KEY"])
        XCTAssertEqual(try fake.environment()["USER"], "someone")
        XCTAssertEqual(fake.calls(), ["--version", "features list", "login status", "exec --json"])
        XCTAssertEqual(fake.leftoverFolders(), [])
    }

    func testAChosenModelIsPassed() async throws {
        try install(main: CLIFakeTool.replay("cli/codex-exec-synthetic.jsonl"))
        _ = await write(provider(model: "gpt-6-luna"))
        let arguments = try fake.arguments()
        let model = try XCTUnwrap(arguments.firstIndex(of: "-m"))
        XCTAssertEqual(arguments[model + 1], "gpt-6-luna")
        XCTAssertEqual(arguments[model - 1], "read-only")
    }

    func testInstructionsAreATOMLBasicString() {
        XCTAssertEqual(CodexProvider.tomlString("plain"), #""plain""#)
        XCTAssertEqual(CodexProvider.tomlString("a \"b\" c\\d"), #""a \"b\" c\\d""#)
        XCTAssertEqual(CodexProvider.tomlString("one\ntwo\r\tthree"), #""one\ntwo\r\tthree""#)
        XCTAssertEqual(CodexProvider.tomlString("bell\u{07}\u{08}\u{0C}\u{7F}"), #""bell\u0007\b\f\u007F""#)
        XCTAssertEqual(CodexProvider.tomlString("Grüße — “quoted” 🙂"), "\"Grüße — “quoted” 🙂\"")
        XCTAssertEqual(CodexProvider.tomlString("'''"), #""'''""#)
    }

    // MARK: Signed in, before every send

    func testSignedOutSendsNothing() async throws {
        var behaviour = behaviour(main: CLIFakeTool.replay("cli/codex-exec-signed-out.jsonl", status: 1))
        behaviour.loginStatus = "/bin/cat \(CLIFakeTool.quoted(FixtureFiles.url("cli/codex-login-status-signed-out.stderr.txt").path)) >&2; exit 1"
        try fake.install("codex", behaviour)
        let (events, error) = await write(provider())
        XCTAssertEqual(error, .signedOut)
        XCTAssertEqual(events, [])
        XCTAssertFalse(fake.calls().contains { $0.hasPrefix("exec") }, "exec would upload the prompt and retry for 17 s")
        XCTAssertNil(fake.recorded("stdin"))
        let health = await provider().health()
        XCTAssertEqual(health, .needsSetup(reason: "Codex is signed out. Run codex login in Terminal."))
    }

    func testTheLoginIsCheckedBeforeEverySendTheFeaturesOncePerVersion() async throws {
        try install(main: CLIFakeTool.replay("cli/codex-exec-synthetic.jsonl"))
        let provider = provider()
        _ = await write(provider)
        _ = await write(provider)
        XCTAssertEqual(fake.calls(), ["--version", "features list", "login status", "exec --json", "login status", "exec --json"])
        try install(main: CLIFakeTool.replay("cli/codex-exec-synthetic.jsonl"), version: "codex-cli 0.170.2")
        _ = await write(provider)
        XCTAssertEqual(fake.calls().suffix(4), ["--version", "features list", "login status", "exec --json"],
                       "an update is checked again")
    }

    func testSignedOutAfterTheCheckStillSaysSignedOut() async throws {
        // The login check passed but the sign-in was refused (expired): the recorded 401 run.
        try install(main: CLIFakeTool.replay("cli/codex-exec-signed-out.jsonl", stderr: "cli/codex-exec-signed-out.stderr.txt", status: 1))
        let (events, error) = await write(provider())
        XCTAssertEqual(error, .signedOut)
        XCTAssertEqual(events, [], "retry notices are not the reply")
    }

    // MARK: Versions and features

    func testARenamedFeatureStopsThatVersion() async throws {
        var behaviour = behaviour(main: CLIFakeTool.replay("cli/codex-exec-synthetic.jsonl"), version: "codex-cli 0.170.0")
        let listing = try FixtureFiles.string("cli/codex-features-list-synthetic.txt")
            .split(separator: "\n").filter { !$0.hasPrefix("shell_tool ") }.joined(separator: "\n")
        behaviour.featuresList = "printf '%s\\n' \(CLIFakeTool.quoted(listing)); exit 0"
        try fake.install("codex", behaviour)
        let provider = provider()
        let (_, error) = await write(provider)
        XCTAssertEqual(error, .newerVersion(found: "0.170.0"))
        XCTAssertFalse(fake.calls().contains { $0.hasPrefix("exec") || $0 == "login status" })
        let health = await provider.health()
        XCTAssertEqual(health, .needsSetup(reason: "Codex 0.170.0 is newer than this SuperSparrow supports"))
        XCTAssertEqual(fake.calls().filter { $0 == "features list" }.count, 1, "remembered for that file")
    }

    func testVersionsOutsideTheTestedRange() async throws {
        for (version, expected) in [("codex-cli 0.150.0", AIError.unsupportedVersion(found: "0.150.0")),
                                    ("codex-cli 1.2.0", .newerVersion(found: "1.2.0"))] {
            try install(main: CLIFakeTool.replay("cli/codex-exec-synthetic.jsonl"), version: version)
            let (_, error) = await write(provider())
            XCTAssertEqual(error, expected, "too old says update; too new does not")
        }
        XCTAssertFalse(fake.calls().contains("features list"))
        XCTAssertFalse(fake.calls().contains { $0.hasPrefix("exec") })
    }

    // MARK: Tools that stay on

    func testNoCodexRunsWhileItKeepsToolsOn() async throws {
        // 0.163.0 still offers code mode's exec, request_user_input and spawn_agent under the recipe (CodexProvider).
        for version in ["codex-cli 0.163.0", "codex-cli 0.170.2"] {
            fake.remove()
            fake = try CLIFakeTool()
            try install(main: CLIFakeTool.replay("cli/codex-exec-synthetic.jsonl"), version: version)
            let found = String(version.dropFirst("codex-cli ".count))
            let real = CodexProvider(model: nil, executablePath: nil, runner: fake.runner())
            let (events, error) = await write(real)
            XCTAssertEqual(error, .toolsStayOn(found: found), version)
            XCTAssertEqual(events, [], version)
            XCTAssertEqual(fake.calls(), ["--version"], "\(version): no features list, no login status, no exec")
            XCTAssertNil(fake.recorded("stdin"), "\(version): the request never reached the CLI")
            let health = await real.health()
            XCTAssertEqual(health, .needsSetup(reason: "Codex \(found) can't turn its tools off, so Help Me Write doesn't use it"))
            XCTAssertEqual(fake.calls(), ["--version"], "\(version): the verdict is kept for that file")
        }
        XCTAssertTrue(AIError.toolsStayOn(found: "0.163.0").needsSettings, "Settings › AI is where another provider is chosen")
    }

    func testFeatureNamesAreTheFirstColumn() throws {
        let names = CodexProvider.featureNames(in: try FixtureFiles.string("cli/codex-features-list-synthetic.txt"))
        XCTAssertTrue(Set(CodexProvider.disabledFeatures).isSubset(of: names))
        XCTAssertFalse(names.contains("development"), "“under development” is a stage")
        XCTAssertEqual(CodexProvider.featureNames(in: "  name  stage\n\nshell_tool stable true\r\n"), ["name", "shell_tool"])
    }

    // MARK: Failures and fallbacks

    func testThePlansLimit() async throws {
        try install(main: CLIFakeTool.replay("cli/codex-exec-usage-limit-synthetic.jsonl", status: 1))
        let (events, error) = await write(provider())
        XCTAssertEqual(error, .planLimit)
        XCTAssertEqual(events, [])
    }

    func testTheLastMessageFileWhenNoMessageLineCame() async throws {
        try install(main: #"prev=; for argument in "$@"; do if [ "$prev" = --output-last-message ]; then printf '%s' 'Thanks, Thursday works.' > "$argument"; fi; prev=$argument; done; "#
            + CLIFakeTool.emit([#"{"type":"thread.started","thread_id":"t"}"#, #"{"type":"turn.started"}"#,
                                #"{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":5}}"#]))
        let (events, error) = await write(provider())
        XCTAssertNil(error)
        XCTAssertEqual(events, [.usage(AIUsage(inputTokens: 10, outputTokens: 5)), .replaceAll("Thanks, Thursday works."), .finished(.done)])
        XCTAssertEqual(fake.leftoverFolders(), [])
    }

    func testAToolItemEndsTheRunAtOnce() async throws {
        let signals = CLIFakeTool.quoted(fake.spy.appendingPathComponent("signals").path)
        try install(main: #"trap 'echo TERM >> "# + signals + #"; exit 143' TERM; "#
            + #"printf '%s\n' '{"type":"item.started","item":{"id":"item_0","type":"command_execution","command":"ls ~","status":"in_progress"}}'; "#
            + "while :; do /bin/sleep 0.05; done")
        let (_, error) = await write(provider())
        XCTAssertEqual(error, .badResponse(code: 0))
        let ended = await fake.wait { fake.recorded("signals") == "TERM\n" && fake.leftoverFolders().isEmpty }
        XCTAssertTrue(ended)
    }

    func testARejectedConfigKeyMeansThisVersionDoesNotFit() async throws {
        try install(main: "printf '%s\\n' 'Error: unknown configuration field `include_apps_instructions`' >&2; exit 1",
                    version: "codex-cli 0.171.0")
        let (_, error) = await write(provider())
        XCTAssertEqual(error, .newerVersion(found: "0.171.0"))
    }

    func testCancellingEndsTheProcess() async throws {
        let signals = CLIFakeTool.quoted(fake.spy.appendingPathComponent("signals").path)
        let ready = CLIFakeTool.quoted(fake.spy.appendingPathComponent("ready").path)
        try install(main: #"trap 'echo TERM >> "# + signals + #"; exit 143' TERM; echo yes > "# + ready + "; "
            + #"printf '%s\n' '{"type":"turn.started"}'; while :; do /bin/sleep 0.05; done"#)
        let provider = provider()
        let request = request
        let consumer = Task { await collectCLIWrite(provider.write(request)) }
        // Running, its trap set: the request was read in full.
        let started = await fake.wait { fake.recorded("ready") == "yes\n" }
        XCTAssertTrue(started)
        consumer.cancel()
        _ = await consumer.value
        let ended = await fake.wait { fake.recorded("signals") == "TERM\n" && fake.leftoverFolders().isEmpty }
        XCTAssertTrue(ended)
    }

    // MARK: Health

    func testHealthSaysVersionAndHowItIsSignedIn() async throws {
        try install(main: "exit 0")
        let health = await provider().health()
        XCTAssertEqual(health, .ready(detail: "Codex 0.163.0 · signed in with ChatGPT"))
        XCTAssertEqual(fake.calls(), ["--version", "features list", "login status"])
    }

    func testHealthNeverRepeatsWhatLoginStatusPrints() async throws {
        var behaviour = behaviour(main: "exit 0")
        behaviour.loginStatus = "printf '%s\\n' 'Logged in using an API key - sk-proj-***ABCD' >&2; exit 0"
        try fake.install("codex", behaviour)
        let health = await provider().health()
        XCTAssertEqual(health, .ready(detail: "Codex 0.163.0 · signed in"))
    }

    func testHealthWhenNotFound() async {
        let health = await provider().health()
        XCTAssertEqual(health, .needsSetup(reason: AIHealth.notFoundWords(for: .codex)))
        XCTAssertFalse(health.words.contains("Choose"), "the row's Choose… and the card's Open Settings… are the actions")
    }
}
