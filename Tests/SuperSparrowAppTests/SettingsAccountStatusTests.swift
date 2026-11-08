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

    // MARK: Older mail behind Up to date

    func testOlderMailWithATotalReadsUpToDateWithTheDownloadingBar() {
        let checked = Date()
        let status = model(AccountSyncStatus(accountID: account.id, phase: .idle, lastSuccessfulSyncAt: checked, backfillProgress: 3_412,
                                             backfillTotal: 8_120)).status(for: account)
        XCTAssertEqual(status.words, "Up to date · older mail \(3_412.formatted()) of \(8_120.formatted())")
        XCTAssertEqual(status.mark, QuireAccountStatus.upToDate().mark, "the Up to date glyph, not a spinner")
        XCTAssertEqual(status.progress ?? 0, 3_412.0 / 8_120.0, accuracy: 0.0001, "the bar the Downloading row uses")
        XCTAssertEqual(status.tooltip, "Checked \(checked.formatted(date: .omitted, time: .shortened))")
        XCTAssertNil(status.actionTitle)
    }

    func testOlderMailWithoutATotalHasNoBar() {
        let status = model(AccountSyncStatus(accountID: account.id, phase: .idle, lastSuccessfulSyncAt: Date(), backfillProgress: 3_412))
            .status(for: account)
        XCTAssertEqual(status.words, "Up to date · older mail \(3_412.formatted())")
        XCTAssertNil(status.progress)
    }

    func testABackgroundCheckKeepsTheOlderMailWords() {
        let status = model(AccountSyncStatus(accountID: account.id, phase: .syncing, lastSuccessfulSyncAt: Date(), backfillProgress: 12,
                                             backfillTotal: 40)).status(for: account)
        XCTAssertEqual(status.words, "Up to date · older mail \(12.formatted()) of \(40.formatted())")
        XCTAssertNotNil(status.progress)
    }

    func testPausedOlderMailSaysUntilWhenAndNamesTheCause() {
        let resume = Date().addingTimeInterval(600)
        let status = model(AccountSyncStatus(accountID: account.id, phase: .idle, lastSuccessfulSyncAt: Date(), backfillProgress: 3_412,
                                             backfillTotal: 8_120, backfillPausedUntil: resume)).status(for: account)
        XCTAssertEqual(status.words, "Up to date · older mail paused until \(resume.formatted(date: .omitted, time: .shortened))")
        XCTAssertNil(status.progress, "nothing moves while paused")
        XCTAssertEqual(status.mark, QuireAccountStatus.upToDate().mark, "never the Retrying clock: new mail still arrives")
        XCTAssertTrue(status.tooltip?.hasSuffix("Gmail is limiting requests.") ?? false, status.tooltip ?? "no tooltip")
    }

    func testBodiesStillArrivingReadUpToDateDownloadingMessages() {
        let checked = Date()
        let status = model(AccountSyncStatus(accountID: account.id, phase: .idle, lastSuccessfulSyncAt: checked,
                                             backfillDownloadingBodies: true)).status(for: account)
        XCTAssertEqual(status.words, "Up to date · downloading messages…")
        XCTAssertEqual(status.mark, QuireAccountStatus.upToDate().mark, "the Up to date glyph: new mail is current")
        XCTAssertNil(status.progress)
        XCTAssertEqual(status.tooltip, "Checked \(checked.formatted(date: .omitted, time: .shortened))")
        let listing = model(AccountSyncStatus(accountID: account.id, phase: .idle, lastSuccessfulSyncAt: checked, backfillProgress: 12,
                                              backfillTotal: 40, backfillDownloadingBodies: true)).status(for: account)
        XCTAssertEqual(listing.words, "Up to date · older mail \(12.formatted()) of \(40.formatted())", "the listing's count comes first")
    }

    func testWithoutOlderMailUpToDateIsUnchanged() {
        let checked = Date()
        let status = model(AccountSyncStatus(accountID: account.id, phase: .idle, lastSuccessfulSyncAt: checked)).status(for: account)
        XCTAssertEqual(status, .upToDate(checked: checked.formatted(date: .omitted, time: .shortened)))
    }

    // MARK: Calendar permission (invitations, spec §5.14, §5.40)

    /// Mail is current, but an invitation the user answered waits for permission to update the calendar: the row asks
    /// with Reconnect, and the reconnect it starts is the one that adds the scope.
    func testAnAnswerWaitingForCalendarPermissionAsksToReconnect() throws {
        let waiting = AccountSyncStatus(accountID: account.id, phase: .idle, lastSuccessfulSyncAt: Date(), permissionsNeeded: [.calendar])
        let settings = model(waiting)
        let status = settings.status(for: account)
        XCTAssertEqual(status, .calendarPermission)
        XCTAssertEqual(status.words, "Calendar permission needed")
        XCTAssertEqual(status.actionTitle, "Reconnect")
        XCTAssertEqual(status.tooltip, "Answer invitations: SuperSparrow needs permission to update your calendar.")
        XCTAssertNil(status.addressReplacement, "the account still syncs: its address stays")

        var reconnected: [AccountID] = []
        settings.reconnect = { reconnected.append($0.id) }
        settings.performRowAction(try XCTUnwrap(settings.rows.first))
        XCTAssertEqual(reconnected, [account.id])

        XCTAssertEqual(model(AccountSyncStatus(accountID: account.id, phase: .needsReauth, permissionsNeeded: [.calendar])).status(for: account),
                       .signInRequired, "signing in again comes first, and asks for the calendar with it")
        XCTAssertEqual(SyncLineSummary.accountWords(waiting), "Calendar permission needed", "the sync line's tooltip says it too")
    }
}
