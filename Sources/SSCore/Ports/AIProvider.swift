import Foundation

/// One way to reach a model for Help Me Write: the port the SSAI adapters (Anthropic and OpenAI over URLSession,
/// Claude Code and Codex as processes) and the app's demo writer implement. The UI never calls one: it goes through
/// `AIWriter`, which applies the permission, one write per field, the deadline and the error mapping.
///
/// Nothing reaches the network or starts a process without an `AIUserAction` (spec §3b): `localHealth` looks only at
/// this Mac, and `check` and `write` take the action that allowed them. A provider sends nothing until `write`'s
/// stream is iterated, and sends only the request's fields.
public protocol AIProvider: Sendable {
    var kind: AIProviderKind { get }
    /// Where the request goes; `kind.destination` unless a provider says otherwise (the demo writer: this Mac).
    var destination: AIDestination { get }

    /// Whether it looks ready, from this Mac alone: a key is stored (its attributes, never its data, so no Keychain
    /// prompt), the CLI is there and executable, the version its path or an earlier check showed. No network, no process:
    /// Settings › AI's status as it opens and whether the reply's text shows Help me write's marks come from here.
    func localHealth() -> AIHealth

    /// The user's Check (or a key just saved): an API provider makes its cheapest authenticated call (`GET /v1/models`,
    /// which sends the key and nothing else); a CLI provider runs its version and sign-in checks. Defaults to
    /// `localHealth()`.
    func check(_ action: AIUserAction) async -> AIHealth

    /// Streams one reply. Yields `.text` / `.replaceAll` / `.usage` in order, then exactly one `.finished`, or throws one
    /// `AIError`. Cancelling the consuming task (the stream's termination) cancels the URLSession task or ends the
    /// process. Nothing is sent before the stream is iterated.
    func write(_ request: AIWriteRequest, action: AIUserAction) -> AsyncThrowingStream<AIWriteEvent, Error>
}

extension AIProvider {
    public var destination: AIDestination { kind.destination }

    public func check(_ action: AIUserAction) async -> AIHealth { localHealth() }
}
