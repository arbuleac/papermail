import Foundation
import SSCore

/// GPT through the OpenAI Responses API with the user's key: `POST /v1/responses`, streamed (SSE), `store: false`.
///
/// STUB (step 1 of the build): compiles under its final name and initializer so the factory, the app and the tests
/// can be written against it. The API track replaces the body: request building (always `store: false`), `SSEParser`
/// streaming, error mapping to `AIError` (429 `insufficient_quota` is `noCredit`), and `GET /v1/models` in `check()`.
public struct OpenAIResponsesProvider: AIProvider {
    public let kind: AIProviderKind = .openAIAPI
    /// The API model id (`AIProviderConfiguration.resolvedModel`); nil means `gpt-6.1-terra`.
    let model: String?
    /// Read at send time only, never at construction: reading the key can show the Keychain prompt.
    let keys: any AIKeyStoring
    let session: URLSession

    public init(model: String?, keys: any AIKeyStoring, session: URLSession) {
        self.model = model
        self.keys = keys
        self.session = session
    }

    public func health() async -> AIHealth {
        .unavailable(reason: "Not built yet")
    }

    public func write(_ request: AIWriteRequest) -> AsyncThrowingStream<AIWriteEvent, Error> {
        AsyncThrowingStream { $0.finish(throwing: AIError.unavailable) }
    }
}
