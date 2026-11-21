import Foundation
import SSCore

/// Claude through the Anthropic Messages API with the user's key: `POST /v1/messages`, streamed (SSE).
///
/// The request carries the app's fixed instructions as `system` and `AIWriteRequest.userTurn` as the one user message,
/// nothing else of the user's. On API version 2026-10-21 sampling parameters are rejected, and Opus and Sonnet 5.5
/// reject `thinking` disabled, so neither is sent: `output_config.effort` low keeps a short reply quick. Opus and Sonnet
/// 5.5 opt into the server-side refusal fallback (another model continues when a safety classifier declines); Haiku has
/// none. A refusal that stands ends the stream with `.finished(.refused)`.
public struct AnthropicMessagesProvider: AIProvider {
    public let kind: AIProviderKind = .claudeAPI
    /// The API model id (`AIProviderConfiguration.resolvedModel`); nil means `claude-opus-5-5`.
    let model: String?
    /// Read at send time only, never at construction: reading the key can show the Keychain prompt.
    let keys: any AIKeyStoring
    let session: URLSession
    /// The wait before the one retry; tests replace it so they need not sleep.
    var pause: HTTPRetryPolicy.Pause = HTTPRetryPolicy.sleep

    static let messagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
    /// The models list, all of it on one page (the API's largest), so Check can tell whether the chosen model is in it.
    static let modelsURL = URL(string: "https://api.anthropic.com/v1/models?limit=1000")!
    static let apiVersion = "2026-10-21"
    static let fallbackBeta = "server-side-fallback-2026-07-01"
    static let defaultModel = "claude-opus-5-5"
    /// Thinking counts toward it, so it is not lowballed; a short reply uses a fraction.
    static let defaultMaxTokens = 16_000
    static let effort = "low"
    /// The models with a server-side refusal fallback (`fallbacks: "default"`).
    static let modelsWithFallback: Set<String> = ["claude-opus-5-5", "claude-sonnet-5-5"]

    public init(model: String?, keys: any AIKeyStoring, session: URLSession) {
        self.model = model
        self.keys = keys
        self.session = session
    }

    var modelID: String { model ?? Self.defaultModel }

    /// A key is stored (its attributes only: no Keychain prompt, no network).
    public func localHealth() -> AIHealth {
        HTTPKeyCheck.health(kind: kind, model: modelID, keys: keys)
    }

    public func check(_ action: AIUserAction) async -> AIHealth {
        await HTTPKeyCheck.check(kind: kind, model: modelID, keys: keys, session: session, action: action,
                                 request: { Self.modelsRequest(key: $0) }, mapReply: { AnthropicErrorMapping.map($0) })
    }

    public func write(_ request: AIWriteRequest, action: AIUserAction) -> AsyncThrowingStream<AIWriteEvent, Error> {
        let provider = self
        return HTTPStreamingWrite<AnthropicStreamDecoder>.stream(
            kind: kind, keys: keys, session: session, pause: pause, action: action,
            makeRequest: { try provider.messagesRequest(for: request, key: $0) },
            mapReply: { AnthropicErrorMapping.map($0) })
    }

    // MARK: Requests

    /// `POST /v1/messages`, exactly: model, max_tokens, stream, system, one user message, effort, and the refusal
    /// fallback where the model has one.
    func messagesRequest(for request: AIWriteRequest, key: String) throws -> URLRequest {
        let model = modelID
        let withFallback = Self.modelsWithFallback.contains(model)
        let body = MessagesBody(
            model: model,
            maxTokens: max(1, request.maxOutputTokens ?? Self.defaultMaxTokens),
            stream: true,
            system: request.instructions,
            messages: [.init(role: "user", content: request.userTurn)],
            outputConfig: .init(effort: Self.effort),
            fallbacks: withFallback ? "default" : nil
        )
        var urlRequest = URLRequest(url: Self.messagesURL)
        urlRequest.httpMethod = "POST"
        Self.authorize(&urlRequest, key: key)
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        if withFallback { urlRequest.setValue(Self.fallbackBeta, forHTTPHeaderField: "anthropic-beta") }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.withoutEscapingSlashes]
        urlRequest.httpBody = try encoder.encode(body)
        return urlRequest
    }

    /// `GET /v1/models`: the key and the version, nothing else.
    static func modelsRequest(key: String) -> URLRequest {
        var urlRequest = URLRequest(url: modelsURL)
        urlRequest.httpMethod = "GET"
        authorize(&urlRequest, key: key)
        urlRequest.setValue("application/json", forHTTPHeaderField: "accept")
        return urlRequest
    }

    private static func authorize(_ request: inout URLRequest, key: String) {
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
    }

    private struct MessagesBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct OutputConfig: Encodable {
            let effort: String
        }

        let model: String
        let maxTokens: Int
        let stream: Bool
        let system: String
        let messages: [Message]
        let outputConfig: OutputConfig
        /// Left out (synthesized `Encodable` skips nil) without a fallback: the field needs the beta header.
        let fallbacks: String?
    }
}
