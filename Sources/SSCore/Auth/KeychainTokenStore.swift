import Foundation
import Security
import os

/// Stores each account's tokens as one generic-password item in the login Keychain
/// (service "SuperSparrow", account = the account id), encoded as JSON.
public final class KeychainTokenStore: TokenStore, Sendable {
    public static let defaultService = "SuperSparrow"

    private static let logger = Logger(subsystem: "io.supersparrow.mac", category: "auth")

    private let service: String
    private let access: KeychainAccess

    public convenience init(service: String = KeychainTokenStore.defaultService) {
        self.init(service: service, access: .system)
    }

    init(service: String, access: KeychainAccess) {
        self.service = service
        self.access = access
    }

    public func tokens(for accountID: AccountID) throws -> OAuthTokens? {
        var query = baseQuery(for: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, item) = access.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let tokens = try? JSONDecoder().decode(OAuthTokens.self, from: data) else {
                // An item this build cannot read has to look like "signed out": the engine only knows
                // `ProviderError.unauthorized` as the cue to ask for a new sign-in, and a thrown `AuthError`
                // would wedge the account until someone deletes the item by hand. Dropping it here does that
                // for them and keeps the error from logging on every poll.
                Self.logger.error("Stored tokens for account \(accountID.rawValue, privacy: .public) could not be decoded; treating the account as signed out")
                _ = access.delete(baseQuery(for: accountID))
                return nil
            }
            return tokens
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
        let status = access.add(attributes)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let updateStatus = access.update(baseQuery(for: accountID), update)
            guard updateStatus == errSecSuccess else {
                throw AuthError.keychain(status: updateStatus)
            }
        default:
            throw AuthError.keychain(status: status)
        }
    }

    public func delete(for accountID: AccountID) throws {
        let status = access.delete(baseQuery(for: accountID))
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
