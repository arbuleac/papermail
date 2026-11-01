import Foundation
import Security

/// Stores each account's tokens as one generic-password item in the login Keychain
/// (service "SuperSparrow", account = the account id), encoded as JSON.
public final class KeychainTokenStore: TokenStore, Sendable {
    public static let defaultService = "SuperSparrow"

    private let service: String

    public init(service: String = KeychainTokenStore.defaultService) {
        self.service = service
    }

    public func tokens(for accountID: AccountID) throws -> OAuthTokens? {
        var query = baseQuery(for: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw AuthError.keychain(status: errSecDecode)
            }
            do {
                return try JSONDecoder().decode(OAuthTokens.self, from: data)
            } catch {
                // A corrupt item should read as "signed out" rather than wedge the account forever.
                throw AuthError.keychain(status: errSecDecode)
            }
        case errSecItemNotFound:
            return nil
        default:
            throw AuthError.keychain(status: status)
        }
    }

    public func save(_ tokens: OAuthTokens, for accountID: AccountID) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(tokens)
        } catch {
            throw AuthError.keychain(status: errSecParam)
        }
        var attributes = baseQuery(for: accountID)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrLabel as String] = "SuperSparrow account tokens"
        let status = SecItemAdd(attributes as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let updateStatus = SecItemUpdate(baseQuery(for: accountID) as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw AuthError.keychain(status: updateStatus)
            }
        default:
            throw AuthError.keychain(status: status)
        }
    }

    public func delete(for accountID: AccountID) throws {
        let status = SecItemDelete(baseQuery(for: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw AuthError.keychain(status: status)
        }
    }

    private func baseQuery(for accountID: AccountID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.rawValue,
        ]
    }
}
