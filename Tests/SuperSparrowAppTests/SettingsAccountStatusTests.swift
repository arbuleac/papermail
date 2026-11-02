import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// Settings › Accounts shows the engine's progress (spec §5.40): “Downloading · N of M” with its bar while the
/// provider gives a total, and “Retrying in 30 s” while an account waits to try again.
@MainActor
final class SettingsAccountStatusTests: XCTestCase {
    private let account = ListTestSupport.accountA

    private func model(_ status: AccountSyncStatus) -> SettingsModel {
        let model = SettingsModel(isDemo: false, oauthFileURL: FileManager.default.temporaryDirectory.appendingPathComponent("absent-\(UUID()).json"))
        model.setAccounts([account])
        model.statuses = [account.id: status]
        return model
    }

    func testDownloadingCountsAgainstTheProvidersTotal() {
        let status = model(AccountSyncStatus(accountID: account.id, phase: .bootstrapping, bootstrapProgress: 3_412, bootstrapTotal: 8_120))
            .status(for: account)
        XCTAssertEqual(status, .downloading(done: 3_412, total: 8_120))
        XCTAssertNotNil(status.progress, "the determinate bar")
        let unknown = model(AccountSyncStatus(accountID: account.id, phase: .bootstrapping, bootstrapProgress: 3_412)).status(for: account)
        XCTAssertNil(unknown.progress)
    }

    func testRetryingSaysWhen() {
        let retryAt = Date().addingTimeInterval(29.5)
        let status = model(AccountSyncStatus(accountID: account.id, phase: .paused, message: "Rate limited; retrying shortly", retryAt: retryAt))
            .status(for: account)
        XCTAssertEqual(status.words, "Retrying in 30 s")
        let shortly = model(AccountSyncStatus(accountID: account.id, phase: .paused, message: "Rate limited; retrying shortly"))
            .status(for: account)
        XCTAssertEqual(shortly.words, "Retrying shortly")
    }
}
