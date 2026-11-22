import Foundation

/// Where the conversation goes when Help Me Write runs: the company that reads it, which is what consent and the
/// Settings caption name. Claude Code and Codex run on this Mac but send the request on to their company, so they
/// share their API sibling's destination.
public enum AIDestination: String, Sendable, Codable, CaseIterable {
    case anthropic
    case openAI
    /// Nothing leaves the Mac (the demo provider).
    case thisMac

    /// The name the consent sheet, the source line and error words use.
    public var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .openAI: return "OpenAI"
        case .thisMac: return "this Mac"
        }
    }
}
