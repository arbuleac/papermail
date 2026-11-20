import XCTest
import SSCore
@testable import SSAI

/// The two parsers on their own, over the recorded lines, and the version gate's arithmetic.
final class CLIReplyParserTests: XCTestCase {
    private let version = CLIVersion(2, 1, 322)

    private func exit(_ status: CLIExit.Status = .exited(0), timedOut: Bool = false, stderr: String = "",
                      kept: String? = nil) -> CLIExit {
        CLIExit(status: status, timedOut: timedOut, stderr: Data(stderr.utf8), keptFile: kept.map { Data($0.utf8) })
    }

    private func lines(_ fixture: String) throws -> [Data] {
        try FixtureFiles.string(fixture).split(separator: "\n").map { Data($0.utf8) }
    }

    /// A recorded Claude Code run as the recipe's isolation gives it (`FixtureFiles.isolatedClaude`).
    private func isolatedLines(_ fixture: String) throws -> [Data] {
        try FixtureFiles.isolatedClaude(fixture).split(separator: "\n").map { Data($0.utf8) }
    }

    private func steps<Parser: CLIReplyParser>(_ parser: inout Parser, _ lines: [Data]) -> [CLIReplyStep] {
        lines.flatMap { parser.consume($0) }
    }

    // MARK: Claude Code

    func testClaudeCodesRecordedRun() throws {
        var parser = ClaudeCodeStream()
        XCTAssertEqual(steps(&parser, try isolatedLines("cli/claude-stream.jsonl")), [
            .event(.text("Thanks, Thursday")), .event(.text(" works.")),
            .event(.usage(AIUsage(inputTokens: 687, outputTokens: 13))), .finished(.done),
        ])
        XCTAssertEqual(parser.shown, "Thanks, Thursday works.")
    }

    func testClaudeCodesRecordedFailuresNeverShowTheirText() throws {
        for (fixture, error) in [("cli/claude-signed-out.jsonl", AIError.signedOut), ("cli/claude-bad-model.jsonl", .modelUnavailable)] {
            var parser = ClaudeCodeStream()
            XCTAssertEqual(steps(&parser, try isolatedLines(fixture)), [.failed(error)], fixture)
            XCTAssertEqual(parser.shown, "", fixture)
        }
    }

