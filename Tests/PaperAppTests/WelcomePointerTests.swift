import AppKit
import PaperCore
import PaperDesign
import XCTest
@testable import PaperApp

/// The pointer over the welcome screen (spec §4.17, §5.39): every button takes the hand at rest. While a sign-in waits,
/// the chosen provider's button stays enabled but loading and inert, so it shows the arrow, as do the disabled other
/// provider and the OAuth link; Cancel, which a click acts on, keeps the hand.
@MainActor
final class WelcomePointerTests: XCTestCase {
    func testAWaitingSignInLeavesTheHandOnlyOnCancel() throws {
        let welcome = WelcomeViewController()
        welcome.loadViewIfNeeded()
        let buttons = Dictionary(descendants(QuireButton.self, of: welcome.view).map { ($0.title, $0) }) { first, _ in first }
        let gmail = try XCTUnwrap(buttons["Add Gmail account"])
        let microsoft = try XCTUnwrap(buttons["Add Microsoft account"])
        let demo = try XCTUnwrap(buttons["Try the demo"])
        let oauth = try XCTUnwrap(buttons["Set up OAuth clients…"])
        for button in [gmail, microsoft, demo, oauth] {
            XCTAssertEqual(button.pointerRegions.map(\.cursor), [.pointingHand], button.title)
        }

        welcome.setActivity(.waiting(.gmail))
        XCTAssertTrue(gmail.isEnabled && gmail.isLoading, "enabled, loading and inert")
        XCTAssertEqual(gmail.pointerRegions.map(\.cursor), [.arrow])
        XCTAssertEqual(microsoft.pointerRegions.map(\.cursor), [.arrow])
        XCTAssertEqual(oauth.pointerRegions.map(\.cursor), [.arrow])
        XCTAssertEqual(demo.title, "Cancel")
        XCTAssertEqual(demo.pointerRegions.map(\.cursor), [.pointingHand])

        welcome.setActivity(.idle)
        XCTAssertTrue([gmail, microsoft, demo, oauth].allSatisfy { $0.pointerRegions.map(\.cursor) == [.pointingHand] })
    }

    private func descendants<T: NSView>(_ type: T.Type, of view: NSView?) -> [T] {
        guard let view else { return [] }
        let own: [T] = (view as? T).map { [$0] } ?? []
        return own + view.subviews.flatMap { descendants(type, of: $0) }
    }
}
