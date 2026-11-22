import Foundation

/// Where API keys live: the Keychain in the app (`AIKeyStore`), a dictionary in tests, demo and previews
/// (`InMemoryAIKeyStore`). A protocol so Settings and the providers can be tested without the real Keychain, which
/// prompts after every ad-hoc rebuild.
///
/// Keys are secrets: implementations never log them and never put them in an error.
public protocol AIKeyStoring: Sendable {
    /// The stored key, nil when there is none. Reading the item's data can show the Keychain's password prompt, so
    /// only a provider about to send (or Check) reads it.
    func key(for kind: AIProviderKind) throws -> String?

    /// Whether a key is stored, read without the item's data, so it never prompts: Settings' status line uses it.
    func hasKey(for kind: AIProviderKind) throws -> Bool

    /// Saves `key`, trimmed of the white space a paste brings; nil or only white space removes the item.
    func setKey(_ key: String?, for kind: AIProviderKind) throws
}