    func testClaudeCodesInitLineMustShowTheUsersOwnSignInAndNoPluginOfTheirs() throws {
        let recorded = try lines("cli/claude-stream.jsonl")[1]
        var parser = ClaudeCodeStream()
        XCTAssertEqual(parser.consume(recorded), [.abort(.badResponse(code: 0))], "the user's swift-lsp plugin, as recorded")
        let isolated = try isolatedLines("cli/claude-stream.jsonl")[1]
        parser = ClaudeCodeStream()
        XCTAssertEqual(parser.consume(isolated), [], "built-in plugins only")
        for source in ["ANTHROPIC_API_KEY", "apiKeyHelper", "/login managed key"] {
            let line = String(decoding: isolated, as: UTF8.self)
                .replacingOccurrences(of: #""apiKeySource":"none""#, with: #""apiKeySource":"\#(source)""#)
            parser = ClaudeCodeStream()
            XCTAssertEqual(parser.consume(Data(line.utf8)), [.abort(.otherSignIn)], source)
        }
    }

    func testClaudeCodeWithoutAResultLine() {
        var parser = ClaudeCodeStream()
        _ = parser.consume(Data(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}}"#.utf8))
        XCTAssertEqual(parser.finish(exit(), version: version), [.finished(.done)])
        XCTAssertEqual(ClaudeCodeStream().finishing(exit(.exited(1), stderr: "error: unknown option '--safe-mode'\n"), version),
                       [.failed(.newerVersion(found: "2.1.322"))])
        XCTAssertEqual(ClaudeCodeStream().finishing(exit(.exited(1), stderr: "Error: Input must be provided"), version),
                       [.failed(.badResponse(code: 1))])
        XCTAssertEqual(ClaudeCodeStream().finishing(exit(.signaled(SIGSEGV)), version), [.failed(.badResponse(code: 139))])
        XCTAssertEqual(ClaudeCodeStream().finishing(exit(.signaled(SIGTERM), timedOut: true), version), [.failed(.timedOut)])
    }

    func testClaudeCodeErrorWordsAndStatuses() {
        func failure(_ error: String?, status: Int?) -> [CLIReplyStep] {
            var parser = ClaudeCodeStream()
            var assistant: [String: Any] = ["type": "assistant", "is_api_error_message": true,
                                            "message": ["model": "<synthetic>", "content": [["type": "text", "text": "MAIL-MARKER"]]]]
            if let error { assistant["error"] = error }
            if let status { assistant["api_error_status"] = status }
            let result: [String: Any] = ["type": "result", "subtype": "success", "is_error": true, "api_error_status": status ?? NSNull()]
            return [assistant, result].flatMap { parser.consume(try! JSONSerialization.data(withJSONObject: $0)) }
        }
        XCTAssertEqual(failure("authentication_failed", status: nil), [.failed(.signedOut)])
        XCTAssertEqual(failure("billing_error", status: nil), [.failed(.planLimit)])
        XCTAssertEqual(failure("rate_limit", status: 429), [.failed(.planLimit)])
        XCTAssertEqual(failure("unknown", status: 401), [.failed(.signedOut)])
        XCTAssertEqual(failure("unknown", status: 404), [.failed(.modelUnavailable)])
        XCTAssertEqual(failure("unknown", status: 529), [.failed(.overloaded)])
        XCTAssertEqual(failure("unknown", status: 500), [.failed(.badResponse(code: 500))])
        XCTAssertEqual(failure("unknown", status: nil), [], "unexplained: the exit status decides")
    }

    func testClaudeCodesRetriesExplainAFailure() {
        var parser = ClaudeCodeStream()
        _ = parser.consume(Data(#"{"type":"system","subtype":"api_retry","attempt":3,"error":"overloaded"}"#.utf8))
        XCTAssertEqual(parser.consume(Data(#"{"type":"result","subtype":"error_during_execution","is_error":true}"#.utf8)),
                       [.failed(.overloaded)])
    }

    func testLinesThatAreNotJSONAreSkipped() {
        var claude = ClaudeCodeStream()
        XCTAssertEqual(claude.consume(Data("Warning: something on stdout".utf8)), [])
        XCTAssertEqual(claude.consume(Data("[1,2]".utf8)), [])
        var codex = CodexStream()
        XCTAssertEqual(codex.consume(Data("{".utf8)), [])
    }

    // MARK: Codex

    func testCodexsSyntheticRun() throws {
        var parser = CodexStream()
        XCTAssertEqual(steps(&parser, try lines("cli/codex-exec-synthetic.jsonl")), [
            .event(.replaceAll("Thanks, Thursday works.")),
            .event(.usage(AIUsage(inputTokens: 2140, outputTokens: 12))),
            .finished(.done),
        ])
    }

    func testCodexsRecordedSignedOutRun() throws {
        var parser = CodexStream()
        XCTAssertEqual(steps(&parser, try lines("cli/codex-exec-signed-out.jsonl")), [.failed(.signedOut)],
                       "the retry notices and the error item are not terminal")
    }

    func testCodexsFailureWords() {
        let cases: [(String, AIError?)] = [
            ("You've hit your usage limit. Try again at 3:05 PM.", .planLimit),
            ("unexpected status 401 Unauthorized: Missing bearer", .signedOut),
            ("Your access token could not be refreshed. Please log in again.", .signedOut),
            ("The 'gpt-9' model is not supported when using Codex with a ChatGPT account.", .modelUnavailable),
            ("unexpected status 429 Too Many Requests", .rateLimited(retryAfter: nil)),
            ("unexpected status 503 Service Unavailable", .overloaded),
            ("stream disconnected before completion: error sending request for url", .offline),
            ("unexpected status 418 I'm a teapot", nil),
        ]
        for (message, error) in cases {
            XCTAssertEqual(CodexStream.error(for: message), error, message)
        }
        XCTAssertEqual(CodexStream.httpStatus(in: "unexpected status 403 Forbidden: nope"), 403)
        XCTAssertNil(CodexStream.httpStatus(in: "no status here"))
        var parser = CodexStream()
        XCTAssertEqual(parser.consume(Data(#"{"type":"turn.failed","error":{"message":"unexpected status 403 Forbidden"}}"#.utf8)),
                       [.failed(.badResponse(code: 403))])
    }

    func testCodexsExit() {
        XCTAssertEqual(CodexStream().finishing(exit(kept: "From the file"), version),
                       [.event(.replaceAll("From the file")), .finished(.done)])
        XCTAssertEqual(CodexStream().finishing(exit(kept: "  \n"), version), [.finished(.done)])
        XCTAssertEqual(CodexStream().finishing(exit(.exited(1), stderr: "Error: Unknown feature flag: shell_tool"), version),
                       [.failed(.newerVersion(found: "2.1.322"))])
        XCTAssertEqual(CodexStream().finishing(exit(.exited(2)), version), [.failed(.badResponse(code: 2))])
        var parser = CodexStream()
        _ = parser.consume(Data(#"{"type":"error","message":"Reconnecting... 5/5 (unexpected status 401 Unauthorized)"}"#.utf8))
        XCTAssertEqual(parser.finish(exit(.exited(1)), version: version), [.failed(.signedOut)],
                       "a run that died without turn.failed is explained by its last notice")
    }

    func testCodexsMessageReplacesNotAppends() {
        var parser = CodexStream()
        XCTAssertEqual(parser.consume(Data(#"{"type":"item.started","item":{"id":"item_1","type":"agent_message","text":""}}"#.utf8)), [])
        XCTAssertEqual(parser.consume(Data(#"{"type":"item.updated","item":{"id":"item_1","type":"agent_message","text":"Thanks"}}"#.utf8)),
                       [.event(.replaceAll("Thanks"))])
        XCTAssertEqual(parser.consume(Data(#"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Thanks, Thursday works."}}"#.utf8)),
                       [.event(.replaceAll("Thanks, Thursday works."))])
        XCTAssertEqual(parser.consume(Data(#"{"type":"item.completed","item":{"id":"item_1","type":"agent_message","text":"Thanks, Thursday works."}}"#.utf8)),
                       [], "the same text twice is one replace")
        for tool in ["command_execution", "file_change", "mcp_tool_call", "web_search", "todo_list", "code_mode_call",
                     "a_type_from_a_later_codex"] {
            for event in ["item.started", "item.updated", "item.completed"] {
                var parser = CodexStream()
                XCTAssertEqual(parser.consume(Data(#"{"type":"\#(event)","item":{"id":"item_2","type":"\#(tool)"}}"#.utf8)),
                               [.abort(.badResponse(code: 0))], "\(event) \(tool): only the message, reasoning and notices pass")
            }
        }
        var untyped = CodexStream()
        XCTAssertEqual(untyped.consume(Data(#"{"type":"item.started","item":{"id":"item_3"}}"#.utf8)), [.abort(.badResponse(code: 0))],
                       "an item without a type fails closed too")
        var reasoning = CodexStream()
        XCTAssertEqual(reasoning.consume(Data(#"{"type":"item.completed","item":{"id":"item_0","type":"reasoning","text":"…"}}"#.utf8)), [])
        XCTAssertEqual(reasoning.consume(Data(#"{"type":"item.completed","item":{"id":"item_1","type":"error","message":"notice"}}"#.utf8)), [])
    }

    // MARK: Versions

    func testVersionsAsTheCLIsPrintThem() {
        XCTAssertEqual(CLIVersion(parsing: "2.1.322 (Claude Code)"), CLIVersion(2, 1, 322))
        XCTAssertEqual(CLIVersion(parsing: "codex-cli 0.163.0\n"), CLIVersion(0, 163, 0))
        XCTAssertEqual(CLIVersion(parsing: "v3 build 12, version 1.4"), CLIVersion(1, 4))
        XCTAssertEqual(CLIVersion(parsing: "1.2.3-beta.4"), CLIVersion(1, 2, 3))
        XCTAssertNil(CLIVersion(parsing: "version 7"))
        XCTAssertNil(CLIVersion(parsing: ""))
        XCTAssertNil(CLIVersion(parsing: "1."))
        XCTAssertEqual(CLIVersion(parsing: "99999999999999999999.1")?.components.count, 2, "no overflow")
        XCTAssertEqual(CLIVersion(parsing: "2.1.322")?.description, "2.1.322")
    }

    func testVersionOrder() {
        XCTAssertLessThan(CLIVersion(2, 1, 321), CLIVersion(2, 1, 322))
        XCTAssertLessThan(CLIVersion(2, 1, 322), CLIVersion(2, 2))
        XCTAssertLessThan(CLIVersion(0, 999), CLIVersion(1))
        XCTAssertEqual(CLIVersion(3), CLIVersion(3, 0, 0))
        XCTAssertEqual(Set([CLIVersion(3), CLIVersion(3, 0)]).count, 1)
        XCTAssertFalse(CLIVersion(3) < CLIVersion(3, 0, 0))
    }

    func testTheTestedRanges() {
        let claude = ClaudeCodeProvider.tool
        XCTAssertTrue(claude.supports(CLIVersion(2, 1, 322)))
        XCTAssertTrue(claude.supports(CLIVersion(2, 9, 1)))
        XCTAssertFalse(claude.supports(CLIVersion(2, 1, 321)))
        XCTAssertFalse(claude.supports(CLIVersion(3, 0, 0)))
        let codex = CodexProvider.tool
        XCTAssertTrue(codex.supports(CLIVersion(0, 163, 0)))
        XCTAssertTrue(codex.supports(CLIVersion(0, 180, 2)))
        XCTAssertFalse(codex.supports(CLIVersion(0, 162, 9)))
        XCTAssertFalse(codex.supports(CLIVersion(1, 0, 0)))
        XCTAssertEqual(codex.refusal(of: CLIVersion(0, 163, 0)), .toolsStayOn(found: "0.163.0"), "no Codex runs with its tools on")
        XCTAssertEqual(codex.refusal(of: CLIVersion(0, 999, 9)), .toolsStayOn(found: "0.999.9"))
        XCTAssertEqual(codex.refusal(of: CLIVersion(0, 162)), .unsupportedVersion(found: "0.162"))
        XCTAssertEqual(codex.refusal(of: CLIVersion(1, 0)), .newerVersion(found: "1.0"))
        XCTAssertNil(claude.refusal(of: CLIVersion(2, 1, 322)))
    }
}

private extension CLIReplyParser {
    /// `finish` on a fresh copy, for one-line checks.
    func finishing(_ exit: CLIExit, _ version: CLIVersion) -> [CLIReplyStep] {
        var parser = self
        return parser.finish(exit, version: version)
    }
}
