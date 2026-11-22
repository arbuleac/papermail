import Foundation
import PaperCore

/// The one place PaperAI sends HTTP to Anthropic or OpenAI (spec §3b): every send takes the user's action and records the
/// contact against it (`AIEgress`) before the request leaves. A write's attempts and Settings' key check both come here;
/// `HelpMeWriteEgressTests` fails if any other PaperAI file calls a `URLSession` send.
enum ProviderHTTP {
    /// The whole answer, for the key check's `GET /v1/models`.
    static func data(for request: URLRequest, on session: URLSession, by action: AIUserAction) async throws -> (Data, URLResponse) {
        AIEgress.record(AIEgress.contact(for: request), by: action)
        return try await session.data(for: request)
    }

    /// The answer as it streams, for a write's server-sent events.
    static func bytes(for request: URLRequest, on session: URLSession,
                      by action: AIUserAction) async throws -> (URLSession.AsyncBytes, URLResponse) {
        AIEgress.record(AIEgress.contact(for: request), by: action)
        return try await session.bytes(for: request)
    }
}
