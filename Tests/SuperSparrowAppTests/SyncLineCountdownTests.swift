import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// The sync line chooses itself again every second only while it counts a retry down on screen (“retrying in 30 s”,
/// spec §5.11). During an outage the engine keeps a retry ahead almost all the time, behind a line that reads
/// Offline or Couldn't sync and shows no count, so an idle window keeps no timer then (Q1.7d).
@MainActor
final class SyncLineCountdownTests: XCTestCase {
    private var harness: MainWindowHarness!
    private let a = ListTestSupport.accountA
    private let b = ListTestSupport.accountB

    override func setUpWithError() throws {
        harness = try MainWindowHarness()
        // The harness parks its window off screen, which the window server reports as not visible.
        harness.controller.syncLineVisibilityOverride = true
        // The real network path is whatever the machine running the tests has; without one every line here would
        // read Offline. The window is told the path is up instead, and the monitor stops before it can say otherwise.
        harness.controller.checkAllAccounts = {}
        harness.controller.activity.stop()
        ListTestSupport.spin(for: 0.1)
        harness.controller.activity.setReachable(true)
    }

    override func tearDown() {
        harness.close()
        harness = nil
    }

    private var line: SyncLineSummary { harness.controller.listPane.statusBar.summary }

    private func networkFailed(_ account: Account, retryIn seconds: TimeInterval) -> AccountSyncStatus {
        AccountSyncStatus(accountID: account.id, phase: .error, message: "network: offline", retryAt: Date().addingTimeInterval(seconds))
    }

    func testOfflineKeepsNoTimerWhileARetryIsAhead() {
        harness.controller.statusesChanged([networkFailed(a, retryIn: 55), networkFailed(b, retryIn: 40)])
        XCTAssertEqual(line.state, .offline)
        XCTAssertFalse(harness.controller.isCountingDownRetry, "Offline shows no count")
    }

    func testCouldntSyncKeepsNoTimerWhileARetryIsAhead() {
        let failed = AccountSyncStatus(accountID: a.id, phase: .error, message: "server 500: unavailable",
                                       retryAt: Date().addingTimeInterval(55))
        harness.controller.statusesChanged([failed, AccountSyncStatus(accountID: b.id, phase: .idle, lastSuccessfulSyncAt: Date())])
        XCTAssertEqual(line.state, .error)
        XCTAssertFalse(harness.controller.isCountingDownRetry, "Couldn't sync shows no count")
    }

    func testSlowCountsDownOnlyWhileTheWindowIsSeen() {
        let throttled = AccountSyncStatus(accountID: a.id, phase: .paused, message: "Rate limited; retrying shortly",
                                          retryAt: Date().addingTimeInterval(30))
        harness.controller.statusesChanged([throttled, AccountSyncStatus(accountID: b.id, phase: .idle, lastSuccessfulSyncAt: Date())])
        XCTAssertEqual(line.state, .slow)
        XCTAssertTrue(line.countsDown)
        XCTAssertTrue(harness.controller.isCountingDownRetry, "“retrying in 30 s” ticks")

        harness.controller.syncLineVisibilityOverride = false
        harness.controller.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification))
        XCTAssertFalse(harness.controller.isCountingDownRetry, "an occluded window keeps no timer")
        harness.controller.syncLineVisibilityOverride = true
        harness.controller.windowDidChangeOcclusionState(Notification(name: NSWindow.didChangeOcclusionStateNotification))
        XCTAssertTrue(harness.controller.isCountingDownRetry, "and counts again once seen")
    }

    /// Under Couldn't sync, another account's retry is counted in the tooltip alone. Nothing ticks it, so the line
    /// brings it up to date as the pointer arrives, before the tooltip shows.
    func testATooltipCountdownIsUpToDateWhenHovered() throws {
        let failed = AccountSyncStatus(accountID: a.id, phase: .error, message: "server 500: unavailable")
        harness.controller.statusesChanged([failed, networkFailed(b, retryIn: 1.5)])
        XCTAssertEqual(line.state, .error)
        XCTAssertFalse(harness.controller.isCountingDownRetry)
        let before = try XCTUnwrap(line.tooltip)
        XCTAssertTrue(before.hasSuffix("Retrying in 2 s"), before)
        // Time only moves on, so after this the count reads 1 s or “shortly”, however long the machine stalls.
        ListTestSupport.spin(for: 0.6)
        XCTAssertEqual(line.tooltip, before, "no timer moved it")
        let bar = harness.controller.listPane.statusBar
        let enter = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
                                                         windowNumber: bar.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                                         trackingNumber: 0, userData: nil))
        bar.mouseEntered(with: enter)
        let after = try XCTUnwrap(line.tooltip)
        XCTAssertNotEqual(after, before)
        XCTAssertFalse(after.contains("Retrying in 2 s"), after)
    }
}
