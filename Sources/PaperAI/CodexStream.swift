import Foundation
import PaperCore

/// Codex's `exec --json` lines (cli.md §C.3) as write events. Codex gives whole items, not tokens: the reply arrives
/// once, as an `agent_message`, shown with `.replaceAll`. Top-level `error` lines and `error` items are retry notices;
/// only `turn.failed` (with exit 1) ends in failure. Its message is read for known words to pick the error, and never
/// kept or shown, since it may quote the request.
///
/// The success shapes (`agent_message`, `turn.completed`) follow the documented schema: Codex was not signed in when
/// the fixtures were recorded (`cli/codex-*-synthetic.jsonl`).
struct CodexStream: CLIReplyParser {
    /// The only items a reply may hold: the message, the model's reasoning and error notices. Anything else (a command,
    /// a file change, a tool, code mode's calls, a plan, or a type this build has never seen) ends the run at once,
    /// although the recipe turns every tool off: the guard fails closed, so no tool output, which could hold a file of
    /// this Mac, follows the request to OpenAI.
    static let allowedItems: Set<String> = ["agent_message", "reasoning", "error"]

    /// What the field shows so far.
    private(set) var shown = ""
    /// The last retry notice, for a failure that ends without `turn.failed`.
    private var lastNotice: String?

    mutating func consume(_ line: Data) -> [CLIReplyStep] {
        guard let object = CLIJSON.object(line), let type = object["type"] as? String else { return [] }
        switch type {
        case "item.started", "item.updated", "item.completed":
            guard let item = object["item"] as? [String: Any], let itemType = item["type"] as? String,
                  Self.allowedItems.contains(itemType) else {
                return [.abort(.badResponse(code: 0))]
            }
            guard itemType == "agent_message", type != "item.started", let text = item["text"] as? String else { return [] }
            return replace(with: text)
        case "error":
            lastNotice = object["message"] as? String
            return []
        case "turn.completed":
            var steps: [CLIReplyStep] = []
            if let usage = Self.usage(object["usage"] as? [String: Any]) { steps.append(.event(.usage(usage))) }
            // Without a message yet, the exit brings the last-message file.
            if shown.contains(where: { !$0.isWhitespace }) { steps.append(.finished(.done)) }
            return steps
        case "turn.failed":
            let message = (object["error"] as? [String: Any])?["message"] as? String ?? lastNotice ?? ""
            return [.failed(Self.error(for: message) ?? .badResponse(code: Self.httpStatus(in: message) ?? 1))]
        default:
            return []
        }
    }

    mutating func finish(_ exit: CLIExit, version: CLIVersion) -> [CLIReplyStep] {
        if exit.timedOut { return [.failed(.timedOut)] }
        if case .signaled = exit.status { return [.failed(.badResponse(code: exit.code))] }
        if exit.status == .exited(0) {
            var steps: [CLIReplyStep] = []
            if !shown.contains(where: { !$0.isWhitespace }), let kept = exit.keptFile {
                steps += replace(with: String(decoding: kept, as: UTF8.self))
            }
            steps.append(.finished(.done))
            return steps
        }
        if CLIStderr.rejectsArguments(exit.stderr) { return [.failed(.newerVersion(found: version.description))] }
        if let lastNotice, let error = Self.error(for: lastNotice) { return [.failed(error)] }
        return [.failed(.badResponse(code: exit.code))]
    }

    private mutating func replace(with text: String) -> [CLIReplyStep] {
        guard text.contains(where: { !$0.isWhitespace }), text != shown else { return [] }
        shown = text
        return [.event(.replaceAll(text))]
    }

    /// The error a failure message names, by its words; nil when it names none. The ChatGPT plan's limit comes as “You've
    /// hit your usage limit”, a missing or expired sign-in as HTTP 401.
    static func error(for message: String) -> AIError? {
        let text = message.lowercased()
        if text.contains("usage limit") || text.contains("usage_limit") { return .planLimit }
        if text.contains("401") || text.contains("unauthorized") || text.contains("not logged in")
            || text.contains("log in again") || text.contains("sign in again") {
            return .signedOut
        }
        if text.contains("model"), ["not supported", "does not exist", "not found", "404"].contains(where: text.contains) {
            return .modelUnavailable
        }
        if text.contains("429") || text.contains("too many requests") || text.contains("rate limit") {
            return .rateLimited(retryAfter: nil)
        }
        if text.contains("503") || text.contains("overloaded") || text.contains("service unavailable") { return .overloaded }
        if ["error sending request", "dns error", "connection refused", "network is unreachable", "no route to host"]
            .contains(where: text.contains) {
            return .offline
        }
        return nil
    }

    /// The HTTP status in “unexpected status 403 Forbidden: …”.
    static func httpStatus(in message: String) -> Int? {
        guard let range = message.range(of: #"status (\d{3})\b"#, options: .regularExpression) else { return nil }
        return Int(message[range].dropFirst("status ".count))
    }

    static func usage(_ usage: [String: Any]?) -> AIUsage? {
        guard let usage else { return nil }
        let input = CLIJSON.int(usage["input_tokens"])
        let output = CLIJSON.int(usage["output_tokens"])
        guard input != nil || output != nil else { return nil }
        return AIUsage(inputTokens: input, outputTokens: output)
    }
}
