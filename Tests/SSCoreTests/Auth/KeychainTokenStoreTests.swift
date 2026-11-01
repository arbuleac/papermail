import Security
import XCTest
@testable import SSCore

final class KeychainTokenStoreTests: XCTestCase {
    private let accountID = AccountID("acct-1")
    private let service = "SuperSparrow.tests"

    /// A dictionary standing in for the login Keychain, keyed the way the store queries it.
    private final class FakeKeychain: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: Data] = [:]

        func set(_ data: Data, service: String, account: String) {
            lock.lock(); defer { lock.unlock() }
            items[Self.key(service: service, account: account)] = data
        }

        func contains(service: String, account: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return items[Self.key(service: service, account: account)] != nil
        }

        var access: KeychainAccess {
            KeychainAccess(
                copyMatching: { [self] query in
                    lock.lock(); defer { lock.unlock() }
                    guard let data = items[Self.key(query)] else { return (errSecItemNotFound, nil) }
                    return (errSecSuccess, data as AnyObject)
                },
                add: { [self] attributes in
                    lock.lock(); defer { lock.unlock() }
                    let key = Self.key(attributes)
                    guard items[key] == nil else { return errSecDuplicateItem }
                    items[key] = attributes[kSecValueData as String] as? Data
                    return errSecSuccess
                },
                update: { [self] query, attributes in
                    lock.lock(); defer { lock.unlock() }
                    let key = Self.key(query)
                    guard items[key] != nil else { return errSecItemNotFound }
                    items[key] = attributes[kSecValueData as String] as? Data
                    return errSecSuccess
                },
                delete: { [self] query in
                    lock.lock(); defer { lock.unlock() }
                    return items.removeValue(forKey: Self.key(query)) == nil ? errSecItemNotFound : errSecSuccess
                }
            )
        }

        private static func key(_ query: [String: Any]) -> String {
            key(service: query[kSecAttrService as String] as? String ?? "", account: query[kSecAttrAccount as String] as? String ?? "")
        }

        private static func key(service: String, account: String) -> String {
            "\(service)/\(account)"
        }
    }

    private func tokens(_ accessToken: String) -> OAuthTokens {
        OAuthTokens(accessToken: accessToken, refreshToken: "rt", expiresAt: Date(timeIntervalSince1970: 1_800_000_000), scope: "scope")
    }

    func testSaveReadUpdateDeleteRoundTrip() throws {
        let keychain = FakeKeychain()
        let store = KeychainTokenStore(service: service, access: keychain.access)
        XCTAssertNil(try store.tokens(for: accountID))
        try store.save(tokens("at-1"), for: accountID)
        XCTAssertEqual(try store.tokens(for: accountID), tokens("at-1"))
        // A second save hits the duplicate-item path and must update in place.
        try store.save(tokens("at-2"), for: accountID)
        XCTAssertEqual(try store.tokens(for: accountID), tokens("at-2"))
        try store.delete(for: accountID)
        XCTAssertNil(try store.tokens(for: accountID))
        XCTAssertNoThrow(try store.delete(for: accountID))
    }

    func testUndecodableItemReadsAsSignedOutAndCanBeOverwritten() throws {
        let keychain = FakeKeychain()
        keychain.set(Data("not json".utf8), service: service, account: accountID.rawValue)
        let store = KeychainTokenStore(service: service, access: keychain.access)
        XCTAssertNil(try store.tokens(for: accountID))
        XCTAssertFalse(keychain.contains(service: service, account: accountID.rawValue), "the dead item should be dropped")
        try store.save(tokens("at-1"), for: accountID)
        XCTAssertEqual(try store.tokens(for: accountID), tokens("at-1"))
    }

    /// The engine only knows `ProviderError.unauthorized` as the signal to ask for a new sign-in.
    func testUndecodableItemLeadsToReauthorization() async throws {
        let keychain = FakeKeychain()
        keychain.set(Data(#"{"accessToken":"at-1"}"#.utf8), service: service, account: accountID.rawValue)
        let manager = TokenManager(
            tokenStore: KeychainTokenStore(service: service, access: keychain.access),
            configurations: ClientConfigurationStore(fileURL: URL(filePath: "/nonexistent/oauth-clients.json")),
            kinds: { _ in .gmail },
            session: StubURLProtocol.makeSession()
        )
        do {
            _ = try await manager.accessToken(for: accountID)
            XCTFail("expected unauthorized")
        } catch ProviderError.unauthorized {
            // expected
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
