import AppKit
import PaperCore
import XCTest
@testable import PaperApp

/// The rail's pending tile and the sync line's waiting state follow the sign-in that is really running
/// (spec §5.44), wherever it started, with no guessing from timing.
@MainActor
final class SignInProgressTests: XCTestCase {
    override func tearDown() {
        MainActor.assumeIsolated { SignInProgress.post(nil) }
        super.tearDown()
    }

    func testAnAddFromAnywhereShowsThePendingTileAndCancel() throws {
        let harness = try MainWindowHarness()
        // Started from Settings or the File menu: the window never asked for it, and still shows it.
        SignInProgress.post(SignInProgress(kind: .microsoft, reconnecting: nil, subject: "Microsoft 365"))
        XCTAssertEqual(harness.controller.pendingSignIn, .adding(.microsoft))
        XCTAssertTrue(harness.controller.strip.showsPendingTile)
        let line = harness.controller.listPane.statusBar.summary
        XCTAssertEqual(line.state, .signingIn)
        XCTAssertEqual(line.action, .cancelSignIn)
        // Cancel (or success): the tile and the waiting line leave at once.
        SignInProgress.post(nil)
        XCTAssertNil(harness.controller.pendingSignIn)
        XCTAssertFalse(harness.controller.strip.showsPendingTile)
        XCTAssertNotEqual(harness.controller.listPane.statusBar.summary.state, .signingIn)
        harness.close()
    }

    func testAReconnectKeepsTheTileAndWaitsOnTheLine() throws {
        let harness = try MainWindowHarness()
        let account = ListTestSupport.accountB
        SignInProgress.post(SignInProgress(kind: account.kind, reconnecting: account.id, subject: "Fabrikam"))
        XCTAssertEqual(harness.controller.pendingSignIn, .reconnecting(account.id))
        XCTAssertFalse(harness.controller.strip.showsPendingTile, "a reconnect adds no tile")
        XCTAssertEqual(harness.controller.listPane.statusBar.summary.state, .signingIn)
        harness.close()
    }

    func testAWindowBuiltMidSignInShowsIt() throws {
        SignInProgress.post(SignInProgress(kind: .gmail, reconnecting: nil, subject: "Gmail"))
        let harness = try MainWindowHarness()
        XCTAssertEqual(harness.controller.pendingSignIn, .adding(.gmail))
        XCTAssertTrue(harness.controller.strip.showsPendingTile)
        harness.close()
    }
}

/// The welcome's waiting button follows the same progress (§5.39).
@MainActor
final class WelcomeSignInTests: XCTestCase {
    func testTheWelcomeWaitsForTheProviderThatIsRunning() {
        let welcome = WelcomeViewController()
        welcome.showSignIn(SignInProgress(kind: .microsoft, reconnecting: nil, subject: "Microsoft 365"))
        XCTAssertEqual(welcome.activity, .waiting(.microsoft))
        welcome.showSignIn(nil)
        XCTAssertEqual(welcome.activity, .idle)
        welcome.setActivity(.preparingDemo)
        welcome.showSignIn(nil)
        XCTAssertEqual(welcome.activity, .preparingDemo, "the end of a sign-in never ends Preparing the demo")
        welcome.setActivity(.idle)
        welcome.showSignIn(SignInProgress(kind: .gmail, reconnecting: AccountID("acct"), subject: "Contoso"))
        XCTAssertEqual(welcome.activity, .idle, "a reconnect has nothing to show on the welcome")
    }
}
