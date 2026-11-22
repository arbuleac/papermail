import PaperCore
import XCTest
@testable import PaperApp

/// The network coming back wakes the engine once (it then checks for mail at once instead of waiting out its
/// backoff); paths that stay up, or go down, do not. Driven without a real path monitor, as is the outbox count.
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

    /// The sending count follows the outbox as it is written, not on a timer an idle window would keep: a held
    /// send is not counted, the send runner claiming it is, and its settling clears it, each well inside a second.
    /// Only the outbox is observed: the real network path reports whatever the machine has, and would add changes.
    func testTheSendingCountFollowsTheOutboxAsItChanges() throws {
        let store = try SQLiteMailStore.inMemory()
        let account = ListTestSupport.accountA
        try store.upsertAccount(account)
        let monitor = SyncActivityMonitor(store: store)
        var changes = 0
        monitor.onChange = { changes += 1 }
        monitor.startObservingSends()
        defer { monitor.stop() }
        ListTestSupport.spin(for: 0.1)
        let message = OutgoingMessage(accountID: account.id, to: [EmailAddress(address: "you@example.com")], subject: "Hello",
                                      html: "<p>Hi</p>", text: "Hi")
        // An hour, so no stall of the test machine can carry the send out of its window.
        var send = PendingSend(message: message, sendAfter: Date().addingTimeInterval(3_600))
        try store.enqueueSend(send)
        XCTAssertTrue(ListTestSupport.spin(until: { monitor.windowTimerFireDate != nil }, timeout: 2))
        XCTAssertEqual(monitor.sendingCount, 0, "inside its undo window")
        XCTAssertEqual(changes, 0)
        send.status = .sending
        send.attempts = 1
        try store.updateSend(send)
        XCTAssertTrue(ListTestSupport.spin(until: { monitor.sendingCount == 1 }, timeout: 2))
        XCTAssertEqual(changes, 1)
        XCTAssertNil(monitor.windowTimerFireDate, "nothing held, so no timer")
        try store.deleteSend(id: send.id)
        XCTAssertTrue(ListTestSupport.spin(until: { monitor.sendingCount == 0 }, timeout: 2))
        XCTAssertEqual(changes, 2)
    }

    /// The send runner delivers one send at a time, so a send whose window ends while another uploads is not written
    /// until that upload settles and no observation fires. The count takes it in at the end of its window anyway, on
    /// a one-shot timer set for that moment, and keeps no timer once nothing is held. The monitor's clock is the
    /// test's, so the window ends when the test says, however slowly the machine runs.
    func testASendWhoseWindowEndsWhileAnotherUploadsIsCountedThen() throws {
        let store = try SQLiteMailStore.inMemory()
        let account = ListTestSupport.accountA
        try store.upsertAccount(account)
        let message = OutgoingMessage(accountID: account.id, to: [EmailAddress(address: "you@example.com")], subject: "Hello",
                                      html: "<p>Hi</p>", text: "Hi")
        let start = Date()
        var uploading = PendingSend(message: message, sendAfter: start)
        uploading.status = .sending
        uploading.attempts = 1
        try store.enqueueSend(uploading)
        // An hour out on the real clock too, so the timer never fires by itself while the test runs.
        let held = PendingSend(message: message, sendAfter: start.addingTimeInterval(3_600))
        try store.enqueueSend(held)
        var clock = start
        let monitor = SyncActivityMonitor(store: store, now: { clock })
        var counts: [Int] = []
        monitor.onChange = { counts.append(monitor.sendingCount) }
        monitor.startObservingSends()
        defer { monitor.stop() }
        XCTAssertTrue(ListTestSupport.spin(until: { !counts.isEmpty }, timeout: 2))
        XCTAssertEqual(counts, [1], "the upload, not the send inside its window")
        let fireDate = try XCTUnwrap(monitor.windowTimerFireDate, "a timer at the end of the held send's window")
        // The store keeps send times to the millisecond.
        XCTAssertEqual(fireDate.timeIntervalSince1970, held.sendAfter.timeIntervalSince1970, accuracy: 0.001)

        clock = fireDate
        monitor.fireWindowTimer()
        XCTAssertEqual(monitor.sendingCount, 2, "counted at the end of its window")
        XCTAssertEqual(counts, [1, 2])
        XCTAssertNil(monitor.windowTimerFireDate, "nothing held, so no timer")
        try store.deleteSend(id: uploading.id)
        try store.deleteSend(id: held.id)
        XCTAssertTrue(ListTestSupport.spin(until: { monitor.sendingCount == 0 }, timeout: 2))
        XCTAssertNil(monitor.windowTimerFireDate)
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
