import Foundation
import XCTest

/// The bundle's App Transport Security policy, read from the Info.plist `scripts/build-app.sh` copies into the app.
/// WebKit holds every load the reader's web view makes to this policy, so one that requires TLS everywhere leaves a
/// message's plain-http images broken however they are allowed (the preference, Load images): the shell asks for
/// them, no policy of its own stands in the way, and the networking process refuses them with
/// `NSURLErrorAppTransportSecurityRequiresSecureConnection` (-1022). The test process has its own bundle, so this
/// cannot be shown through a web view here; the policy is checked where it lives.
final class AppTransportSecurityTests: XCTestCase {
    func testTheReaderMayLoadImagesOverPlainHTTP() throws {
        XCTAssertEqual(try policy()["NSAllowsArbitraryLoadsInWebContent"] as? Bool, true,
                       "message bodies may load http images, as https ones, once the user lets their images load")
    }

    /// The exemption is for web content alone: OAuth, Gmail, Graph and unsubscribe requests keep requiring TLS.
    func testTheAppsOwnConnectionsStillRequireTLS() throws {
        let policy = try policy()
        for key in ["NSAllowsArbitraryLoads", "NSAllowsArbitraryLoadsForMedia", "NSExceptionDomains"] {
            XCTAssertNil(policy[key], "\(key) would lift the policy beyond the reader's web content")
        }
    }

    private func policy() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try XCTUnwrap(plist["NSAppTransportSecurity"] as? [String: Any], "the bundle states its transport policy")
    }
}
