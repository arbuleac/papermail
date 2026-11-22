import Foundation
import PaperCore

/// What a provider's decoder makes of one server-sent event.
enum HTTPStreamStep: Sendable, Equatable {
    /// Pass this on to the reader (`.text`, `.replaceAll`, `.usage`).
    case emit(AIWriteEvent)
    /// The reply is over.
    case finish(AIStop)
    /// The reply failed. `retryable` failures are asked for again once, if no text has been shown yet.
    case fail(AIError, retryable: Bool)
}

/// One API's server-sent events turned into steps. `HTTPStreamingWrite` makes a fresh decoder for every attempt.
protocol HTTPStreamDecoding {
    init()
    mutating func decode(_ event: SSEEvent) -> [HTTPStreamStep]
    /// The connection closed: what to make of what arrived. A reply that never said it was over is a failure the
    /// writer may retry, since a cut connection looks the same.
    mutating func streamEnded() -> [HTTPStreamStep]
}
