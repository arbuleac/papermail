import PaperCore
import XCTest
@testable import PaperApp

/// What a launch shows instead of opening anything after the first launch's move (docs/ARCHITECTURE.md, "Identity"):
/// whenever the old app's mailbox is not in Paper's folder yet, main.swift opens no store, since one started there would
/// leave the old mailbox where it is for good.
@MainActor
final class IdentityHoldAlertTests: XCTestCase {
    func testOnlyALaunchWhoseMailboxIsInPlaceOpens() {
        for outcome: IdentityMigration.Outcome in [.notThisApp, .ran, .deferred(applicationSupportWaiting: false)] {
            XCTAssertNil(AppAlert.identityHold(for: outcome), "\(outcome)")
        }
        XCTAssertEqual(AppAlert.identityHold(for: .deferred(applicationSupportWaiting: true))?.title, "SuperSparrow is still open")
        XCTAssertEqual(AppAlert.identityHold(for: .leftBehind(.moveFailed))?.title, "Paper couldn't bring over your mail")
        XCTAssertEqual(AppAlert.identityHold(for: .leftBehind(.mailboxInBothFolders))?.title, "Paper already has a mailbox")
    }

    /// Each says where the old mailbox is and what to do, and quits: Esc and every button end the launch.
    func testTheAlertsSayWhereTheMailIsAndQuit() throws {
        let failed = AppAlert.mailboxNotMoved
        XCTAssertTrue(failed.body.contains("~/Library/Application Support/SuperSparrow"))
        XCTAssertTrue(failed.body.contains("nothing was lost"))
        XCTAssertEqual(failed.buttons.map(\.title), ["Quit"])
        XCTAssertEqual(failed.escapeIndex, 0)

        let both = AppAlert.mailboxInBothFolders
        XCTAssertTrue(both.body.contains("~/Library/Application Support/SuperSparrow"))
        XCTAssertTrue(both.body.contains("~/Library/Application Support/app.paperinbox.mac"))
        XCTAssertEqual(both.buttons.map(\.title), ["Show in Finder", "Quit"])
        XCTAssertEqual(both.escapeIndex, 1)
        XCTAssertFalse(both.buttons.contains { $0.role == .destructive })

        for alert in [failed, both] {
            XCTAssertTrue(AppAlert.specimens.contains { $0.title == alert.title }, "in the alert snapshot")
        }
    }
}
