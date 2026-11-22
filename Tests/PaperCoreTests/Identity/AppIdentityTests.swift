import XCTest
@testable import PaperCore

/// The app's identity (docs/ARCHITECTURE.md, "Identity"): every name it keeps something under on this Mac, spelt out
/// here once so a change to one is a decision.
final class AppIdentityTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/private/tmp/identity-tests", isDirectory: true)

    func testTheAppIsPaperAtItsDomain() {
        XCTAssertEqual(AppIdentity.name, "Paper")
        XCTAssertEqual(AppIdentity.bundleIdentifier, "app.paperinbox.mac")
        XCTAssertEqual(AppIdentity.website.absoluteString, "https://paperinbox.app")
        XCTAssertEqual(AppIdentity.websiteAlias.absoluteString, "https://paperinboxapp.com")
        XCTAssertEqual(AppIdentity.localDomain, "paperinbox.local")
    }

    /// Named for the bundle identifier, never "Paper" alone, which could be another app's folder.
    func testItsFoldersAreNamedForTheBundleIdentifier() {
        XCTAssertEqual(AppIdentity.applicationSupportDirectory(in: root).path, "/private/tmp/identity-tests/app.paperinbox.mac")
        XCTAssertEqual(AppIdentity.cachesDirectory(in: root).path, "/private/tmp/identity-tests/app.paperinbox.mac")
        XCTAssertEqual(AppIdentity.sentryCacheDirectory(in: root).path, "/private/tmp/identity-tests/app.paperinbox.mac/Sentry")
        XCTAssertTrue(AppIdentity.applicationSupportDirectory.path.hasSuffix("/Library/Application Support/app.paperinbox.mac"),
                      AppIdentity.applicationSupportDirectory.path)
        XCTAssertTrue(AppIdentity.cachesDirectory.path.hasSuffix("/Library/Caches/app.paperinbox.mac"), AppIdentity.cachesDirectory.path)
    }

    func testTheMailboxDraftsAndOAuthClientsLiveInTheAppsFolder() {
        let folder = AppIdentity.applicationSupportDirectory
        XCTAssertEqual(SQLiteMailStore.defaultPath, folder.appending(path: "mail.sqlite").path)
        XCTAssertEqual(ClientConfigurationStore.defaultFileURL().path, folder.appending(path: "oauth-clients.json").path)
    }

    func testTheKeychainItemsAreTheApps() {
        XCTAssertEqual(AppIdentity.tokensKeychainService, "app.paperinbox.mac")
        XCTAssertEqual(AppIdentity.tokensKeychainLabel, "Paper account")
        XCTAssertEqual(AppIdentity.aiKeysKeychainService, "app.paperinbox.mac.ai")
        XCTAssertEqual(AppIdentity.aiKeysKeychainLabel, "Paper AI key")
        XCTAssertEqual(KeychainTokenStore.defaultService, AppIdentity.tokensKeychainService)
        XCTAssertEqual(AIKeyStore.defaultService, AppIdentity.aiKeysKeychainService)
        XCTAssertEqual(AIKeyStore.label, AppIdentity.aiKeysKeychainLabel)
    }

    /// Nothing the app writes today goes where the old app kept its things.
    func testNoCurrentNameIsAnOldOne() {
        XCTAssertNotEqual(AppIdentity.bundleIdentifier, LegacyIdentity.bundleIdentifier)
        XCTAssertNotEqual(AppIdentity.applicationSupportFolderName, LegacyIdentity.applicationSupportFolderName)
        XCTAssertNotEqual(AppIdentity.cachesFolderName, LegacyIdentity.cachesFolderName)
        XCTAssertNotEqual(AppIdentity.cachesFolderName, LegacyIdentity.attachmentCachesFolderName)
        XCTAssertNotEqual(AppIdentity.tokensKeychainService, LegacyIdentity.tokensKeychainService)
        XCTAssertNotEqual(AppIdentity.aiKeysKeychainService, LegacyIdentity.aiKeysKeychainService)
    }
}
