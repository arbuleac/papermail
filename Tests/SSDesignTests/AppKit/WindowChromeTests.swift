import AppKit
import XCTest
@testable import SSDesign

/// Spec §8.7 `WindowChromeTests`: the main window built off screen with the §3.2 configuration puts the lights
/// on the 52 pt band, and the rail derived from them clears them by 4 pt. A failure here means a macOS release
/// moved the lights: re-derive the title-bar metrics (§3.2) rather than nudging numbers.
@MainActor
final class WindowChromeTests: XCTestCase {
    private var isMacOS26OrLater: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }

    private func mainWindow() -> NSWindow {
        let window = QuireWindowChrome.makeMainWindow(title: "SuperSparrow")
        window.isReleasedWhenClosed = false
        window.contentView?.layoutSubtreeIfNeeded()
        return window
    }

    // MARK: The §3.2 configuration

    func testMainWindowCarriesTheEmptyUnifiedToolbar() throws {
        let window = mainWindow()
        let toolbar = try XCTUnwrap(window.toolbar, "without a toolbar AppKit draws the plain title bar")
        XCTAssertEqual(toolbar.identifier, "main")
        XCTAssertTrue(toolbar.items.isEmpty)
        XCTAssertEqual(window.toolbarStyle, .unified)
        XCTAssertEqual(window.titlebarSeparatorStyle, .none)
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertTrue(window.styleMask.isSuperset(of: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]))
        XCTAssertEqual(window.title, "SuperSparrow", "the title still names the window for the Window menu and VoiceOver")
    }

    func testDefaultAndMinimumSizes() throws {
        let window = mainWindow()
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.bounds.size, NSSize(width: 1280, height: 800))
        XCTAssertEqual(window.contentMinSize, NSSize(width: 960, height: 600))
    }

    // MARK: The lights

    func testCloseButtonCentreIsOnTheBandCentreLine() {
        let metrics = QuireWindowChrome.metrics(of: mainWindow())
        XCTAssertEqual(metrics.lightsCenterY, Quire.Layout.TrafficLights.centerY, accuracy: Quire.Layout.TrafficLights.tolerance)
        XCTAssertEqual(metrics.titlebarZone, Quire.Layout.Window.titlebarZone)
    }

    func testRailClearsTheZoomButtonByFourPoints() throws {
        let window = mainWindow()
        let content = try XCTUnwrap(window.contentView)
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        let zoomMaxX = zoom.convert(zoom.bounds, to: content).maxX
        let metrics = QuireWindowChrome.metrics(of: window)
        XCTAssertEqual(metrics.lightsEnd, zoomMaxX, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(metrics.railWidth, zoomMaxX + Quire.Layout.Rail.lightsClearance)
        XCTAssertEqual(metrics.railWidth.truncatingRemainder(dividingBy: 2), 0, "the rail width is even so tiles centre on whole points")
    }

    func testRailWidthPerRelease() {
        let metrics = QuireWindowChrome.metrics(of: mainWindow())
        if isMacOS26OrLater {
            XCTAssertEqual(metrics.lightsEnd, Quire.Layout.TrafficLights.endX26, accuracy: 0.5)
            XCTAssertEqual(metrics.railWidth, Quire.Layout.Rail.width26)
            XCTAssertEqual(metrics.mastheadMinimalX, Quire.Layout.ListHeader.mastheadMinimalX26)
        } else {
            XCTAssertEqual(metrics.lightsEnd, Quire.Layout.TrafficLights.endX, accuracy: 0.5)
            XCTAssertEqual(metrics.railWidth, Quire.Layout.Rail.width)
            XCTAssertEqual(metrics.mastheadMinimalX, Quire.Layout.ListHeader.mastheadMinimalX)
        }
    }

    func testRailWidthMaths() {
        XCTAssertEqual(QuireWindowChrome.railWidth(lightsEnd: 60), 76, "never narrower than 76")
        XCTAssertEqual(QuireWindowChrome.railWidth(lightsEnd: 72), 76, "macOS 15")
        XCTAssertEqual(QuireWindowChrome.railWidth(lightsEnd: 79), 84, "macOS 26 and later")
        XCTAssertEqual(QuireWindowChrome.railWidth(lightsEnd: 80), 84)
        XCTAssertEqual(QuireWindowChrome.railWidth(lightsEnd: 81), 86, "the smallest even width with 4 pt to spare")
        XCTAssertEqual(QuireWindowChrome.fallbackMetrics.railWidth, Quire.Layout.Rail.width)
    }

    func testListNeverSqueezesTheReaderBelowItsMinimum() {
        XCTAssertEqual(QuireWindowChrome.listMaxWidth(windowWidth: 1280, railWidth: 84), 480)
        XCTAssertEqual(QuireWindowChrome.listMaxWidth(windowWidth: 960, railWidth: 84), 476)
        XCTAssertEqual(QuireWindowChrome.listMaxWidth(windowWidth: 960, railWidth: 76), 480)
    }

    // MARK: The composer

    func testComposerFieldRowsStartAtTheMeasuredTitleBar() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: QuireWindowChrome.mainStyleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        QuireWindowChrome.configureComposerWindow(window)
        window.title = "New Message"
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let band = QuireWindowChrome.titlebarHeight(of: window)
        XCTAssertEqual(band, isMacOS26OrLater ? Quire.Layout.Window.composerTitlebar26 : Quire.Layout.Window.composerTitlebar,
                       accuracy: 0.5)
        // A field row placed at the measured band starts exactly where the unobscured content begins.
        let layout = content.convert(window.contentLayoutRect, from: nil)
        XCTAssertEqual(content.bounds.height - band, layout.maxY, accuracy: 0.01)
        XCTAssertNil(window.toolbar, "the composer keeps the plain system title bar")
        XCTAssertEqual(window.titleVisibility, .visible)
    }
}
