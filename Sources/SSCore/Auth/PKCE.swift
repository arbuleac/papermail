import CryptoKit
import Foundation

/// A Proof Key for Code Exchange pair (RFC 7636) using the S256 transform.
///
/// The verifier never leaves the process; only the challenge travels in the authorization URL, so an attacker
/// who observes the loopback redirect cannot redeem the code without it.
public struct PKCE: Sendable, Hashable {
    public static let method = "S256"

    public let verifier: String
    public let challenge: String

    /// Generates a fresh verifier: 32 random bytes base64url-encoded, which gives the 43 characters RFC 7636 §4.1
    /// recommends.
    public init() {
        self.init(verifier: Data.secureRandom(count: 32).base64URLEncodedString())
    }

    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = PKCE.challenge(for: verifier)
    }

    /// `BASE64URL(SHA256(ASCII(verifier)))` per RFC 7636 §4.2.
    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }
}
