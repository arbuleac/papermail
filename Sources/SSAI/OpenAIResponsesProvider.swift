import Foundation
import SSCore

/// GPT through the OpenAI Responses API with the user's key: `POST /v1/responses`, streamed (SSE).
///
/// Every request says `store: false`, so OpenAI keeps no application state for it (its 30-day abuse log still
/// applies). The app's fixed instructions go in `instructions` and `AIWriteRequest.userTurn` is the one user input,
/// nothing else of the user's. Reasoning effort is `low` on every model: the GPT-6.2 models reject `none`, and no
/// current model lists `minimal`. No sampling parameters (the GPT-6.x guides say to omit them).
public struct OpenAIResponsesProvider: AIProvider {
    public let kind: AIProviderKind = .openAIAPI
    /// The API model id (`AIProviderConfiguration.resolvedModel`); nil means `gpt-6.1-terra`.
    let model: String?
    /// Read at send time only, never at construction: reading the key can show the Keychain prompt.
    let keys: any AIKeyStoring
    let session: URLSession
    /// The wait before the one retry; tests replace it so they need not sleep.
    var pause: HTTPRetryPolicy.Pause = HTTPRetryPolicy.sleep

    static let responsesURL = URL(string: "https://api.openai.com/v1/responses")!
    static let modelsURL = URL(string: "https://api.openai.com/v1/models")!
    static let defaultModel = "gpt-6.1-terra"
    /// Reasoning counts toward it; a few thousand is plenty for a reply at low effort (openai.md §1).
    static let defaultMaxOutputTokens = 4_000
    /// The API's floor for `max_output_tokens`.
    static let minimumMaxOutputTokens = 16
    static let verbosity = "low"

    public init(model: String?, keys: any AIKeyStoring, session: URLSession) {
        self.model = model
        self.keys = keys
        self.session = session
    }

    var modelID: String { model ?? Self.defaultModel }

    /// `low` everywhere: accepted by every current model, where `none` is a 400 on `gpt-6.2-*` and `minimal` is listed
    /// by none. A function of the model so the rule stays visible (and tested) if a model ever needs another.
    static func reasoningEffort(for model: String) -> String {
        "low"
    }

    /// A key is stored (its attributes only: no Keychain prompt, no network).
    public func localHealth() -> AIHealth {
        HTTPKeyCheck.health(kind: kind, model: modelID, keys: keys)
    }

    public func check(_ action: AIUserAction) async -> AIHealth {
        await HTTPKeyCheck.check(kind: kind, model: modelID, keys: keys, session: session, action: action,
                                 request: { Self.modelsRequest(key: $0) }, mapReply: { OpenAIErrorMapping.map($0) })
    }

    public func write(_ request: AIWriteRequest, action: AIUserAction) -> AsyncThrowingStream<AIWriteEvent, Error> {
        let provider = self
        return HTTPStreamingWrite<OpenAIStreamDecoder>.stream(
            kind: kind, keys: keys, session: session, pause: pause, action: action,
            makeRequest: { try provider.responsesRequest(for: request, key: $0) },
            mapReply: { OpenAIErrorMapping.map($0) })
    }

    // MARK: Requests

    /// `POST /v1/responses`, exactly the body openai.md §1 settles on, with `store: false` always.
    func responsesRequest(for request: AIWriteRequest, key: String) throws -> URLRequest {
        let model = modelID
        let body = ResponsesBody(
            model: model,
            instructions: request.instructions,
            input: [.init(role: "user", content: [.init(type: "input_text", text: request.userTurn)])],
            maxOutputTokens: max(Self.minimumMaxOutputTokens, request.maxOutputTokens ?? Self.defaultMaxOutputTokens),
            store: false,
            reasoning: .init(effort: Self.reasoningEffort(for: model)),
            text: .init(verbosity: Self.verbosity),
            stream: true,
            streamOptions: .init(includeObfuscation: false)
        )
        var urlRequest = URLRequest(url: Self.responsesURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.withoutEscapingSlashes]
        urlRequest.httpBody = try encoder.encode(body)
        return urlRequest
    }

    /// `GET /v1/models`: the key, nothing else.
    static func modelsRequest(key: String) -> URLRequest {
        var urlRequest = URLRequest(url: modelsURL)
        urlRequest.httpMethod = "GET"
        urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        return urlRequest
    }

    private struct ResponsesBody: Encodable {
        struct Message: Encodable {
            let role: String
            let content: [Content]
        }

        struct Content: Encodable {
            let type: String
            let text: String
        }

        struct Reasoning: Encodable {
            let effort: String
        }

        struct TextOptions: Encodable {
            let verbosity: String
        }

        struct StreamOptions: Encodable {
            let includeObfuscation: Bool
        }

        let model: String
        let instructions: String
        let input: [Message]
        let maxOutputTokens: Int
        /// Always false; a stored response would be kept 30 days as application state.
        let store: Bool
        let reasoning: Reasoning
        let text: TextOptions
        let stream: Bool
        let streamOptions: StreamOptions
    }
}
