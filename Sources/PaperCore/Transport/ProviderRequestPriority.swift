import Foundation

/// How soon a provider request should go out, set by the engine around a call (`$current`) and read by the transport
/// when the request is made (`SentBytesProbe` gives its URLSession task this priority). A body the reader is waiting for
/// is `foreground`; the backfill's paced bodies are `background`; everything else keeps URLSession's default.
public enum ProviderRequestPriority: Sendable {
    case background
    case normal
    case foreground

    @TaskLocal public static var current: ProviderRequestPriority = .normal

    /// The `URLSessionTask.priority` this stands for.
    public var taskPriority: Float {
        switch self {
        case .background: return URLSessionTask.lowPriority
        case .normal: return URLSessionTask.defaultPriority
        case .foreground: return URLSessionTask.highPriority
        }
    }
}
