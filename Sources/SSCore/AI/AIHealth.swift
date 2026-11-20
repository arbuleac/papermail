import Foundation

/// Whether a provider can write right now, in words Settings › AI's status line and the card show as they are.
/// The words are fixed text plus versions and model names, never anything a CLI printed about the user (no email,
/// no organisation).
public enum AIHealth: Sendable, Hashable {
    /// Can write. “Ready · Claude Opus 5.5”, “Claude Code 2.1.322 · signed in with claude.ai”.
    case ready(detail: String)
    /// The user can fix it in Settings: “Add your API key”, “Claude Code is signed out. Run claude in Terminal.”
    case needsSetup(reason: String)
    /// Nothing the user can do in Settings fixes it now: “No connection”, “Not built yet”.
    case unavailable(reason: String)

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// The status line's words, whatever the state.
    public var words: String {
        switch self {
        case .ready(let detail): return detail
        case .needsSetup(let reason), .unavailable(let reason): return reason
        }
    }
}
