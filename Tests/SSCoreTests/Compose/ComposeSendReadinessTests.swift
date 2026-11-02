import XCTest
@testable import SSCore

final class ComposeSendReadinessTests: XCTestCase {
    private let ben = EmailAddress(name: "Ben Carter", address: "ben@contoso.test")
    private let desk = EmailAddress(address: "it-desk@contoso")

    func testNoRecipientAsksForOne() {
        let readiness = ComposeSendReadiness.evaluate(tokens: [], pendingText: ["", " "])
        XCTAssertEqual(readiness, ComposeSendReadiness(isEnabled: false, tooltip: "Add a recipient"))
    }

    func testOnlyInvalidRecipientsNameTheAddressToFix() {
        let readiness = ComposeSendReadiness.evaluate(tokens: [desk], pendingText: [""])
        XCTAssertEqual(readiness, ComposeSendReadiness(isEnabled: false, tooltip: "Fix the address it-desk@contoso"))
    }

    /// §5.23 disables Send only without a valid recipient; the specimen draws it enabled beside an invalid
    /// token, and pressing it validates instead of sending.
    func testAValidRecipientBesideAnInvalidOneKeepsSendEnabled() {
        let readiness = ComposeSendReadiness.evaluate(tokens: [ben, desk], pendingText: [])
        XCTAssertTrue(readiness.isEnabled)
        XCTAssertEqual(readiness.tooltip, "Send  ⌘↩")
    }

    func testTypedTextCountsOnceItIsAnAddress() {
        XCTAssertTrue(ComposeSendReadiness.evaluate(tokens: [], pendingText: ["ben@contoso.test"]).isEnabled)
        let partial = ComposeSendReadiness.evaluate(tokens: [], pendingText: ["ben@con"])
        XCTAssertFalse(partial.isEnabled)
        // Text still being written is not called invalid.
        XCTAssertEqual(partial.tooltip, "Add a recipient")
    }
}
