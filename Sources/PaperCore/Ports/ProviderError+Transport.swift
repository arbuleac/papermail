import Foundation

extension ProviderError {
    /// Starts the message of a `network` failure met before the request left this Mac. Still a network failure to
    /// every rule that reads one (backoff, "Offline" on the sync line), but a send that failed so can go again: the
    /// provider never saw it, where after any other failure it may already have delivered the message.
    static let notSentPrefix = "not sent: "

    /// Failures of a connection that was never made: no name, no host listening. Nothing of the request can have left.
    static let neverConnectedCodes: Set<URLError.Code> = [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed]

    /// No usable network. URLSession reports these before a connection is tried, and also for a request already on
    /// its way when the interface goes down (ENETDOWN): its body may have reached the server whole, the reply lost.
    /// So they say "not sent" only when the task's metrics show no byte of the request left this Mac.
    static let noNetworkCodes: Set<URLError.Code> = [.notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff]

    /// What a failed transfer means to the engine: a cancellation, or a network failure, marked as one that never left
    /// this Mac when the connection was never made, or when there was no network and `bytesSent` (the request's header
    /// and body bytes the task sent, `SentBytesProbe`) is zero. Unknown (nil), it may have left.
    public static func transport(_ error: URLError, bytesSent: Int64? = nil) -> ProviderError {
        if error.code == .cancelled { return .cancelled }
        let neverLeft = neverConnectedCodes.contains(error.code) || (noNetworkCodes.contains(error.code) && bytesSent == 0)
        return neverLeft ? notSent(error.localizedDescription) : .network(error.localizedDescription)
    }

    /// A network failure before the request left this Mac: the connection was never made, or the token it needed could
    /// not be fetched.
    public static func notSent(_ reason: String) -> ProviderError {
        .network(notSentPrefix + reason)
    }

    /// Whether this failure came before the request left this Mac, so nothing reached the provider.
    public var neverLeftThisMac: Bool {
        guard case .network(let message) = self else { return false }
        return message.hasPrefix(Self.notSentPrefix)
    }
}
