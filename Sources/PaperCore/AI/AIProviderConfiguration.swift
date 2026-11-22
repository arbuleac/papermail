import Foundation

/// What Settings › AI chose, as the factory and the writer need it. The app builds one from AppSettings when the user
/// presses Write (PaperCore cannot see AppSettings); the API key is not part of it, it stays in the Keychain until the
/// provider reads it for the request.
public struct AIProviderConfiguration: Sendable, Hashable, Codable {
    public var kind: AIProviderKind
    /// The model the user picked; nil, or an id this build no longer offers, means the kind's default.
    public var model: String?
    /// The CLI the user chose with Choose…; nil means search ~/.local/bin, /opt/homebrew/bin and /usr/local/bin.
    public var cliPath: String?

    public init(kind: AIProviderKind, model: String? = nil, cliPath: String? = nil) {
        self.kind = kind
        self.model = model
        self.cliPath = cliPath
    }

    /// The model to send: the chosen one when this build still offers it, else the default. Nil for a CLI's default,
    /// for which no model flag is passed.
    public var resolvedModel: String? {
        if let model, kind.modelChoices.contains(where: { $0.model == model }) { return model }
        return kind.defaultModel
    }

    /// The card's source line (spec §1.2): the model and its company for an API (“Claude Opus 5.5 · Anthropic”), the
    /// CLI and its company otherwise (“Claude Code · Anthropic”). AI text is always attributed in the card.
    public var sourceLine: String {
        let name: String
        if kind.usesAPIKey {
            let model = resolvedModel
            name = kind.modelChoices.first { $0.model == model }?.title ?? kind.displayName
        } else {
            name = kind.displayName
        }
        return "\(name) · \(kind.destination.displayName)"
    }
}
