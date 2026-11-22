import Foundation
import Security
import os

/// API keys in the login Keychain: one generic-password item per provider (service `AppIdentity.aiKeysKeychainService`,
/// account = the provider kind's raw value, label `AppIdentity.aiKeysKeychainLabel`), apart from the account tokens
/// (`AppIdentity.tokensKeychainService`) so neither is ever mistaken for the other. Readable only while the Mac is unlocked, which is when the user writes.
///
/// A key saved before the app was Paper is under the old service (`LegacyIdentity`). The first read that finds none
/// under the new service reads the old one, writes the key under the new service and then deletes the old item
/// (docs/ARCHITECTURE.md, "Identity"); `hasKey` sees the old item without reading it. Clearing or replacing a key removes
/// the old item too. Only the bundled app reads the old service (`defaultLegacyService`).
public final class AIKeyStore: AIKeyStoring, Sendable {
    public static let defaultService = AppIdentity.aiKeysKeychainService
    static let label = AppIdentity.aiKeysKeychainLabel

    /// The old service, in the bundled app only: the bare binary and the tests never take a key from under the old app.
    public static var defaultLegacyService: String? {
        IdentityMigration.appliesToThisProcess ? LegacyIdentity.aiKeysKeychainService : nil
    }

    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "ai")

    private let service: String
    private let legacyService: String?
    private let access: KeychainAccess
    /// One move at a time, so a read racing another's move never finds the key under neither service.
    private let moveLock = NSLock()

    public convenience init(service: String = AIKeyStore.defaultService, legacyService: String? = AIKeyStore.defaultLegacyService) {
        self.init(service: service, legacyService: legacyService, access: .system)
    }

    init(service: String, legacyService: String? = nil, access: KeychainAccess) {
        self.service = service
        self.legacyService = legacyService
        self.access = access
    }

    public func key(for kind: AIProviderKind) throws -> String? {
        if let stored = try storedKey(for: kind, in: service) { return stored.key }
        guard let legacyService else { return nil }
        moveLock.lock()
        defer { moveLock.unlock() }
        // Another read may have moved it while this one waited.
        if let stored = try storedKey(for: kind, in: service) { return stored.key }
        guard let legacy = try storedKey(for: kind, in: legacyService) else { return nil }
        if let key = legacy.key {
            do {
                try write(key, for: kind)
            } catch {
                // Still under the old service, where the next read finds it and tries again.
                Self.logger.error("An API key could not be moved to the new Keychain item: \(String(describing: error), privacy: .public)")
                return key
            }
        }
        let status = access.delete(baseQuery(for: kind, service: legacyService))
        if status == errSecSuccess || status == errSecItemNotFound {
            Self.logger.info("An API key moved to the new Keychain item")
        } else {
            Self.logger.error("An old API key's Keychain item could not be deleted (status \(status, privacy: .public))")
        }
        return legacy.key
    }

    public func hasKey(for kind: AIProviderKind) throws -> Bool {
        if try itemExists(for: kind, in: service) { return true }
        guard let legacyService else { return false }
        return try itemExists(for: kind, in: legacyService)
    }

    public func setKey(_ key: String?, for kind: AIProviderKind) throws {
        guard let key = Self.normalized(key) else {
            let statuses = ([service] + [legacyService].compactMap { $0 }).map { access.delete(baseQuery(for: kind, service: $0)) }
            if let failure = statuses.first(where: { $0 != errSecSuccess && $0 != errSecItemNotFound }) {
                throw AuthError.keychain(status: failure)
            }
            return
        }
        try write(key, for: kind)
        // A replaced key must not stay behind under the old service, where nothing would ever read or remove it.
        if let legacyService { _ = access.delete(baseQuery(for: kind, service: legacyService)) }
    }

    /// A key as stored: trimmed, and nil when nothing is left, so “no key” has one representation.
    static func normalized(_ key: String?) -> String? {
        guard let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// An item found: its key, or nil when it holds nothing this build can read.
    private struct Stored {
        var key: String?
    }

    /// The item under `service`, nil when there is none.
    private func storedKey(for kind: AIProviderKind, in service: String) throws -> Stored? {
        var query = baseQuery(for: kind, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = access.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else { return Stored(key: nil) }
            return Stored(key: Self.normalized(key))
        case errSecItemNotFound:
            return nil
        default:
            throw AuthError.keychain(status: status)
        }
    }

    private func itemExists(for kind: AIProviderKind, in service: String) throws -> Bool {
        var query = baseQuery(for: kind, service: service)
        // Attributes only: asking for the data is what shows the password prompt after a rebuild.
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, _) = access.copyMatching(query)
        switch status {
        case errSecSuccess: return true
        case errSecItemNotFound: return false
        default: throw AuthError.keychain(status: status)
        }
    }

    private func write(_ key: String, for kind: AIProviderKind) throws {
        let data = Data(key.utf8)
        var attributes = baseQuery(for: kind, service: service)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        attributes[kSecAttrLabel as String] = Self.label
        let status = access.add(attributes)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
            ]
            let updateStatus = access.update(baseQuery(for: kind, service: service), update)
            guard updateStatus == errSecSuccess else { throw AuthError.keychain(status: updateStatus) }
        default:
            throw AuthError.keychain(status: status)
        }
    }

    private func baseQuery(for kind: AIProviderKind, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]
    }
}
