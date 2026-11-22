import Foundation

/// Short descriptions of errors for `lastError` columns and logs. Provider messages are passed through, so
/// callers that log them use `.private`, since a provider could echo something it should not.
enum SyncErrorDescription {
    static func describe(_ error: Error) -> String {
        if let providerError = error as? ProviderError {
            switch providerError {
            case .unauthorized:
                return "unauthorized"
            case .throttled(let retryAfter):
                return retryAfter.map { "throttled (retry after \(Int($0.rounded())) s)" } ?? "throttled"
            case .resetRequired:
                return "reset required"
            case .notFound:
                return "not found"
            case .network(let message):
                return "network: \(message)"
            case .decoding(let message):
                return "decoding: \(message)"
            case .server(let status, let message):
                return "server \(status): \(message)"
            case .cancelled:
                return "cancelled"
            }
        }
        if error is CancellationError { return "cancelled" }
        return String(describing: error)
    }
}
