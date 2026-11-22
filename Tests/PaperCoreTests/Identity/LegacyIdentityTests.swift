import XCTest
@testable import PaperCore

/// The names the app had before it was Paper (docs/ARCHITECTURE.md, "Identity"), which the first launch reads from.
final class LegacyIdentityTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/private/tmp/identity-tests", isDirectory: true)

    /// The old app's names, exactly as it used them: the move finds nothing if one is off by a letter.
    func testTheOldAppsNamesAreWhereItKeptThings() {
        XCTAssertEqual(LegacyIdentity.name, "SuperSparrow")
        XCTAssertEqual(LegacyIdentity.bundleIdentifier, "io.supersparrow.mac")
        XCTAssertEqual(LegacyIdentity.defaultsDomain, "io.supersparrow.mac")
        XCTAssertEqual(LegacyIdentity.bareBinaryDefaultsDomain, "SuperSparrow")
        XCTAssertEqual(LegacyIdentity.applicationSupportDirectory(in: root).path, "/private/tmp/identity-tests/SuperSparrow")
        XCTAssertEqual(LegacyIdentity.cachesDirectory(in: root).path, "/private/tmp/identity-tests/io.supersparrow.mac")
        XCTAssertEqual(LegacyIdentity.sentryCacheDirectory(in: root).path, "/private/tmp/identity-tests/io.supersparrow.mac/Sentry")
        XCTAssertEqual(LegacyIdentity.attachmentCachesDirectory(in: root).path, "/private/tmp/identity-tests/SuperSparrow")
        XCTAssertEqual(LegacyIdentity.tokensKeychainService, "SuperSparrow")
        XCTAssertEqual(LegacyIdentity.aiKeysKeychainService, "SuperSparrow AI")
        XCTAssertEqual(LegacyIdentity.googleCalendarClientKeyProperty, "supersparrowKey")
    }

    /// Exactly these, nothing broader: the old app's derived state, no user data.
    func testTheOldAppsLeftoversAreExactlyItsPerBundleState() {
        XCTAssertEqual(LegacyIdentity.leftovers(inLibrary: root).map(\.path), [
            "/private/tmp/identity-tests/WebKit/io.supersparrow.mac",
            "/private/tmp/identity-tests/HTTPStorages/io.supersparrow.mac",
            "/private/tmp/identity-tests/HTTPStorages/io.supersparrow.mac.binarycookies",
            "/private/tmp/identity-tests/Saved Application State/io.supersparrow.mac.savedState",
        ])
    }
}
