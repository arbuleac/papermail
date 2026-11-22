import AppKit
import XCTest
@testable import PaperDesign

/// Badge capping (spec §5.28) and the spinner's own delay, fade and rotation (§5.37).
@MainActor
final class BadgeAndSpinnerTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    // MARK: Badges

    func testUnreadCountsCapAt99Plus() {
        XCTAssertEqual(Quire.Layout.Badge.cap, 99)
        XCTAssertEqual(QuireBadge.text(for: .unread(0)), "0")
        XCTAssertEqual(QuireBadge.text(for: .unread(7)), "7")
        XCTAssertEqual(QuireBadge.text(for: .unread(99)), "99")
        XCTAssertEqual(QuireBadge.text(for: .unread(100)), "99+")
        XCTAssertEqual(QuireBadge.text(for: .unread(128)), "99+")
        XCTAssertEqual(QuireBadge.text(for: .unread(120_000)), "99+")
        XCTAssertEqual(QuireBadge.text(for: .unread(-3)), "0", "a negative count never shows")
        XCTAssertNil(QuireBadge.text(for: .dot))
        XCTAssertNil(QuireBadge.text(for: .attention))
    }

    /// One formatter for every unread count, the Dock's included: nothing at zero, so the Dock badge clears.
    func testUnreadTextIsTheOneFormatterTheRailAndTheDockRead() {
        XCTAssertNil(QuireBadge.unreadText(0), "no badge, not “0”")
        XCTAssertNil(QuireBadge.unreadText(-3))
        XCTAssertEqual(QuireBadge.unreadText(1), "1")
        XCTAssertEqual(QuireBadge.unreadText(99), "99")
        XCTAssertEqual(QuireBadge.unreadText(100), "99+")
        XCTAssertEqual(QuireBadge.unreadText(1_234), "99+", "never the grouped number")
        for count in [1, 7, 99, 100, 128, 1_234, 120_000] {
            XCTAssertEqual(QuireBadge.text(for: .unread(count)), QuireBadge.unreadText(count), "the rail's badge reads the same for \(count)")
        }
        XCTAssertEqual(QuireBadge.unreadAccessibilityText(1_234), "\(1_234.formatted(.number.grouping(.automatic))) unread",
                       "VoiceOver hears the real count")
        XCTAssertEqual(QuireBadge(.unread(1_234)).accessibilityLabel(), QuireBadge.unreadAccessibilityText(1_234))
    }

    func testMessageCountsAreExactInTheLocalesGrouping() {
        XCTAssertEqual(QuireBadge.text(for: .messageCount(4)), "4")
        XCTAssertEqual(QuireBadge.text(for: .messageCount(140)), "140", "row counts are not capped")
        XCTAssertEqual(QuireBadge.text(for: .messageCount(3412)), 3412.formatted(.number.grouping(.automatic)))
    }

    func testCappingKeepsTheBadgeWidthStable() {
        XCTAssertEqual(QuireBadge(.unread(100)).intrinsicContentSize, QuireBadge(.unread(5_000)).intrinsicContentSize)
        XCTAssertLessThan(QuireBadge(.unread(9)).intrinsicContentSize.width, QuireBadge(.unread(100)).intrinsicContentSize.width)
    }

    func testBadgeNumeralsAreTabularRounded() {
        XCTAssertTrue(QuireFont.Role.badge.tabular)
        XCTAssertEqual(QuireFont.Role.badge.family, .rounded)
        XCTAssertEqual(QuireFont.Role.badge.weight, 600)
        // Tabular digits: every numeral has the same advance, so counts do not jitter.
        let widths = (0...9).map { QuireFont.attributedString("\($0)", role: .badge, color: .black).size().width }
        XCTAssertEqual(Set(widths.map { ($0 * 100).rounded() }).count, 1)
    }

    // MARK: Spinner

    private func hostedSpinner(delay: TimeInterval? = nil) -> (QuireSpinnerView, NSWindow) {
        let spinner = QuireSpinnerView()
        if let delay { spinner.delay = delay }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(spinner)
        return (spinner, window)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func testSpinnerWaits150MillisecondsBeforeAppearing() {
        XCTAssertEqual(Quire.Motion.spinnerDelay, 0.15)
        let (spinner, window) = hostedSpinner()
        XCTAssertEqual(spinner.delay, 0.15)
        spinner.startAnimation()
        XCTAssertTrue(spinner.isAnimating)
        XCTAssertFalse(spinner.isRevealed, "nothing shows at once")
        XCTAssertFalse(spinner.isTurning)
        spin(0.08)
        XCTAssertFalse(spinner.isRevealed, "still nothing before 150 ms")
        let revealed = expectation(description: "revealed")
        spinner.onReveal = { revealed.fulfill() }
        wait(for: [revealed], timeout: 2)
        XCTAssertTrue(spinner.isRevealed)
        XCTAssertTrue(spinner.isTurning, "turns once shown in a window")
        XCTAssertTrue(spinner.isAccessibilityElement())
        spinner.stopAnimation()
        XCTAssertFalse(spinner.isRevealed)
        XCTAssertFalse(spinner.isTurning)
        _ = window
    }

    func testWorkThatEndsSoonerNeverShowsASpinner() {
        let (spinner, window) = hostedSpinner()
        var revealed = false
        spinner.onReveal = { revealed = true }
        spinner.startAnimation()
        spin(0.05)
        spinner.stopAnimation()
        spin(0.25)
        XCTAssertFalse(revealed)
        XCTAssertFalse(spinner.isRevealed)
        _ = window
    }

    func testRotationRunsOnlyWhileVisibleAndInAWindow() {
        let (spinner, window) = hostedSpinner(delay: 0)
        spinner.startAnimation()
        XCTAssertTrue(spinner.isRevealed)
        XCTAssertTrue(spinner.isTurning)
        spinner.isHidden = true
        XCTAssertFalse(spinner.isTurning, "removed while hidden")
        spinner.isHidden = false
        XCTAssertTrue(spinner.isTurning)
        spinner.removeFromSuperview()
        XCTAssertFalse(spinner.isTurning, "removed off-window")
        window.contentView?.addSubview(spinner)
        XCTAssertTrue(spinner.isTurning)
    }

    func testSpinnerKeepsTurningUnderReduceMotionAndIgnoresFinishAll() {
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: true, reduceTransparency: false))
        let (spinner, window) = hostedSpinner(delay: 0)
        spinner.startAnimation()
        XCTAssertTrue(spinner.isTurning, "spinners keep turning (§4.10)")
        Quire.Motion.finishAll()
        XCTAssertTrue(spinner.isTurning, "a keystroke never stops a spinner")
        _ = window
    }

    func testButtonSpinnerFollowsLoading() {
        let button = QuireButton(title: "Send", variant: .primary)
        button.loadingTitle = "Sending…"
        XCTAssertNil(button.spinner)
        button.isLoading = true
        XCTAssertNotNil(button.spinner)
        XCTAssertTrue(button.spinner?.isAnimating ?? false)
        XCTAssertFalse(button.spinner?.isRevealed ?? true, "the button's spinner keeps the 150 ms delay too")
        button.isLoading = false
        XCTAssertNil(button.spinner)
    }
}
