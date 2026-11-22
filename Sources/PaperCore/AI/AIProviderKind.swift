import Foundation

/// The four ways Help Me Write can reach a model, plus the demo's canned writer. Stored in AppSettings by raw value,
/// so the raw values never change; consent and the Keychain item are keyed by it too.
public enum AIProviderKind: String, Sendable, Codable, CaseIterable {
    /// The Anthropic Messages API with the user's API key.
    case claudeAPI
    /// The user's own Claude Code CLI and its sign-in.
    case claudeCode
    /// The OpenAI Responses API with the user's API key.
    case openAIAPI
    /// The user's own Codex CLI and its sign-in.
    case codex
    /// Canned text streamed on this Mac (demo mode, tests and snapshots). Never offered in Settings.
    case demo

    /// The choices Settings › AI offers, in popup order: grouped by destination, API key before sign-in.
    public static let selectable: [AIProviderKind] = [.claudeAPI, .claudeCode, .openAIAPI, .codex]

    public var destination: AIDestination {
        switch self {
        case .claudeAPI, .claudeCode: return .anthropic
        case .openAIAPI, .codex: return .openAI
        case .demo: return .thisMac
        }
    }

    /// The product name: popup titles, the source line for CLIs, error and status words.
    public var displayName: String {
        switch self {
        case .claudeAPI: return "Claude"
        case .claudeCode: return "Claude Code"
        case .openAIAPI: return "OpenAI"
        case .codex: return "Codex"
        case .demo: return "Demo"
        }
    }

    /// Whether the provider needs an API key from the Keychain (`AIKeyStoring`).
    public var usesAPIKey: Bool { self == .claudeAPI || self == .openAIAPI }

    /// The CLI's executable name, searched for in the standard folders; nil for the others.
    public var executableName: String? {
        switch self {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        default: return nil
        }
    }

    /// Settings' Model popup, default first. The API ids are the ones verified for this build (docs: SPEC §2); the
    /// CLIs take their own aliases and default to the CLI's own choice, so no model flag is passed for it.
    public var modelChoices: [AIModelChoice] {
        switch self {
        case .claudeAPI:
            return [
                AIModelChoice(model: "claude-opus-5-5", title: "Claude Opus 5.5"),
                AIModelChoice(model: "claude-sonnet-5-5", title: "Claude Sonnet 5.5"),
                AIModelChoice(model: "claude-haiku-5-5", title: "Claude Haiku 5.5"),
            ]
        case .openAIAPI:
            return [
                AIModelChoice(model: "gpt-6.1-terra", title: "GPT-6.1 Terra"),
                AIModelChoice(model: "gpt-6.2-sol", title: "GPT-6.2 Sol"),
                AIModelChoice(model: "gpt-6.2-astra", title: "GPT-6.2 Astra"),
                AIModelChoice(model: "gpt-6-luna", title: "GPT-6 Luna"),
            ]
        case .claudeCode:
            return [
                AIModelChoice(model: nil, title: "Default"),
                AIModelChoice(model: "opus", title: "Opus"),
                AIModelChoice(model: "sonnet", title: "Sonnet"),
                AIModelChoice(model: "haiku", title: "Haiku"),
            ]
        case .codex:
            return [
                AIModelChoice(model: nil, title: "Default"),
                AIModelChoice(model: "gpt-6-luna", title: "GPT-6 Luna"),
                AIModelChoice(model: "gpt-6.1-terra", title: "GPT-6.1 Terra"),
                AIModelChoice(model: "gpt-6.2-sol", title: "GPT-6.2 Sol"),
            ]
        case .demo:
            return [AIModelChoice(model: nil, title: "Default")]
        }
    }

    /// The model used when the user has not chosen one, or chose one this build no longer offers.
    public var defaultModel: String? { modelChoices.first?.model }

    /// The breadcrumb word for this kind. A `StaticString`, so a crash report can carry it (CrashReporting takes only
    /// names from the code).
    public var breadcrumbName: StaticString {
        switch self {
        case .claudeAPI: return "claudeAPI"
        case .claudeCode: return "claudeCode"
        case .openAIAPI: return "openAIAPI"
        case .codex: return "codex"
        case .demo: return "demo"
        }
    }
}
