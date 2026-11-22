import Foundation
import PaperCore

/// Builds the provider Settings › AI chose. The app hands `provider(for:)` to `AIWriter` as its resolver in the real
/// environment; demo mode and tests resolve to their own writer instead. Building a provider sends nothing and reads no
/// key: providers read the key store only when they are about to send.
public struct AIProviderFactory: Sendable {
    public let keys: any AIKeyStoring
    /// Shared by the API providers: ephemeral, no cache, no cookies (`makeSession()`). Tests pass a session whose
    /// configuration routes to a stub `URLProtocol`.
    public let session: URLSession
    public let runner: CLIProcessRunner

    public init(keys: any AIKeyStoring, session: URLSession = AIProviderFactory.makeSession(),
                runner: CLIProcessRunner = CLIProcessRunner()) {
        self.keys = keys
        self.session = session
        self.runner = runner
    }

    /// The provider for `configuration`; nil for `.demo`, which the app supplies itself.
    public func provider(for configuration: AIProviderConfiguration) -> (any AIProvider)? {
        let model = configuration.resolvedModel
        switch configuration.kind {
        case .claudeAPI:
            return AnthropicMessagesProvider(model: model, keys: keys, session: session)
        case .openAIAPI:
            return OpenAIResponsesProvider(model: model, keys: keys, session: session)
        case .claudeCode:
            return ClaudeCodeProvider(model: model, executablePath: configuration.cliPath, runner: runner)
        case .codex:
            return CodexProvider(model: model, executablePath: configuration.cliPath, runner: runner)
        case .demo:
            return nil
        }
    }

    /// A session that keeps nothing: no URL cache (responses are mail), no cookie store, and no waiting for a network
    /// that is not there (the card says “No connection” at once).
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        // Idle time between bytes: the APIs send pings while a model thinks, so a minute of silence is a dead stream.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 130
        return URLSession(configuration: configuration)
    }
}
