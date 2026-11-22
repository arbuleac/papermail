import Foundation

/// Why a write ended without an error.
public enum AIStop: String, Sendable, Hashable {
    /// The model finished its reply.
    case done
    /// The output cap cut the reply short; the text so far stands.
    case maxTokens
    /// The model declined (Anthropic `stop_reason: "refusal"`, an OpenAI refusal part). Providers report it here;
    /// `AIWriter` turns it into `AIError.refused`, so the UI only ever sees it as a failure.
    case refused
    /// The user stopped it (Stop, Esc), or the card closed.
    case cancelled
}
