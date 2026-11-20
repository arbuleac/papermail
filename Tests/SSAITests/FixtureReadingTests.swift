import XCTest
import SSCore

/// The core's line reader over the recorded CLI runs, in the chunks a pipe might hand over, and the facts the providers
/// build on (cli.md): which lines carry text, and that the final lines repeat it whole.
final class FixtureReadingTests: XCTestCase {
    private func objects(_ path: String, chunk: Int) throws -> [[String: Any]] {
        let data = try FixtureFiles.data(path)
        var reader = JSONLineReader()
        var lines: [Data] = []
        var index = data.startIndex
        while index < data.endIndex {
            let end = data.index(index, offsetBy: chunk, limitedBy: data.endIndex) ?? data.endIndex
            lines += reader.feed(data[index..<end])
            index = end
        }
        lines += reader.finish()
        return try lines.map { try XCTUnwrap(JSONSerialization.jsonObject(with: $0) as? [String: Any]) }
    }

    func testEveryJSONLFixtureReadsWhateverTheChunks() throws {
        for path in FixtureFiles.all() where path.hasSuffix(".jsonl") {
            let whole = try objects(path, chunk: .max / 2)
            XCTAssertFalse(whole.isEmpty, path)
            for chunk in [1, 7, 512] {
                let read = try objects(path, chunk: chunk)
                XCTAssertEqual(read.map { $0["type"] as? String }, whole.map { $0["type"] as? String }, "\(path) in \(chunk)-byte chunks")
            }
        }
    }

    func testClaudeCodesDeltasAddUpToTheRepeatedFinalText() throws {
        let lines = try objects("cli/claude-stream.jsonl", chunk: 64)
        XCTAssertEqual(lines.count, 13)
        let deltas = lines.compactMap { line -> String? in
            guard line["type"] as? String == "stream_event", let event = line["event"] as? [String: Any],
                  let delta = event["delta"] as? [String: Any], delta["type"] as? String == "text_delta" else { return nil }
            return delta["text"] as? String
        }
        XCTAssertEqual(deltas, ["Thanks, Thursday", " works."])
        let result = try XCTUnwrap(lines.last)
        XCTAssertEqual(result["type"] as? String, "result")
        XCTAssertEqual(result["is_error"] as? Bool, false)
        XCTAssertEqual(result["result"] as? String, deltas.joined(), "the result repeats the text: replace, never append")
    }

    func testClaudeCodesFailuresSaySuccessButAreErrors() throws {
        for (path, error) in [("cli/claude-bad-model.jsonl", "model_not_found"), ("cli/claude-signed-out.jsonl", "authentication_failed")] {
            let lines = try objects(path, chunk: 100)
            let assistant = try XCTUnwrap(lines.first { $0["type"] as? String == "assistant" })
            XCTAssertEqual(assistant["error"] as? String, error, path)
            let result = try XCTUnwrap(lines.last)
            XCTAssertEqual(result["subtype"] as? String, "success", path)
            XCTAssertEqual(result["is_error"] as? Bool, true, path)
            XCTAssertEqual(result["terminal_reason"] as? String, "api_error", path)
        }
    }

    func testCodexSignedOutEndsInTurnFailed() throws {
        let lines = try objects("cli/codex-exec-signed-out.jsonl", chunk: 33)
        XCTAssertEqual(lines.first?["type"] as? String, "thread.started")
        XCTAssertEqual(lines.last?["type"] as? String, "turn.failed")
        XCTAssertEqual(lines.filter { $0["type"] as? String == "turn.failed" }.count, 1, "the top-level errors are retry notices")
    }

    func testTheOpenAIErrorBodiesParse() throws {
        for path in ["openai/401-missing-key.json", "openai/401-invalid-key.json", "openai/401-invalid-key-stream.txt"] {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: FixtureFiles.data(path)) as? [String: Any])
            let error = try XCTUnwrap(body["error"] as? [String: Any], path)
            XCTAssertEqual(error["type"] as? String, "invalid_request_error", path)
        }
    }
}
