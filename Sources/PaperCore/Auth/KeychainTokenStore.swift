import Foundation
import Security
import os

/// Stores each account's tokens as one generic-password item in the login Keychain
/// (service `AppIdentity.tokensKeychainService`, account = the account id, label `AppIdentity.tokensKeychainLabel`),
/// encoded as JSON.
///
/// An account signed in before the app was Paper has its item under the old service (`LegacyIdentity`). The first read
/// that finds none under the new service reads the old one, writes what it found under the new service and then deletes
/// the old item, so each account moves the first time it is used (docs/ARCHITECTURE.md, "Identity"). `delete` removes
/// both. Only the bundled app reads the old service (`defaultLegacyService`).
public final class KeychainTokenStore: TokenStore, Sendable {
    public static let defaultService = AppIdentity.tokensKeychainService

    /// The old service, in the bundled app only: the bare binary and the tests never take an item from under the old
    /// app, which may still be using it.
    public static var defaultLegacyService: String? {
        IdentityMigration.appliesToThisProcess ? LegacyIdentity.tokensKeychainService : nil
    }

    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "auth")

    private let service: String
    private let legacyService: String?
    private let access: KeychainAccess
    /// One move at a time: a read that found nothing under the new service while another was moving the same item
    /// would otherwise find the old one gone too, and take a signed-in account for signed out.
    private let moveLock = NSLock()

    public convenience init(service: String = KeychainTokenStore.defaultService,
                            legacyService: String? = KeychainTokenStore.defaultLegacyService) {
        self.init(service: service, legacyService: legacyService, access: .system)
    }

    init(service: String, legacyService: String? = nil, access: KeychainAccess) {
        self.service = service
        self.legacyService = legacyService
        self.access = access
    }

    public func tokens(for accountID: AccountID) throws -> OAuthTokens? {
        switch try read(accountID, from: service) {
        case .found(let tokens): return tokens
        case .dropped: return nil
        case .missing: break
        }
        guard let legacyService else { return nil }
        moveLock.lock()
        defer { moveLock.unlock() }
        // Another read may have moved it while this one waited.
        switch try read(accountID, from: service) {
        case .found(let tokens): return tokens
        case .dropped: return nil
        case .missing: break
        }
        guard case .found(let tokens) = try read(accountID, from: legacyService) else { return nil }
        do {
            try save(tokens, for: accountID)
        } catch {
            // Still under the old service, where the next read finds it and tries again.
            Self.logger.error("An account's tokens could not be moved to the new Keychain item: \(String(describing: error), privacy: .public)")
            return tokens
        }
        let status = access.delete(baseQuery(for: accountID, service: legacyService))
        if status == errSecSuccess || status == errSecItemNotFound {
            Self.logger.info("An account's tokens moved to the new Keychain item")
        } else {
            // The new item wins every read from now on; the old one is only left behind.
            Self.logger.error("An account's old Keychain item could not be deleted (status \(status, privacy: .public))")
        }
        return tokens
    }

    public func save(_ tokens: OAuthTokens, for accountID: AccountID) throws {
        let data: Data
        do {
            data = try JSONEncoder().encode(tokens)
        } catch {
            throw AuthError.keychain(status: errSecParam)
        }
        var attributes = baseQuery(for: accountID, service: service)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrLabel as String] = AppIdentity.tokensKeychainLabel
        let status = access.add(attributes)
        switch status {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            let updateStatus = access.update(baseQuery(for: accountID, service: service), update)
            guard updateStatus == errSecSuccess else {
                throw AuthError.keychain(status: updateStatus)
            }
        default:
            throw AuthError.keychain(status: status)
        }
    }

    /// Removes the account's item under the new service and, in the bundled app, any left under the old one.
    public func delete(for accountID: AccountID) throws {
        let statuses = ([service] + [legacyService].compactMap { $0 }).map { access.delete(baseQuery(for: accountID, service: $0)) }
        if let failure = statuses.first(where: { $0 != errSecSuccess && $0 != errSecItemNotFound }) {
            throw AuthError.keychain(status: failure)
        }
    }

    private enum Read {
        case found(OAuthTokens)
        case missing
        /// An item this build cannot read, deleted.
        case dropped
    }

    private func read(_ accountID: AccountID, from service: String) throws -> Read {
        var query = baseQuery(for: accountID, service: service)
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
                _ = access.delete(baseQuery(for: accountID, service: service))
                return .dropped
            }
            return .found(tokens)
        case errSecItemNotFound:
            return .missing
        default:
            throw AuthError.keychain(status: status)
        }
    }

    private func baseQuery(for accountID: AccountID, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.rawValue,
        ]
    }
}
