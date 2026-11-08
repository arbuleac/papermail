import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// Settings › Accounts ticks its clock once a second only while its window is open and a row counts a retry down
/// (“Retrying in 30 s”, spec §5.40). A closed window keeps its model, fed by the engine, for the next show; and during
/// an outage a retry is ahead almost all the time behind rows that read Offline or Couldn't sync (Q1.7d).
@MainActor
final class SettingsRetryClockTests: XCTestCase {
    private let a = ListTestSupport.accountA
    private let b = ListTestSupport.accountB

    private func model(_ statuses: [AccountSyncStatus], open: Bool = true) -> SettingsModel {
        let model = SettingsModel(isDemo: false, oauthFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID()).json"))
        model.setAccounts([a, b])
        model.isWindowOpen = open
        model.statuses = Dictionary(uniqueKeysWithValues: statuses.map { ($0.accountID, $0) })
        return model
    }

    private func networkFailed(_ account: Account, retryIn seconds: TimeInterval = 30) -> AccountSyncStatus {
        AccountSyncStatus(accountID: account.id, phase: .error, message: "network: offline", retryAt: Date().addingTimeInterval(seconds))
    }

    /// A network failure while the other account is syncing reads Retrying, with a count.
    private var retrying: [AccountSyncStatus] { [networkFailed(a), AccountSyncStatus(accountID: b.id, phase: .syncing)] }

    func testTheClockRunsOnlyWhileTheWindowIsOpen() {
        let model = model(retrying, open: false)
        XCTAssertEqual(model.status(for: a).words, "Retrying in 30 s")
        XCTAssertFalse(model.isRetryClockRunning, "a closed window ticks for nobody")
        model.isWindowOpen = true
        XCTAssertTrue(model.isRetryClockRunning)
        model.isWindowOpen = false
        XCTAssertFalse(model.isRetryClockRunning)
    }

    func testRowsWithoutACountKeepNoClock() {
        let offline = model([networkFailed(a), networkFailed(b, retryIn: 50)])
        XCTAssertEqual(offline.status(for: a).words, "Offline")
        XCTAssertFalse(offline.isRetryClockRunning, "Offline shows no count")

        let failed = AccountSyncStatus(accountID: a.id, phase: .error, message: "server 500: unavailable", retryAt: Date().addingTimeInterval(55))
        let couldntSync = model([failed, AccountSyncStatus(accountID: b.id, phase: .idle, lastSuccessfulSyncAt: Date())])
        XCTAssertFalse(couldntSync.isRetryClockRunning, "Couldn't sync shows no count")

        let throttled = AccountSyncStatus(accountID: a.id, phase: .paused, message: "Rate limited; retrying shortly",
                                          retryAt: Date().addingTimeInterval(20))
        XCTAssertTrue(model([throttled]).isRetryClockRunning, "a throttle counts down")
    }

    /// The window controller opens and closes the model's window: closing stops the clock and later statuses do not
    /// start it, and showing the window again does.
    func testClosingTheWindowStopsTheClock() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsRetryClockTests-\(UUID().uuidString)")
        let environment = try AppEnvironment.makeScratch(in: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try environment.store.upsertAccount(a)
        try environment.store.upsertAccount(b)
        let controller = SettingsWindowController(environment: environment, settings: ListTestSupport.settings())
        defer { controller.tearDown() }
        // The engine's first status report, an empty one, lands before the test writes its own.
        ListTestSupport.spin(for: 0.2)
        let window = try XCTUnwrap(controller.window)
        window.setFrameAutosaveName("")
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        XCTAssertFalse(controller.model.isWindowOpen)

        controller.show()
        controller.model.statuses = Dictionary(uniqueKeysWithValues: retrying.map { ($0.accountID, $0) })
        XCTAssertTrue(controller.model.isRetryClockRunning)

        window.performClose(nil)
        XCTAssertFalse(window.isVisible)
        XCTAssertFalse(controller.model.isRetryClockRunning, "closed")
        controller.model.statuses = Dictionary(uniqueKeysWithValues: [networkFailed(a, retryIn: 40),
                                                                      AccountSyncStatus(accountID: b.id, phase: .syncing)].map { ($0.accountID, $0) })
        XCTAssertFalse(controller.model.isRetryClockRunning, "a status arriving while closed starts nothing")

        controller.show()
        XCTAssertTrue(controller.model.isRetryClockRunning, "shown again")
        window.performClose(nil)
    }
}
