import Foundation

extension ProviderError {
    /// Starts the message of a `network` failure met before the request left this Mac. Still a network failure to
    /// every rule that reads one (backoff, "Offline" on the sync line), but a send that failed so can go again: the
    /// provider never saw it, where after any other failure it may already have delivered the message.
    static let notSentPrefix = "not sent: "

    /// Connection failures no byte of the request got past: no network, no route, no name, no host listening.
    static let unsentCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .dataNotAllowed,
        .internationalRoamingOff,
    ]

    /// What a failed transfer means to the engine: a cancellation, or a network failure, marked as one that never left
    /// this Mac when the connection was never made.
    public static func transport(_ error: URLError) -> ProviderError {
        if error.code == .cancelled { return .cancelled }
        return unsentCodes.contains(error.code) ? notSent(error.localizedDescription) : .network(error.localizedDescription)
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
