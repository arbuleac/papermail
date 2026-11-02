import AppKit
import SSCore
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The composer's chrome (spec §3.2, §8.7): its field rows start at the title-bar height AppKit actually laid
/// out, 28 pt on macOS 15 and 32 pt from 26 on. A release that changes the band moves the rows with it rather
/// than sliding them under the title.
@MainActor
final class ComposerChromeTests: XCTestCase {
    private var isMacOS26OrLater: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }

    func testFieldRowsStartAtTheMeasuredTitleBarHeight() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        // With two accounts the From row leads; with one it is hidden and To leads.
        for accounts in [[ListTestSupport.accountA, ListTestSupport.accountB], [ListTestSupport.accountA]] {
            let composer = ComposeWindowController(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                   mode: .new)
            let window = try XCTUnwrap(composer.window)
            XCTAssertNil(window.toolbar, "the composer keeps the plain system title bar")
            XCTAssertEqual(window.titleVisibility, .visible)
            XCTAssertTrue(window.titlebarAppearsTransparent)
            let content = try XCTUnwrap(window.contentView)
            content.layoutSubtreeIfNeeded()

            let band = QuireWindowChrome.titlebarHeight(of: window)
            XCTAssertEqual(band, isMacOS26OrLater ? Quire.Layout.Window.composerTitlebar26 : Quire.Layout.Window.composerTitlebar,
                           accuracy: 0.5)
            let rows = content.subviews.compactMap { $0 as? ComposeFieldRow }.filter { !$0.isHidden }
            XCTAssertEqual(rows.count, accounts.count > 1 ? 3 : 2, "From (with two accounts), To and Subject")
            let first = try XCTUnwrap(rows.min { $0.frame.minY < $1.frame.minY })
            XCTAssertTrue(content.isFlipped)
            XCTAssertEqual(first.frame.minY, band, accuracy: 0.01)
            // The band ends exactly where AppKit's unobscured content begins.
            let layout = content.convert(window.contentLayoutRect, from: nil)
            XCTAssertEqual(first.frame.minY, layout.minY, accuracy: 0.01)
            composer.close()
        }
    }
}
