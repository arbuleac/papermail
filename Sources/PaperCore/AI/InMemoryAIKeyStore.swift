import Foundation

/// Keys in memory: tests, demo mode and previews, so none of them ever reads or writes the real Keychain.
public final class InMemoryAIKeyStore: AIKeyStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [AIProviderKind: String]
    private var readCounts: [AIProviderKind: Int] = [:]

    public init(_ keys: [AIProviderKind: String] = [:]) {
        self.keys = keys.compactMapValues { AIKeyStore.normalized($0) }
    }

    public func key(for kind: AIProviderKind) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        readCounts[kind, default: 0] += 1
        return keys[kind]
    }

    public func hasKey(for kind: AIProviderKind) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return keys[kind] != nil
    }

    public func setKey(_ key: String?, for kind: AIProviderKind) throws {
        lock.lock(); defer { lock.unlock() }
        keys[kind] = AIKeyStore.normalized(key)
    }

    /// How often `key(for:)` read the secret: tests assert a key is read only when a provider is about to send.
    public func reads(of kind: AIProviderKind) -> Int {
        lock.lock(); defer { lock.unlock() }
        return readCounts[kind, default: 0]
    }
}
