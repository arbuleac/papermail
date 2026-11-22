import XCTest
import PaperCore
@testable import PaperAI

/// The process rules every CLI write follows (SPEC §3), checked against a fake executable: the request on stdin and
/// never in argv, stdin closed, a minimal environment without API keys, a private folder removed afterwards, the
/// timeouts with SIGTERM then SIGKILL, and cancellation ending the process.
final class CLIProcessRunnerTests: XCTestCase {
    private var fake: CLIFakeTool!

    override func setUpWithError() throws {
        fake = try CLIFakeTool()
    }

    override func tearDown() {
        fake.remove()
        fake = nil
    }

    private func command(_ executable: URL, arguments: [String] = ["-p", "--fixed"], input: String? = nil,
                         environment: [String: String] = [:], keepFile: String? = nil,
                         idle: Duration = .seconds(10), total: Duration = .seconds(20)) -> CLICommand {
        CLICommand(executable: executable, action: pressedWrite, arguments: { _ in arguments }, environment: environment,
                   input: input.map { Data($0.utf8) }, keepFile: keepFile, idleTimeout: idle, totalTimeout: total)
    }

    private func outputs(_ runner: CLIProcessRunner, _ command: CLICommand) async throws -> (lines: [String], exit: CLIExit?) {
        var lines: [String] = []
        var exit: CLIExit?
        for try await output in runner.run(command) {
            switch output {
            case .line(let line): lines.append(String(decoding: line, as: UTF8.self))
            case .exit(let ended): exit = ended
            }
        }
        return (lines, exit)
    }

    // MARK: What the CLI is given

