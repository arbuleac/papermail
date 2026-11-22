import Foundation
import PaperCore

/// The Responses API's stream in steps (openai.md §2). `response.output_text.delta` appends; `response.output_text.done`
/// is the part's authoritative text and replaces only when it differs from what streamed. A refusal part ends the
/// write at once and its words never reach the field. `response.completed` finishes with usage; `response.incomplete`
/// is a cut (`max_output_tokens`) or a filter (`content_filter`, a refusal); `response.failed` and `error` fail.
/// Everything else (created, in_progress, reasoning items, content parts, a `[DONE]` some proxies add) is skipped.
struct OpenAIStreamDecoder: HTTPStreamDecoding {
    /// One output text part: a message item can carry several, and a reasoning item may come first.
    private struct Part: Hashable {
        let item: String
        let content: Int
    }

    private var parts: [Part] = []
    private var texts: [Part: String] = [:]

    init() {}

    mutating func decode(_ event: SSEEvent) -> [HTTPStreamStep] {
        if event.data.trimmingCharacters(in: .whitespaces) == "[DONE]" { return [] }
        guard let object = HTTPJSON.object(event.data) else {
            return [.fail(.badResponse(code: 0), retryable: false)]
        }
        switch object["type"] as? String ?? event.event {
        case "response.output_text.delta":
            guard let delta = object["delta"] as? String, !delta.isEmpty else { return [] }
            let part = Self.part(of: object)
            if texts[part] == nil { parts.append(part) }
            texts[part, default: ""] += delta
            return [.emit(.text(delta))]
        case "response.output_text.done":
            guard let text = object["text"] as? String else { return [] }
            let part = Self.part(of: object)
            if texts[part] == nil { parts.append(part) }
            guard texts[part] != text else { return [] }
            texts[part] = text
            return [.emit(.replaceAll(parts.map { texts[$0] ?? "" }.joined()))]
        case "response.refusal.delta", "response.refusal.done":
            return [.finish(.refused)]
        case "response.completed":
            return usage(in: object) + [.finish(.done)]
        case "response.incomplete":
            let details = HTTPJSON.dictionary(HTTPJSON.dictionary(object["response"])?["incomplete_details"])
            let stop: AIStop = details?["reason"] as? String == "content_filter" ? .refused : .maxTokens
            return usage(in: object) + [.finish(stop)]
        case "response.failed":
            let error = HTTPJSON.dictionary(HTTPJSON.dictionary(object["response"])?["error"])
            let mapped = OpenAIErrorMapping.mapStreamError(code: HTTPJSON.string(error?["code"]), type: HTTPJSON.string(error?["type"]))
            return [.fail(mapped.error, retryable: mapped.retryable)]
        case "error":
            // Documented flat (`code` beside `type: "error"`); some servers nest it under `error` as the HTTP body does.
            let nested = HTTPJSON.dictionary(object["error"])
            let code = HTTPJSON.string(object["code"]) ?? HTTPJSON.string(nested?["code"])
            let mapped = OpenAIErrorMapping.mapStreamError(code: code, type: HTTPJSON.string(nested?["type"]))
            return [.fail(mapped.error, retryable: mapped.retryable)]
        default:
            return []
        }
    }

    mutating func streamEnded() -> [HTTPStreamStep] {
        // Every reply ends with a terminal event; a stream without one was cut.
        [.fail(.badResponse(code: 0), retryable: true)]
    }

    private static func part(of object: [String: Any]) -> Part {
        Part(item: object["item_id"] as? String ?? "", content: HTTPJSON.int(object["content_index"]) ?? 0)
    }

    private func usage(in object: [String: Any]) -> [HTTPStreamStep] {
        guard let usage = HTTPJSON.dictionary(HTTPJSON.dictionary(object["response"])?["usage"]) else { return [] }
        let input = HTTPJSON.int(usage["input_tokens"])
        let output = HTTPJSON.int(usage["output_tokens"])
        guard input != nil || output != nil else { return [] }
        return [.emit(.usage(AIUsage(inputTokens: input, outputTokens: output)))]
    }
}
