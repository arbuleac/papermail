import Foundation
import PaperCore

/// The Messages API's stream (`message_start`, `content_block_*`, `message_delta`, `message_stop`, `ping`, `error`)
/// in steps. Only `text` blocks reach the field: `thinking` blocks (empty, since this build asks for no summaries),
/// their signatures, and the `fallback` blocks that mark where a declined model handed over are skipped. A fallback
/// continues the text already streamed (the API passes the partial text to the fallback model as its start, and never
/// takes streamed content back), so the next text block simply appends.
struct AnthropicStreamDecoder: HTTPStreamDecoding {
    private var blockTypes: [Int: String] = [:]
    private var stopReason: String?
    private var inputTokens: Int?
    private var outputTokens: Int?

    init() {}

    mutating func decode(_ event: SSEEvent) -> [HTTPStreamStep] {
        guard let object = HTTPJSON.object(event.data) else {
            return [.fail(.badResponse(code: 0), retryable: false)]
        }
        switch object["type"] as? String ?? event.event {
        case "message_start":
            if let usage = HTTPJSON.dictionary(HTTPJSON.dictionary(object["message"])?["usage"]) { read(usage) }
            return []
        case "content_block_start":
            guard let index = HTTPJSON.int(object["index"]), let block = HTTPJSON.dictionary(object["content_block"]),
                  let type = block["type"] as? String else { return [] }
            blockTypes[index] = type
            if type == "text", let text = block["text"] as? String, !text.isEmpty { return [.emit(.text(text))] }
            return []
        case "content_block_delta":
            guard let delta = HTTPJSON.dictionary(object["delta"]), delta["type"] as? String == "text_delta",
                  let text = delta["text"] as? String, !text.isEmpty else { return [] }
            // A text delta belongs to a text block; one that names any other kind of block is not the reply.
            if let index = HTTPJSON.int(object["index"]), let type = blockTypes[index], type != "text" { return [] }
            return [.emit(.text(text))]
        case "message_delta":
            if let reason = HTTPJSON.dictionary(object["delta"])?["stop_reason"] as? String { stopReason = reason }
            if let usage = HTTPJSON.dictionary(object["usage"]) { read(usage) }
            return []
        case "message_stop":
            return ending()
        case "error":
            let mapped = AnthropicErrorMapping.mapStreamError(type: HTTPJSON.dictionary(object["error"])?["type"] as? String)
            return [.fail(mapped.error, retryable: mapped.retryable)]
        default:
            // ping, content_block_stop, and whatever a later API version adds.
            return []
        }
    }

    mutating func streamEnded() -> [HTTPStreamStep] {
        // A stop reason without `message_stop` is a reply whose last event was lost to the close: it is complete.
        guard stopReason != nil else { return [.fail(.badResponse(code: 0), retryable: true)] }
        return ending()
    }

    private func ending() -> [HTTPStreamStep] {
        var steps: [HTTPStreamStep] = []
        if inputTokens != nil || outputTokens != nil {
            steps.append(.emit(.usage(AIUsage(inputTokens: inputTokens, outputTokens: outputTokens))))
        }
        steps.append(.finish(Self.stop(for: stopReason)))
        return steps
    }

    /// `end_turn` and `stop_sequence` finish the reply; `max_tokens` and a full context window cut it short; `refusal`
    /// is the model or its safety classifier declining (after any fallback model declined too).
    static func stop(for reason: String?) -> AIStop {
        switch reason {
        case "max_tokens", "model_context_window_exceeded": return .maxTokens
        case "refusal": return .refused
        default: return .done
        }
    }

    /// `message_start` carries the input count, `message_delta` the running output count (cumulative, so the last wins).
    private mutating func read(_ usage: [String: Any]) {
        if let input = HTTPJSON.int(usage["input_tokens"]) { inputTokens = input }
        if let output = HTTPJSON.int(usage["output_tokens"]) { outputTokens = output }
    }
}
