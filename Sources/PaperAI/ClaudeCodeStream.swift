import Foundation
import PaperCore

/// Claude Code's `stream-json` lines (cli.md §B.3) as write events. `text_delta`s stream; the `assistant` and `result`
/// lines repeat the whole text, so they only replace it when it differs. Failures arrive as a synthetic `assistant`
/// line (its text is the CLI's error message, never shown) and a `result` that says `subtype: "success"` with
/// `is_error: true`, so the decision rests on `is_error`, the `error` value and `api_error_status`.
struct ClaudeCodeStream: CLIReplyParser {
    /// Content blocks that mean a tool ran, although `--tools ""` turns every tool off.
    static let toolBlocks: Set<String> = ["tool_use", "server_tool_use", "mcp_tool_use"]

    /// What the field shows so far.
    private(set) var shown = ""
    /// The synthetic assistant line's `error` (`authentication_failed`, `model_not_found`, `rate_limit`…).
    private var failure: String?
    private var failureStatus: Int?
    /// An `api_retry` line's `error`, in case the retries run out without a synthetic line.
    private var retryFailure: String?
    private var rateLimitRejected = false
    private var stopReason: String?
    /// A `result` said `is_error` with nothing to tell why: the exit status decides.
    private var resultFailed = false

    mutating func consume(_ line: Data) -> [CLIReplyStep] {
        guard let object = CLIJSON.object(line), let type = object["type"] as? String else { return [] }
        switch type {
        case "stream_event":
            return streamEvent(object["event"] as? [String: Any] ?? [:])
        case "assistant":
            return assistant(object)
        case "rate_limit_event":
            if (object["rate_limit_info"] as? [String: Any])?["status"] as? String == "rejected" { rateLimitRejected = true }
            return []
        case "system":
            switch object["subtype"] as? String {
            case "init":
                return initialized(object)
            case "api_retry":
                if let error = object["error"] as? String { retryFailure = error }
            default:
                break
            }
            return []
        case "result":
            return result(object)
        default:
            return []
        }
    }

    mutating func finish(_ exit: CLIExit, version: CLIVersion) -> [CLIReplyStep] {
        if exit.timedOut { return [.failed(.timedOut)] }
        if case .signaled = exit.status { return [.failed(.badResponse(code: exit.code))] }
        if failure != nil || failureStatus != nil, let error = classifiedFailure() { return [.failed(error)] }
        if exit.status == .exited(0), !resultFailed {
            switch stopReason {
            case "max_tokens": return [.finished(.maxTokens)]
            case "refusal": return [.finished(.refused)]
            default: return [.finished(.done)]
            }
        }
        if CLIStderr.rejectsArguments(exit.stderr) { return [.failed(.newerVersion(found: version.description))] }
        return [.failed(classifiedFailure() ?? .badResponse(code: exit.code))]
    }

    // MARK: Lines

    /// The init line, about 0.2 s in and before the request leaves (`status: requesting` follows it): the run must use
    /// the user's own sign-in, not an API key from anywhere (`apiKeySource` other than `none`), and none of the user's
    /// plugins (whose hooks would see the request), which the recipe's isolation leaves out. Claude Code's own built-in
    /// plugins (`path: "builtin"`) come with every run. Otherwise the run ends here: a second line of defence, since
    /// the request may already be leaving as this line is read.
    private func initialized(_ object: [String: Any]) -> [CLIReplyStep] {
        if let source = object["apiKeySource"], source as? String != "none" { return [.abort(.otherSignIn)] }
        let plugins = object["plugins"] as? [Any] ?? []
        let usersOwn = plugins.contains { plugin in
            ((plugin as? [String: Any])?["path"] as? String) != "builtin"
        }
        return usersOwn ? [.abort(.badResponse(code: 0))] : []
    }

