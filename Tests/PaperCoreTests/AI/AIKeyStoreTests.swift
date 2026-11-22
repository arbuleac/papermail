import Security
import XCTest
@testable import PaperCore

/// API keys in the Keychain, against a dictionary standing in for it: tests never touch the real Keychain.
final class AIKeyStoreTests: XCTestCase {
    /// The fake records every query, so the tests can see what was asked of the Keychain.
    private final class FakeKeychain: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String: [String: Any]] = [:]
        private(set) var queries: [[String: Any]] = []
        var failure: OSStatus?

        func item(service: String, account: String) -> [String: Any]? {
            lock.lock(); defer { lock.unlock() }
            return items["\(service)/\(account)"]
        }

        var access: KeychainAccess {
            KeychainAccess(
                copyMatching: { [self] query in
                    lock.lock(); defer { lock.unlock() }
                    queries.append(query)
                    if let failure { return (failure, nil) }
                    guard let item = items[Self.key(query)] else { return (errSecItemNotFound, nil) }
                    if query[kSecReturnData as String] as? Bool == true { return (errSecSuccess, item[kSecValueData as String] as AnyObject) }
                    return (errSecSuccess, item as AnyObject)
                },
                add: { [self] attributes in
                    lock.lock(); defer { lock.unlock() }
                    if let failure { return failure }
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
                    if let failure { return failure }
                    return items.removeValue(forKey: Self.key(query)) == nil ? errSecItemNotFound : errSecSuccess
                }
            )
        }

        private static func key(_ query: [String: Any]) -> String {
            "\(query[kSecAttrService as String] as? String ?? "")/\(query[kSecAttrAccount as String] as? String ?? "")"
        }
    }

    private let keychain = FakeKeychain()
    private var store: AIKeyStore { AIKeyStore(service: AIKeyStore.defaultService, access: keychain.access) }

    func testAKeyIsSavedTrimmedUnderItsOwnServiceAccountAndLabel() throws {
        try store.setKey("  sk-ant-test-123\n", for: .claudeAPI)
        XCTAssertEqual(try store.key(for: .claudeAPI), "sk-ant-test-123")
        let item = try XCTUnwrap(keychain.item(service: "app.paperinbox.mac.ai", account: "claudeAPI"))
        XCTAssertEqual(item[kSecAttrLabel as String] as? String, "Paper AI key")
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlocked as String)
        XCTAssertEqual(item[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertNil(keychain.item(service: "app.paperinbox.mac", account: "claudeAPI"), "never beside the account tokens")
    }

    func testEachProviderHasItsOwnKey() throws {
        try store.setKey("anthropic", for: .claudeAPI)
        try store.setKey("openai", for: .openAIAPI)
        XCTAssertEqual(try store.key(for: .claudeAPI), "anthropic")
        XCTAssertEqual(try store.key(for: .openAIAPI), "openai")
        XCTAssertNil(try store.key(for: .codex))
    }

    func testSavingAgainReplacesTheKey() throws {
        try store.setKey("first", for: .openAIAPI)
        try store.setKey("second", for: .openAIAPI)
        XCTAssertEqual(try store.key(for: .openAIAPI), "second")
    }

    func testClearingRemovesTheItem() throws {
        try store.setKey("key", for: .claudeAPI)
        try store.setKey("   ", for: .claudeAPI)
        XCTAssertNil(keychain.item(service: "app.paperinbox.mac.ai", account: "claudeAPI"))
        try store.setKey("key", for: .claudeAPI)
        try store.setKey(nil, for: .claudeAPI)
        XCTAssertNil(try store.key(for: .claudeAPI))
        XCTAssertNoThrow(try store.setKey(nil, for: .claudeAPI), "removing a missing key is fine")
    }

    func testHasKeyNeverAsksForTheSecret() throws {
        XCTAssertFalse(try store.hasKey(for: .claudeAPI))
        try store.setKey("key", for: .claudeAPI)
        XCTAssertTrue(try store.hasKey(for: .claudeAPI))
        let lookups = keychain.queries
        XCTAssertFalse(lookups.isEmpty)
        for query in lookups {
            XCTAssertNil(query[kSecReturnData as String], "reading the data is what prompts after a rebuild")
        }
    }

    func testKeychainFailuresThrowTheStatusAndNeverTheKey() {
        keychain.failure = errSecInteractionNotAllowed
        XCTAssertThrowsError(try store.key(for: .claudeAPI)) { error in
            guard case AuthError.keychain(let status) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(status, errSecInteractionNotAllowed)
            XCTAssertTrue((error as? AuthError)?.isKeychainDenial == true)
        }
        XCTAssertThrowsError(try store.setKey("sk-secret-value", for: .claudeAPI)) { error in
            XCTAssertFalse(String(describing: error).contains("sk-secret-value"))
        }
        XCTAssertThrowsError(try store.hasKey(for: .claudeAPI))
    }

    func testTheInMemoryStoreCountsReads() throws {
        let memory = InMemoryAIKeyStore([.claudeAPI: " key ", .openAIAPI: "  "])
        XCTAssertTrue(try memory.hasKey(for: .claudeAPI))
        XCTAssertFalse(try memory.hasKey(for: .openAIAPI), "blank is no key")
        XCTAssertEqual(memory.reads(of: .claudeAPI), 0, "hasKey is not a read")
        XCTAssertEqual(try memory.key(for: .claudeAPI), "key")
        XCTAssertEqual(memory.reads(of: .claudeAPI), 1)
        try memory.setKey(nil, for: .claudeAPI)
        XCTAssertNil(try memory.key(for: .claudeAPI))
    }
}
