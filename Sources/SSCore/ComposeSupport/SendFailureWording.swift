import Foundation

/// The plain-words reason in the composer's send-failed banner (spec §5.20: “Couldn't send: Microsoft 365
/// rejected the attachment size.”). The outbox keeps the provider's error as a technical description; this
/// reduces it to what happened, without blaming the user and without codes.
public enum SendFailureWording {
    /// “Couldn't send: <reason>”.
    public static func banner(lastError: String?, provider: ProviderKind) -> String {
        "Couldn't send: " + reason(lastError: lastError, provider: provider)
    }

    public static func reason(lastError: String?, provider: ProviderKind) -> String {
        let name = providerName(provider)
        let error = (lastError ?? "").lowercased()
        // `SendRunner` marks a send it was handing over when the app quit “interrupted while sending”: the provider may
        // have it, so saying it refused the message would invite a second copy (spec §5.53).
        if error.contains("interrupted") {
            return "SuperSparrow quit while sending it, so it may have gone. Check Sent before sending it again."
        }
        if error.contains("413") || error.contains("too large") || error.contains("size") || error.contains("exceed") {
            return "\(name) rejected the attachment size."
        }
        if error.contains("401") || error.contains("unauthorized") || error.contains("reauth") || error.contains("token")
            || error.contains("sign in") {
            return "\(name) needs you to sign in again."
        }
        if error.contains("network") || error.contains("offline") || error.contains("timed out")
            || error.contains("not connected") {
            return "the connection to \(name) was lost."
        }
        if error.contains("429") || error.contains("rate") || error.contains("quota") {
            return "\(name) is limiting how much mail this account can send right now."
        }
        if error.contains("recipient") || error.contains("address") {
            return "\(name) rejected a recipient's address."
        }
        return "\(name) didn't accept the message."
    }

    public static func providerName(_ provider: ProviderKind) -> String {
        switch provider {
        case .gmail: return "Gmail"
        case .microsoft: return "Microsoft 365"
        }
    }
}
