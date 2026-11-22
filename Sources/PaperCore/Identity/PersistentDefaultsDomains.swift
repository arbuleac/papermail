import Foundation

/// The defaults the first launch's move reads and writes, a whole persistent domain at a time (`IdentityMigration`):
/// `UserDefaults.standard` in the app, a dictionary in the tests, since even a test's own suite is written to the
/// user's `~/Library/Preferences`.
public protocol PersistentDefaultsDomains: AnyObject {
    func persistentDomain(forName domainName: String) -> [String: Any]?
    func setPersistentDomain(_ domain: [String: Any], forName domainName: String)
    func removePersistentDomain(forName domainName: String)
}

extension UserDefaults: PersistentDefaultsDomains {}
