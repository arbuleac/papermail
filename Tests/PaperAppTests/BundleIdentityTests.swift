import Foundation
import PaperCore
import XCTest
@testable import PaperApp

/// The bundle's Info.plist names the app as `AppIdentity` does (docs/ARCHITECTURE.md, "Identity"): the bundle
/// identifier the logs, folders and Keychain items are named for, the executable `scripts/build-app.sh` copies in,
/// and the application class AppKit makes.
final class BundleIdentityTests: XCTestCase {
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testInfoPlistNamesTheAppAsAppIdentityDoes() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, AppIdentity.bundleIdentifier)
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, AppIdentity.name, "the executable product, so the bare binary's defaults domain is the name too")
        XCTAssertEqual(plist["CFBundleName"] as? String, AppIdentity.name)
        XCTAssertEqual(plist["CFBundleDisplayName"] as? String, AppIdentity.name)
        XCTAssertEqual(plist["NSPrincipalClass"] as? String, NSStringFromClass(PaperApplication.self))
        XCTAssertEqual(NSStringFromClass(PaperApplication.self), "PaperApplication")
    }

    func testTheBundleIsSignedWithTheAppsEntitlements() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Resources/Paper.entitlements").path))
    }

    /// What the Finder's “downloaded by” line names on an attachment saved from a message.
    func testAttachmentsAreQuarantinedInTheAppsName() {
        XCTAssertEqual(AttachmentSafety.agentName, AppIdentity.name)
    }
}
