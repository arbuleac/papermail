import Foundation
import Security

/// API keys in the login Keychain: one generic-password item per provider (service `AppIdentity.aiKeysKeychainService`,
/// account = the provider kind's raw value, label `AppIdentity.aiKeysKeychainLabel`), apart from the account tokens
/// (`AppIdentity.tokensKeychainService`) so neither is ever mistaken for the other. Readable only while the Mac is unlocked, which is when the user writes.
public final class AIKeyStore: AIKeyStoring, Sendable {
    public static let defaultService = AppIdentity.aiKeysKeychainService
    static let label = AppIdentity.aiKeysKeychainLabel

    private let service: String
    private let access: KeychainAccess

    public convenience init(service: String = AIKeyStore.defaultService) {
        self.init(service: service, access: .system)
    }

    init(service: String, access: KeychainAccess) {
        self.service = service
        self.access = access
    }

    public func key(for kind: AIProviderKind) throws -> String? {
        var query = baseQuery(for: kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = access.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else { return nil }
            return Self.normalized(key)
        case errSecItemNotFound:
            return nil
        default:
            throw AuthError.keychain(status: status)
        }
    }

    public func hasKey(for kind: AIProviderKind) throws -> Bool {
        var query = baseQuery(for: kind)
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

    public func setKey(_ key: String?, for kind: AIProviderKind) throws {
        guard let key = Self.normalized(key) else {
            let status = access.delete(baseQuery(for: kind))
            guard status == errSecSuccess || status == errSecItemNotFound else { throw AuthError.keychain(status: status) }
            return
        }
        let data = Data(key.utf8)
        var attributes = baseQuery(for: kind)
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
            let updateStatus = access.update(baseQuery(for: kind), update)
            guard updateStatus == errSecSuccess else { throw AuthError.keychain(status: updateStatus) }
        default:
            throw AuthError.keychain(status: status)
        }
    }

    /// A key as stored: trimmed, and nil when nothing is left, so “no key” has one representation.
    static func normalized(_ key: String?) -> String? {
        guard let trimmed = key?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private func baseQuery(for kind: AIProviderKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: kind.rawValue,
        ]
    }
}
