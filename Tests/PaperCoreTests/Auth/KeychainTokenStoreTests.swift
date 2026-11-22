import Security
import XCTest
@testable import PaperCore

final class KeychainTokenStoreTests: XCTestCase {
    private let accountID = AccountID("acct-1")
    private let service = "Paper.tests"

    /// A dictionary standing in for the login Keychain, keyed the way the store queries it: tests never touch the real
    /// Keychain.
    private final class FakeKeychain: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: [String: Any]] = [:]
        private(set) var reads: [String] = []
        var addFailure: OSStatus?

        func set(_ data: Data, service: String, account: String) {
            lock.lock(); defer { lock.unlock() }
            items[Self.key(service: service, account: account)] = [kSecValueData as String: data]
        }

        func contains(service: String, account: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return items[Self.key(service: service, account: account)] != nil
        }

        func item(service: String, account: String) -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            return items[Self.key(service: service, account: account)]
        }

        var access: KeychainAccess {
            KeychainAccess(
                copyMatching: { [self] query in
                    lock.lock(); defer { lock.unlock() }
                    reads.append(query[kSecAttrService as String] as? String ?? "")
                    guard let item = items[Self.key(query)] else { return (errSecItemNotFound, nil) }
                    return (errSecSuccess, item[kSecValueData as String] as AnyObject)
                },
                add: { [self] attributes in
                    lock.lock(); defer { lock.unlock() }
                    if let addFailure { return addFailure }
                    let key = Self.key(attributes)
                    guard items[key] == nil else { return errSecDuplicateItem }
                    items[key] = attributes
                    return errSecSuccess
                },
                update: { [self] query, attributes in
                    lock.lock(); defer { lock.unlock() }
                    let key = Self.key(query)
                    guard var item = items[key] else { return errSecItemNotFound }
                    item.merge(attributes) { $1 }
                    items[key] = item
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

    // MARK: Moving from the old service (docs/ARCHITECTURE.md, "Identity")

    private let newService = KeychainTokenStore.defaultService
    private let oldService = LegacyIdentity.tokensKeychainService

    private func encoded(_ tokens: OAuthTokens) throws -> Data {
        try JSONEncoder().encode(tokens)
    }

    func testTokensOnlyUnderTheOldServiceMoveOnTheirFirstRead() throws {
        let keychain = FakeKeychain()
        keychain.set(try encoded(tokens("old-at")), service: oldService, account: accountID.rawValue)
        let store = KeychainTokenStore(service: newService, legacyService: oldService, access: keychain.access)

        XCTAssertEqual(try store.tokens(for: accountID), tokens("old-at"))
        let moved = try XCTUnwrap(keychain.item(service: "app.paperinbox.mac", account: accountID.rawValue))
        XCTAssertEqual(try JSONDecoder().decode(OAuthTokens.self, from: try XCTUnwrap(moved[kSecValueData as String] as? Data)), tokens("old-at"))
        XCTAssertEqual(moved[kSecAttrLabel as String] as? String, "Paper account")
        XCTAssertEqual(moved[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String)
        XCTAssertFalse(keychain.contains(service: "SuperSparrow", account: accountID.rawValue), "the old item is deleted")

        // From now on the new item answers, and the old service is never asked again.
        let before = keychain.reads.count
        XCTAssertEqual(try store.tokens(for: accountID), tokens("old-at"))
        XCTAssertEqual(Array(keychain.reads.dropFirst(before)), [newService])
    }

    /// Reads at the same time (the token manager's and the engine's at launch) all find the account signed in, whichever
    /// of them moves it.
    func testConcurrentFirstReadsAllFindTheTokens() throws {
        for _ in 0..<20 {
            let keychain = FakeKeychain()
            keychain.set(try encoded(tokens("old-at")), service: oldService, account: accountID.rawValue)
            let store = KeychainTokenStore(service: newService, legacyService: oldService, access: keychain.access)
            let found = Found()
            DispatchQueue.concurrentPerform(iterations: 16) { _ in
                found.add((try? store.tokens(for: accountID)) ?? nil)
            }
            XCTAssertEqual(found.all, Array(repeating: tokens("old-at"), count: 16))
            XCTAssertFalse(keychain.contains(service: oldService, account: accountID.rawValue))
        }
    }

    private final class Found: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [OAuthTokens?] = []
        var all: [OAuthTokens?] { lock.lock(); defer { lock.unlock() }; return values }
        func add(_ value: OAuthTokens?) { lock.lock(); values.append(value); lock.unlock() }
    }

    func testTokensUnderBothServicesReadTheNewOne() throws {
        let keychain = FakeKeychain()
        keychain.set(try encoded(tokens("old-at")), service: oldService, account: accountID.rawValue)
        keychain.set(try encoded(tokens("new-at")), service: newService, account: accountID.rawValue)
        let store = KeychainTokenStore(service: newService, legacyService: oldService, access: keychain.access)
        XCTAssertEqual(try store.tokens(for: accountID), tokens("new-at"))
        XCTAssertEqual(keychain.reads, [newService], "the old item is not even read, so it asks for no password")
    }

    func testDeleteRemovesTheItemUnderBothServices() throws {
        let keychain = FakeKeychain()
        keychain.set(try encoded(tokens("old-at")), service: oldService, account: accountID.rawValue)
        keychain.set(try encoded(tokens("new-at")), service: newService, account: accountID.rawValue)
        let store = KeychainTokenStore(service: newService, legacyService: oldService, access: keychain.access)
        try store.delete(for: accountID)
        XCTAssertFalse(keychain.contains(service: newService, account: accountID.rawValue))
        XCTAssertFalse(keychain.contains(service: oldService, account: accountID.rawValue))
        XCTAssertNil(try store.tokens(for: accountID))
        XCTAssertNoThrow(try store.delete(for: accountID))
    }

    /// A move that cannot write the new item keeps the old one, which the next read tries again.
    func testAFailedMoveKeepsTheOldItem() throws {
        let keychain = FakeKeychain()
        keychain.set(try encoded(tokens("old-at")), service: oldService, account: accountID.rawValue)
        keychain.addFailure = errSecInteractionNotAllowed
        let store = KeychainTokenStore(service: newService, legacyService: oldService, access: keychain.access)
        XCTAssertEqual(try store.tokens(for: accountID), tokens("old-at"))
        XCTAssertTrue(keychain.contains(service: oldService, account: accountID.rawValue))
        keychain.addFailure = nil
        XCTAssertEqual(try store.tokens(for: accountID), tokens("old-at"))
        XCTAssertFalse(keychain.contains(service: oldService, account: accountID.rawValue))
        XCTAssertTrue(keychain.contains(service: newService, account: accountID.rawValue))
    }

    /// A move cut off after its write and before its delete (a crash, or a delete that failed) leaves the old item; every
    /// later read stops at the new one, so the next save (a token refresh) deletes it.
    func testASaveDeletesAnOldItemAMoveLeftBehind() throws {
        let keychain = FakeKeychain()
        keychain.set(try encoded(tokens("old-at")), service: oldService, account: accountID.rawValue)
        keychain.set(try encoded(tokens("moved-at")), service: newService, account: accountID.rawValue)
        let store = KeychainTokenStore(service: newService, legacyService: oldService, access: keychain.access)
        XCTAssertEqual(try store.tokens(for: accountID), tokens("moved-at"))
        XCTAssertTrue(keychain.contains(service: oldService, account: accountID.rawValue), "a read alone never reaches it")

        try store.save(tokens("refreshed-at"), for: accountID)
        XCTAssertFalse(keychain.contains(service: oldService, account: accountID.rawValue))
        XCTAssertEqual(try store.tokens(for: accountID), tokens("refreshed-at"))

        // Without an old service (the bare binary, the tests), a save never touches the old item.
        keychain.set(try encoded(tokens("old-at")), service: oldService, account: accountID.rawValue)
        try KeychainTokenStore(service: newService, access: keychain.access).save(tokens("again-at"), for: accountID)
        XCTAssertTrue(keychain.contains(service: oldService, account: accountID.rawValue))
    }

    /// The bare binary and the tests have no old service: they never take an item from under the old app.
    func testWithoutAnOldServiceTheOldItemIsNeverRead() throws {
        let keychain = FakeKeychain()
        keychain.set(try encoded(tokens("old-at")), service: oldService, account: accountID.rawValue)
        let store = KeychainTokenStore(service: newService, access: keychain.access)
        XCTAssertNil(try store.tokens(for: accountID))
        try store.delete(for: accountID)
        XCTAssertTrue(keychain.contains(service: oldService, account: accountID.rawValue))
        XCTAssertEqual(Set(keychain.reads), [newService])
    }
}
