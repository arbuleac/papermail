import Foundation

extension Data {
    /// RFC 4648 §5 base64url without padding, the alphabet PKCE (RFC 7636 §4) and OAuth state values use.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Cryptographically secure random bytes. `SystemRandomNumberGenerator` is backed by the kernel CSPRNG on
    /// Apple platforms, which keeps this file free of a Security framework dependency.
    static func secureRandom(count: Int) -> Data {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: count)
        for index in bytes.indices {
            bytes[index] = UInt8.random(in: .min ... .max, using: &generator)
        }
        return Data(bytes)
    }
}
