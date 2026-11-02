import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// After a successful add the welcome cross-fades to the inbox (spec §5.39) through `Quire.Motion`.
@MainActor
final class WelcomeCrossFadeTests: XCTestCase {
    func testTheFirstAccountCrossFadesFromTheWelcomeToTheInbox() throws {
        let harness = try MainWindowHarness(accounts: false)
        let window = try XCTUnwrap(harness.controller.window)
        harness.controller.showWindow(nil)
        defer { harness.close() }
        XCTAssertTrue(window.contentViewController is WelcomeViewController)

        try MainWindowHarness.seed(harness.environment.store)
        harness.controller.refreshAccounts()
        XCTAssertTrue(window.contentViewController is MainSplitViewController, "the inbox is in place under the fade")
        let overlay = try XCTUnwrap(harness.controller.crossFadeOverlay, "the welcome's last frame fades out over it")
        XCTAssertEqual(window.childWindows?.contains(overlay), true)
        XCTAssertTrue(overlay.ignoresMouseEvents, "the inbox takes clicks from the first frame")
        // A key press finishes the fade at once.
        Quire.Motion.finishAll()
        XCTAssertNil(harness.controller.crossFadeOverlay)
        XCTAssertEqual(window.childWindows?.contains(overlay) ?? false, false)
    }
}