    func testTheRequestGoesToStdinThenStdinClosesAndArgvNeverHoldsIt() async throws {
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.main = CLIFakeTool.emit([#"{"type":"done"}"#])
        let executable = try fake.install("claude", behaviour)
        let request = "Dana wrote: MAIL-MARKER-4711 about Thursday\nNotes: say yes"
        let (lines, exit) = try await outputs(fake.runner(), command(executable, input: request))
        // The fake reads stdin to its end before answering: it answered, so stdin was closed.
        XCTAssertEqual(lines, [#"{"type":"done"}"#])
        XCTAssertEqual(exit?.status, .exited(0))
        XCTAssertEqual(exit?.timedOut, false)
        XCTAssertEqual(fake.recorded("stdin"), request)
        XCTAssertEqual(try fake.arguments(), ["-p", "--fixed"])
        XCTAssertFalse(try fake.arguments().contains { $0.contains("MAIL-MARKER") })
    }

    func testALargeRequestArrivesWhole() async throws {
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.main = CLIFakeTool.emit(["{}"])
        let executable = try fake.install("claude", behaviour)
        let request = String(repeating: "Ünïcode mail line, well past a pipe's 64 KB buffer.\n", count: 12_000)
        let (_, exit) = try await outputs(fake.runner(), command(executable, input: request))
        XCTAssertEqual(exit?.status, .exited(0))
        XCTAssertEqual(fake.recorded("stdin"), request)
    }

    func testACLIThatNeverReadsItsInputDoesNotHurtTheApp() async throws {
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.readsInput = false
        behaviour.main = "exit 3"
        let executable = try fake.install("claude", behaviour)
        // Far more than the pipe holds: the write fails with EPIPE, which must not raise SIGPIPE in this process.
        let request = String(repeating: "x", count: 2 << 20)
        let (lines, exit) = try await outputs(fake.runner(), command(executable, input: request))
        XCTAssertEqual(lines, [])
        XCTAssertEqual(exit?.status, .exited(3))
        XCTAssertEqual(exit?.code, 3)
    }

    func testTheEnvironmentIsMinimalAndHoldsNoAPIKey() async throws {
        let parentKeys = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "OPENAI_API_KEY", "CODEX_API_KEY"]
        for key in parentKeys { setenv(key, "sk-parent-secret-\(key)", 1) }
        defer { for key in parentKeys { unsetenv(key) } }
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.main = "exit 0"
        let executable = try fake.install("claude", behaviour)
        _ = try await outputs(fake.runner(), command(executable, input: "hi",
                                                      environment: ["DISABLE_TELEMETRY": "1", "OPENAI_API_KEY": "sk-listed",
                                                                    "ANTHROPIC_API_KEY": "sk-ant-listed"]))
        let environment = try fake.environment()
        let cwd = try XCTUnwrap(fake.recorded("cwd")).trimmingCharacters(in: .newlines)
        XCTAssertEqual(environment["HOME"], fake.home.path)
        XCTAssertEqual(environment["USER"], "someone", "without USER, Claude Code cannot find its sign-in")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(environment["PATH"], "/usr/bin:/bin:" + fake.bin.path)
        XCTAssertEqual(CLIFakeTool.realPath(environment["TMPDIR"] ?? ""), cwd)
        XCTAssertEqual(environment["DISABLE_TELEMETRY"], "1")
        for key in parentKeys { XCTAssertNil(environment[key], key) }
        XCTAssertFalse(environment.values.contains { $0.contains("sk-") })
        // Only what the runner set, plus what /bin/sh itself exports.
        let allowed: Set<String> = ["HOME", "USER", "LANG", "PATH", "TMPDIR", "DISABLE_TELEMETRY", "PWD", "OLDPWD", "SHLVL", "_"]
        XCTAssertEqual(Set(environment.keys).subtracting(allowed), [])
    }

    func testEachRunHasItsOwnEmptyPrivateFolderRemovedAfterwards() async throws {
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.main = "printf 'scratch' > notes.txt; /bin/mkdir -p sub/deeper; exit 0"
        let executable = try fake.install("claude", behaviour)
        _ = try await outputs(fake.runner(), command(executable, input: "hi"))
        let cwd = try XCTUnwrap(fake.recorded("cwd")).trimmingCharacters(in: .newlines)
        XCTAssertEqual(URL(fileURLWithPath: cwd).deletingLastPathComponent().path, fake.temporary.path)
        XCTAssertTrue(URL(fileURLWithPath: cwd).lastPathComponent.hasPrefix("paper-ai-"))
        XCTAssertEqual(fake.recorded("mode")?.trimmingCharacters(in: .newlines), "700")
        XCTAssertEqual(fake.recorded("listing"), "", "the folder starts empty")
        XCTAssertEqual(fake.leftoverFolders(), [], "and is removed with what the CLI left in it")
    }

    func testAKeptFileComesBackBeforeTheFolderGoes() async throws {
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.main = "printf 'Thanks, Thursday works.' > last.txt; exit 0"
        let executable = try fake.install("codex", behaviour)
        let (_, exit) = try await outputs(fake.runner(), command(executable, input: "hi", keepFile: "last.txt"))
        XCTAssertEqual(exit?.keptFile.map { String(decoding: $0, as: UTF8.self) }, "Thanks, Thursday works.")
        XCTAssertEqual(fake.leftoverFolders(), [])
    }

    // MARK: Reading

    func testLinesSplitAcrossWritesArriveWhole() async throws {
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.main = #"printf '{"a":'; /bin/sleep 0.1; printf '1}\n\n{"b":2}\r\n{"c":'; /bin/sleep 0.1; printf '3}'; exit 0"#
        let executable = try fake.install("claude", behaviour)
        let (lines, exit) = try await outputs(fake.runner(), command(executable, input: "hi"))
        XCTAssertEqual(lines, [#"{"a":1}"#, #"{"b":2}"#, #"{"c":3}"#])
        XCTAssertEqual(exit?.status, .exited(0))
    }

    func testStderrKeepsOnlyItsLast8KB() async throws {
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.main = "i=0; while [ $i -lt 400 ]; do printf '%s\\n' 'a fifty-byte line of diagnostics, quoting the mail' >&2; i=$((i + 1)); done; printf 'THE-END' >&2; exit 1"
        let executable = try fake.install("claude", behaviour)
        let (_, exit) = try await outputs(fake.runner(), command(executable, input: "hi"))
        let stderr = try XCTUnwrap(exit?.stderr)
        XCTAssertEqual(stderr.count, 8 * 1024)
        XCTAssertTrue(String(decoding: stderr, as: UTF8.self).hasSuffix("THE-END"))
    }

    func testAHelperHoldingThePipesDoesNotHoldTheRun() async throws {
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.main = #"/bin/sleep 4 & printf '{"type":"done"}\n'; exit 0"#
        let executable = try fake.install("claude", behaviour)
        let started = Date()
        let (lines, exit) = try await outputs(fake.runner(), command(executable, input: "hi"))
        XCTAssertEqual(lines, [#"{"type":"done"}"#])
        XCTAssertEqual(exit?.status, .exited(0))
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "stops reading shortly after the CLI exits")
    }

    /// Whether the process `pid` names still runs.
    private func isRunning(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno == EPERM
    }

    private func recordedPID(_ name: String) -> pid_t? {
        fake.recorded(name).flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func testAHelperGoesWithTheCLI() async throws {
        let helper = CLIFakeTool.quoted(fake.spy.appendingPathComponent("helper").path)
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.main = "/bin/sleep 30 & echo $! > \(helper); printf '{\"type\":\"done\"}\\n'; exit 0"
        let executable = try fake.install("claude", behaviour)
        let (_, exit) = try await outputs(fake.runner(), command(executable, input: "hi"))
        XCTAssertEqual(exit?.status, .exited(0))
        let pid = try XCTUnwrap(recordedPID("helper"))
        let gone = await fake.wait(timeout: 3) { !self.isRunning(pid) }
        XCTAssertTrue(gone, "the helper holding the pipes was ended with its CLI, not left with the request")
        XCTAssertEqual(fake.leftoverFolders(), [])
    }

    func testATimeoutEndsTheCLIsHelpersToo() async throws {
        let helper = CLIFakeTool.quoted(fake.spy.appendingPathComponent("helper").path)
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.main = "/bin/sleep 30 > /dev/null 2>&1 & echo $! > \(helper); printf '{\"type\":\"init\"}\\n'; exec /bin/sleep 30"
        let executable = try fake.install("claude", behaviour)
        let (_, exit) = try await outputs(fake.runner(), command(executable, input: "hi", idle: .seconds(2)))
        XCTAssertEqual(exit?.timedOut, true)
        let pid = try XCTUnwrap(recordedPID("helper"))
        let gone = await fake.wait(timeout: 3) { !self.isRunning(pid) }
        XCTAssertTrue(gone, "SIGTERM went to the CLI's whole group, its helper among it")
    }

    func testEndAllEndsEveryRunAtOnceEvenOneIgnoringSIGTERM() async throws {
        let signals = CLIFakeTool.quoted(fake.spy.appendingPathComponent("signals").path)
        let ready = CLIFakeTool.quoted(fake.spy.appendingPathComponent("ready").path)
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.main = #"trap 'echo TERM >> "# + signals + #"' TERM; echo yes > "# + ready
            + #"; printf '{"type":"init"}\n'; while :; do /bin/sleep 0.05; done"#
        let executable = try fake.install("claude", behaviour)
        let runner = fake.runner()
        let command = command(executable, input: "hi")
        let consumer = Task { try await outputs(runner, command) }
        let started = await fake.wait { fake.recorded("ready") == "yes\n" }
        XCTAssertTrue(started)
        let before = Date()
        await runner.endAll(grace: .milliseconds(200))
        XCTAssertLessThan(Date().timeIntervalSince(before), 1.5, "the app's quit does not wait for the 2-minute limit")
        XCTAssertEqual(runner.running.all.count, 0)
        XCTAssertEqual(fake.leftoverFolders(), [], "its folder went before endAll returned")
        XCTAssertEqual(fake.recorded("signals"), "TERM\n", "SIGTERM first, then SIGKILL")
        let (_, exit) = try await consumer.value
        XCTAssertEqual(exit?.status, .signaled(SIGKILL))
        await runner.endAll()
    }

    /// The app quit while a write was still preparing (its context being built): the run it asks for afterwards starts
    /// nothing, so no CLI outlives the app with the conversation on its stdin.
    func testNothingStartsAfterEndAll() async throws {
        let ran = CLIFakeTool.quoted(fake.spy.appendingPathComponent("ran").path)
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.main = "echo yes > " + ran
        let executable = try fake.install("claude", behaviour)
        let runner = fake.runner()
        await runner.endAll()
        do {
            _ = try await outputs(runner, command(executable, input: "hi"))
            XCTFail("a run asked for after endAll starts nothing")
        } catch {
            XCTAssertEqual(error as? AIError, .cancelled)
        }
        XCTAssertNil(fake.recorded("ran"), "the CLI never ran")
        XCTAssertEqual(fake.leftoverFolders(), [], "and no folder was made for it")
    }

    // MARK: Ending it

    func testSilenceEndsTheProcess() async throws {
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.main = #"printf '{"type":"init"}\n'; exec /bin/sleep 30"#
        let executable = try fake.install("claude", behaviour)
        let started = Date()
        // The idle limit counts from the launch: long enough for the fake to record what it was given, even on a busy Mac.
        let (lines, exit) = try await outputs(fake.runner(), command(executable, input: "hi", idle: .seconds(2)))
        XCTAssertEqual(lines, [#"{"type":"init"}"#])
        XCTAssertEqual(exit?.timedOut, true)
        XCTAssertEqual(exit?.status, .signaled(SIGTERM))
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
        XCTAssertEqual(fake.leftoverFolders(), [])
    }

    func testTheTotalLimitEndsAChattyProcess() async throws {
        var behaviour = CLIFakeTool.Behaviour()
        behaviour.main = #"while :; do printf '{"type":"ping"}\n'; /bin/sleep 0.1; done"#
        let executable = try fake.install("claude", behaviour)
        let started = Date()
        let (lines, exit) = try await outputs(fake.runner(), command(executable, input: "hi", idle: .seconds(5),
                                                                      total: .milliseconds(1_500)))
        XCTAssertGreaterThanOrEqual(lines.count, 1)
        XCTAssertEqual(exit?.timedOut, true)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4.5, "the total limit, not the 5 s idle one")
    }

    func testSIGKILLFollowsAnIgnoredSIGTERM() async throws {
        var behaviour = CLIFakeTool.Behaviour()
        let signals = CLIFakeTool.quoted(fake.spy.appendingPathComponent("signals").path)
        behaviour.main = #"trap 'echo TERM >> "# + signals + #"' TERM; printf '{"type":"init"}\n'; while :; do /bin/sleep 0.05; done"#
        let executable = try fake.install("claude", behaviour)
        let started = Date()
        // The idle limit counts from the launch: long enough for the fake to record what it was given and set its trap.
        let (lines, exit) = try await outputs(fake.runner(), command(executable, input: "hi", idle: .seconds(2)))
        XCTAssertEqual(lines, [#"{"type":"init"}"#])
        XCTAssertEqual(exit?.status, .signaled(SIGKILL))
        XCTAssertEqual(exit?.timedOut, true)
        XCTAssertEqual(exit?.code, 128 + Int(SIGKILL))
        XCTAssertEqual(fake.recorded("signals"), "TERM\n", "SIGTERM first, then SIGKILL after the grace")
        XCTAssertGreaterThan(Date().timeIntervalSince(started), 2.25, "2 s of silence, then the 0.3 s grace")
        XCTAssertEqual(fake.leftoverFolders(), [])
    }

    func testCancellingTheConsumerEndsTheProcess() async throws {
        var behaviour = CLIFakeTool.Behaviour()
        let signals = CLIFakeTool.quoted(fake.spy.appendingPathComponent("signals").path)
        behaviour.main = #"trap 'echo TERM >> "# + signals + #"; exit 143' TERM; printf '{"type":"init"}\n'; while :; do /bin/sleep 0.05; done"#
        let executable = try fake.install("claude", behaviour)
        let runner = fake.runner()
        let command = command(executable, input: "hi")
        let firstLine = expectation(description: "first line")
        let consumer = Task {
            for try await output in runner.run(command) {
                if case .line = output { firstLine.fulfill() }
            }
        }
        await fulfillment(of: [firstLine], timeout: 5)
        consumer.cancel()
        let ended = await fake.wait { fake.leftoverFolders().isEmpty && fake.recorded("signals") == "TERM\n" }
        XCTAssertTrue(ended, "the process got SIGTERM, exited, and its folder went")
    }

    // MARK: Starting it

    func testAMissingExecutableIsNotInstalled() async throws {
        let missing = fake.bin.appendingPathComponent("claude")
        do {
            _ = try await outputs(fake.runner(), command(missing, input: "hi"))
            XCTFail("ran a missing executable")
        } catch {
            XCTAssertEqual(error as? AIError, .notInstalled)
        }
        XCTAssertEqual(fake.leftoverFolders(), [])
    }

    func testTheChosenCLIWinsThenTheStandardFoldersInOrder() throws {
        let runner = fake.runner()
        XCTAssertNil(runner.locate(.claudeCode, chosen: nil))
        let last = try fake.install("claude", in: fake.otherBins[1], .init())
        XCTAssertEqual(runner.locate(.claudeCode, chosen: nil), last)
        let homebrew = try fake.install("claude", in: fake.otherBins[0], .init())
        XCTAssertEqual(runner.locate(.claudeCode, chosen: nil), homebrew)
        // A file that cannot run, and a folder of that name, are passed over.
        try Data("not a program".utf8).write(to: fake.bin.appendingPathComponent("claude"))
        XCTAssertEqual(runner.locate(.claudeCode, chosen: nil), homebrew)
        try FileManager.default.createDirectory(at: fake.bin.appendingPathComponent("codex"), withIntermediateDirectories: true)
        XCTAssertNil(runner.locate(.codex, chosen: nil))
        let chosen = try fake.install("my-claude", in: fake.root, .init())
        XCTAssertEqual(runner.locate(.claudeCode, chosen: chosen.path), chosen)
        XCTAssertEqual(runner.locate(.claudeCode, chosen: fake.root.appendingPathComponent("gone").path), homebrew,
                       "a chosen CLI that is gone falls back to the standard folders")
        XCTAssertNil(runner.locate(.claudeAPI, chosen: nil), "API providers have no CLI")
    }

    func testTheStandardFoldersAreTheSpecs() {
        XCTAssertEqual(CLIProcessRunner.standardFolders(home: "/Users/someone").map(\.path),
                       ["/Users/someone/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"])
    }

    func testFoldersACrashLeftAreSweptOnce() async throws {
        let temporary = fake.root.appendingPathComponent("tmp-sweep", isDirectory: true)
        let stale = temporary.appendingPathComponent("paper-ai-stale", isDirectory: true)
        let fresh = temporary.appendingPathComponent("paper-ai-fresh", isDirectory: true)
        let other = temporary.appendingPathComponent("someone-elses", isDirectory: true)
        for folder in [stale, fresh, other] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let anHourAgo = Date().addingTimeInterval(-3_600)
        for folder in [stale, other] {
            try FileManager.default.setAttributes([.modificationDate: anHourAgo], ofItemAtPath: folder.path)
        }
        let executable = try fake.install("claude", .init())
        let runner = CLIProcessRunner(temporaryDirectory: temporary, limits: CLIFakeTool.fastLimits,
                                      base: CLIBaseEnvironment(home: fake.home.path, user: "someone", language: "en_US.UTF-8"),
                                      searchFolders: [fake.bin])
        _ = try await outputs(runner, command(executable, input: "hi"))
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: temporary.path))
        XCTAssertEqual(left, ["paper-ai-fresh", "someone-elses"])
    }
}