    private mutating func streamEvent(_ event: [String: Any]) -> [CLIReplyStep] {
        switch event["type"] as? String {
        case "content_block_start":
            let block = event["content_block"] as? [String: Any]
            if let type = block?["type"] as? String, Self.toolBlocks.contains(type) { return [.abort(.badResponse(code: 0))] }
        case "content_block_delta":
            let delta = event["delta"] as? [String: Any]
            if delta?["type"] as? String == "text_delta", let text = delta?["text"] as? String, !text.isEmpty {
                shown += text
                return [.event(.text(text))]
            }
        case "message_delta":
            if let reason = (event["delta"] as? [String: Any])?["stop_reason"] as? String { stopReason = reason }
        default:
            break
        }
        return []
    }

    private mutating func assistant(_ object: [String: Any]) -> [CLIReplyStep] {
        let message = object["message"] as? [String: Any] ?? [:]
        if object["error"] != nil || object["is_api_error_message"] as? Bool == true || message["model"] as? String == "<synthetic>" {
            failure = object["error"] as? String ?? failure ?? "unknown"
            failureStatus = CLIJSON.int(object["api_error_status"]) ?? failureStatus
            return []
        }
        let content = message["content"] as? [[String: Any]] ?? []
        if content.contains(where: { Self.toolBlocks.contains($0["type"] as? String ?? "") }) {
            return [.abort(.badResponse(code: 0))]
        }
        if let reason = message["stop_reason"] as? String { stopReason = reason }
        guard stopReason != "refusal" else { return [] }
        return replace(with: content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined())
    }

    private mutating func result(_ object: [String: Any]) -> [CLIReplyStep] {
        let usage = Self.usage(object["usage"] as? [String: Any])
        if let reason = object["stop_reason"] as? String { stopReason = reason }
        let isError = object["is_error"] as? Bool ?? (object["subtype"] as? String != "success")
        if let status = CLIJSON.int(object["api_error_status"]) { failureStatus = status }
        guard isError else {
            if stopReason == "refusal" { return [.finished(.refused)] }
            var steps = replace(with: object["result"] as? String ?? "")
            if let usage { steps.append(.event(.usage(usage))) }
            steps.append(.finished(stopReason == "max_tokens" ? .maxTokens : .done))
            return steps
        }
        if failure == "max_output_tokens", shown.contains(where: { !$0.isWhitespace }) {
            return [.finished(.maxTokens)]
        }
        if let error = classifiedFailure() { return [.failed(error)] }
        resultFailed = true
        return []
    }

    // MARK: Decisions

    /// Shows `text` as the whole reply unless the field already ends with it (a later block repeated alone).
    private mutating func replace(with text: String) -> [CLIReplyStep] {
        guard !text.isEmpty, text != shown, !shown.hasSuffix(text) else { return [] }
        shown = text
        return [.event(.replaceAll(text))]
    }

    /// The error the lines explain, if they do. Claude Code is the user's plan: its 402/429 are the plan's limit.
    private func classifiedFailure() -> AIError? {
        switch failure ?? retryFailure {
        case "authentication_failed", "oauth_org_not_allowed": return .signedOut
        case "model_not_found": return .modelUnavailable
        case "rate_limit", "billing_error": return .planLimit
        case "overloaded", "overloaded_error": return .overloaded
        default: break
        }
        if let status = failureStatus {
            switch status {
            case 401, 403: return .signedOut
            case 402, 429: return .planLimit
            case 404: return .modelUnavailable
            case 529: return .overloaded
            default: return .badResponse(code: status)
            }
        }
        if rateLimitRejected { return .planLimit }
        return nil
    }

    static func usage(_ usage: [String: Any]?) -> AIUsage? {
        guard let usage else { return nil }
        let input = ["input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"].compactMap { CLIJSON.int(usage[$0]) }
        let output = CLIJSON.int(usage["output_tokens"])
        guard !input.isEmpty || output != nil else { return nil }
        return AIUsage(inputTokens: input.isEmpty ? nil : input.reduce(0, +), outputTokens: output)
    }
}
