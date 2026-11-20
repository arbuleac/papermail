import Foundation

/// One way to reach a model for Help Me Write: the port the SSAI adapters (Anthropic and OpenAI over URLSession,
/// Claude Code and Codex as processes) and the app's demo writer implement. The UI never calls one: it goes through
/// `AIWriter`, which applies consent, one write per field, the deadline and the error mapping.
///
/// A provider sends nothing until `write` is called and its stream is iterated, and sends only the request's fields.
public protocol AIProvider: Sendable {
    var kind: AIProviderKind { get }
    /// Where the request goes; `kind.destination` unless a provider says otherwise (the demo writer: this Mac).
    var destination: AIDestination { get }

    /// Whether it can write now, cheaply and without sending mail: a key is stored, the CLI is found, at a supported
    /// version, signed in. Called when Settings › AI opens or the provider changes, never on the launch path.
    func health() async -> AIHealth

    /// The deeper check the user asks for with Settings' Check button: an API provider makes its cheapest
    /// authenticated call (`GET /v1/models`, which sends the key and nothing else). Defaults to `health()`.
    func check() async -> AIHealth

    /// Streams one reply. Yields `.text` / `.replaceAll` / `.usage` in order, then exactly one `.finished`, or throws one
    /// `AIError`. Cancelling the consuming task (the stream's termination) cancels the URLSession task or ends the
    /// process. Nothing is sent before the stream is iterated.
    func write(_ request: AIWriteRequest) -> AsyncThrowingStream<AIWriteEvent, Error>
}

extension AIProvider {
    public var destination: AIDestination { kind.destination }

    public func check() async -> AIHealth { await health() }
}
