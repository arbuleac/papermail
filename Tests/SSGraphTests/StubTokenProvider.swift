import Foundation
import SSCore

/// Hands out a scripted sequence of tokens and counts invalidations, so 401 handling can be asserted.
final class StubTokenProvider: AccessTokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String]
    private(set) var invalidations = 0
    private(set) var requests = 0
    /// The scopes the token endpoint listed for the account; nil when unknown.
    var scopes: String?

    init(tokens: [String] = ["token-1"], scopes: String? = nil) {
        queue = tokens
        self.scopes = scopes
    }

    func grantedScopes(for accountID: AccountID) async -> String? {
        lock.withLock { scopes }
    }

    func accessToken(for accountID: AccountID) async throws -> String {
        nextToken()
    }

    func invalidateAccessToken(for accountID: AccountID) async {
        recordInvalidation()
    }

    // Locking happens in synchronous helpers because NSLock may not be held across an await.
    private func nextToken() -> String {
        lock.withLock {
            requests += 1
            if queue.count > 1 { return queue.removeFirst() }
            return queue.first ?? "token"
        }
    }

    private func recordInvalidation() {
        lock.withLock { invalidations += 1 }
    }
}
