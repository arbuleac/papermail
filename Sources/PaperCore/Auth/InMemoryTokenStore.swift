import Foundation

/// A `TokenStore` that forgets everything on exit, for tests and demo mode.
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [AccountID: OAuthTokens] = [:]

    public init(_ initial: [AccountID: OAuthTokens] = [:]) {
        storage = initial
    }

    public func tokens(for accountID: AccountID) throws -> OAuthTokens? {
        lock.lock(); defer { lock.unlock() }
        return storage[accountID]
    }

    public func save(_ tokens: OAuthTokens, for accountID: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[accountID] = tokens
    }

    public func delete(for accountID: AccountID) throws {
        lock.lock(); defer { lock.unlock() }
        storage[accountID] = nil
    }

    /// Every stored account id, for tests that assert on what was persisted.
    public var accountIDs: [AccountID] {
        lock.lock(); defer { lock.unlock() }
        return Array(storage.keys)
    }
}
