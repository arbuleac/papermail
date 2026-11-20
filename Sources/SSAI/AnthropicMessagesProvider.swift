import Foundation
import SSCore

/// Claude through the Anthropic Messages API with the user's key: `POST /v1/messages`, streamed (SSE).
///
/// STUB (step 1 of the build): compiles under its final name and initializer so the factory, the app and the tests
/// can be written against it. The API track replaces the body: request building, `SSEParser` streaming, error mapping
/// to `AIError`, one retry before text, and `GET /v1/models` in `check()`.
public struct AnthropicMessagesProvider: AIProvider {
    public let kind: AIProviderKind = .claudeAPI
    /// The API model id (`AIProviderConfiguration.resolvedModel`); nil means `claude-opus-5-5`.
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
