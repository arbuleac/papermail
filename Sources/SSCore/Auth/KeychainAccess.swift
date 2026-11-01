import Foundation
import Security

/// The Security framework calls `KeychainTokenStore` makes, as closures so tests can stand a dictionary in for
/// the login Keychain, which prompts, persists between runs and is not available on every build machine.
struct KeychainAccess: Sendable {
    var copyMatching: @Sendable (_ query: [String: Any]) -> (status: OSStatus, item: CFTypeRef?)
    var add: @Sendable (_ attributes: [String: Any]) -> OSStatus
    var update: @Sendable (_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus
    var delete: @Sendable (_ query: [String: Any]) -> OSStatus

    static let system = KeychainAccess(
        copyMatching: { query in
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            return (status, item)
        },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        delete: { SecItemDelete($0 as CFDictionary) }
    )
}
