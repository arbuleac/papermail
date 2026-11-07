import SSCore
import XCTest
@testable import SuperSparrowApp

/// The network coming back wakes the engine once (it then checks for mail at once instead of waiting out its
/// backoff); paths that stay up, or go down, do not. Driven without a real path monitor.
@MainActor
final class SyncActivityMonitorTests: XCTestCase {
    private func monitor() throws -> (SyncActivityMonitor, returns: () -> Int) {
        let monitor = SyncActivityMonitor(store: try SQLiteMailStore.inMemory())
        var count = 0
        monitor.onNetworkReturned = { count += 1 }
        return (monitor, { count })
    }

    func testAReturningPathWakesTheEngineOncePerReturn() throws {
        let (monitor, returns) = try monitor()
        monitor.setReachable(false)
        XCTAssertEqual(returns(), 0, "losing the path is not a return")
        XCTAssertFalse(monitor.isNetworkReachable)
        monitor.setReachable(true)
        XCTAssertEqual(returns(), 1)
        monitor.setReachable(true)
        XCTAssertEqual(returns(), 1, "a path that stays up reports nothing new")
        monitor.setReachable(false)
        monitor.setReachable(true)
        XCTAssertEqual(returns(), 2)
    }

    func testAPathThatWasUpFromTheStartIsNotAReturn() throws {
        let (monitor, returns) = try monitor()
        monitor.setReachable(true)
        XCTAssertEqual(returns(), 0)
        XCTAssertTrue(monitor.isNetworkReachable)
    }
}

/// The main window answers the network coming back by checking every account, once per return.
@MainActor
final class MainWindowNetworkReturnTests: XCTestCase {
    func testTheWindowChecksEveryAccountWhenTheNetworkReturns() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        var checks = 0
        harness.controller.checkAllAccounts = { checks += 1 }
        let activity = harness.controller.activity
        activity.setReachable(false)
        XCTAssertEqual(checks, 0, "losing the path checks nothing")
        activity.setReachable(true)
        XCTAssertEqual(checks, 1)
        activity.setReachable(true)
        XCTAssertEqual(checks, 1, "a path that stays up checks nothing more")
    }
}
