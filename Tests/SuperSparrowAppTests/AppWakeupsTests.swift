import AppKit
import XCTest
@testable import SuperSparrowApp

/// Coming to the front tells the engine and checks at once, leaving it tells the engine, and waking from sleep
/// checks at once (the live lane's 5 s and 30 s intervals depend on the first two). Posted on private centers,
/// so nothing depends on the test runner being frontmost.
@MainActor
final class AppWakeupsTests: XCTestCase {
    private final class Calls {
        var active: [Bool] = []
        var checks = 0
    }

    // Fresh for every test: XCTest makes a new instance per test method.
    private let appCenter = NotificationCenter()
    private let workspaceCenter = NotificationCenter()
    /// Held as the app delegate holds it.
    private var wakeups: AppWakeups?

    private func listen() -> Calls {
        let calls = Calls()
        wakeups = AppWakeups(appCenter: appCenter, workspaceCenter: workspaceCenter,
                             setActive: { calls.active.append($0) }, checkAll: { calls.checks += 1 })
        return calls
    }

    func testComingToTheFrontTellsTheEngineAndChecks() {
        let calls = listen()
        appCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(calls.active, [true])
        XCTAssertEqual(calls.checks, 1)
    }

    func testLeavingTheFrontTellsTheEngineWithoutChecking() {
        let calls = listen()
        appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
        XCTAssertEqual(calls.active, [false])
        XCTAssertEqual(calls.checks, 0)
    }

    func testWakingFromSleepChecksOnce() {
        let calls = listen()
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(calls.checks, 1)
        XCTAssertEqual(calls.active, [], "waking says nothing about which app is frontmost")
    }

    func testEachNotificationIsHeardOnlyOnItsOwnCenter() {
        // NSWorkspace posts on its own center, not the default one; listening on the wrong one would never fire.
        let calls = listen()
        appCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        workspaceCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(calls.checks, 0)
        XCTAssertEqual(calls.active, [])
    }

    func testARoundTrip() {
        let calls = listen()
        appCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        appCenter.post(name: NSApplication.didResignActiveNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        appCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(calls.active, [true, false, true])
        XCTAssertEqual(calls.checks, 3)
    }

    func testStoppingStopsListening() {
        let calls = listen()
        wakeups?.stop()
        appCenter.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        workspaceCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        XCTAssertEqual(calls.active, [])
        XCTAssertEqual(calls.checks, 0)
    }
}
