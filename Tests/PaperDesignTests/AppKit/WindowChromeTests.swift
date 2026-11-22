import AppKit
import XCTest
@testable import PaperDesign

/// Spec §8.7 `WindowChromeTests`: the main window built off screen with the §3.2 configuration puts the lights
/// on the 52 pt band, and the rail derived from them clears them by 4 pt. A failure here means a macOS release
/// moved the lights: re-derive the title-bar metrics (§3.2) rather than nudging numbers.
@MainActor
final class WindowChromeTests: XCTestCase {
    private var isMacOS26OrLater: Bool {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }

    private func mainWindow() -> NSWindow {
        let window = QuireWindowChrome.makeMainWindow(title: "Paper")
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
        XCTAssertEqual(window.title, "Paper", "the title still names the window for the Window menu and VoiceOver")
    }

    func testDefaultAndMinimumSizes() throws {
        let window = mainWindow()
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.bounds.size, NSSize(width: 1304, height: 800), "the reader keeps its keycaps beside the day column (§3.2)")
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
        // The drawn light: the frame's end, or up to 2 pt inside it in the compatibility appearance.
        XCTAssertLessThanOrEqual(metrics.lightsEnd, zoomMaxX + 0.01)
        XCTAssertGreaterThanOrEqual(metrics.lightsEnd, zoomMaxX - 2)
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

    /// A 12 pt light in a 14 pt frame, as the compatibility appearance draws it, ends 1 pt inside the frame.
    func testTheDrawnEdgeOfALightInsideItsFrame() throws {
        final class Light: NSView {
            override func draw(_ dirtyRect: NSRect) {
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: NSRect(x: 1, y: 2, width: 12, height: 12)).fill()
            }
        }
        let light = Light(frame: NSRect(x: 0, y: 0, width: 14, height: 16))
        XCTAssertEqual(try XCTUnwrap(QuireWindowChrome.drawnTrailingEdge(of: light)), 13, accuracy: 0.01)
        XCTAssertNil(QuireWindowChrome.drawnTrailingEdge(of: NSView(frame: NSRect(x: 0, y: 0, width: 14, height: 16))))
    }

    func testRailWidthMaths() {
        XCTAssertEqual(QuireWindowChrome.railWidth(lightsEnd: 60), 76, "never narrower than 76")
        XCTAssertEqual(QuireWindowChrome.railWidth(lightsEnd: 72), 76, "macOS 15")
        XCTAssertEqual(QuireWindowChrome.railWidth(lightsEnd: 79), 84, "macOS 26 and later")
        XCTAssertEqual(QuireWindowChrome.railWidth(lightsEnd: 80), 84)
        XCTAssertEqual(QuireWindowChrome.railWidth(lightsEnd: 81), 86, "the smallest even width with 4 pt to spare")
        XCTAssertEqual(QuireWindowChrome.fallbackMetrics.railWidth, Quire.Layout.Rail.width)
    }

    // MARK: A reader window (§5.49)

    func testReaderWindowSharesTheMainWindowsCentreLine() throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: QuireWindowChrome.readerWindowDefaultSize),
                              styleMask: QuireWindowChrome.mainStyleMask, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        QuireWindowChrome.configureReaderWindow(window, title: "Contoso rollout")
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertNotNil(window.toolbar, "the band the reader header's row 1 is drawn for")
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.title, "Contoso rollout", "the subject names the window for the Window menu and VoiceOver")
        XCTAssertEqual(window.contentMinSize, NSSize(width: 520, height: 420))
        XCTAssertEqual(try XCTUnwrap(window.contentView).bounds.size, NSSize(width: 840, height: 800))
        let metrics = QuireWindowChrome.metrics(of: window)
        XCTAssertEqual(metrics.lightsCenterY, Quire.Layout.ReaderHeader.kickerCenterY, accuracy: Quire.Layout.TrafficLights.tolerance)
        XCTAssertGreaterThanOrEqual(metrics.mastheadMinimalX, metrics.lightsEnd + Quire.Layout.Rail.lightsClearance,
                                    "the kicker, which starts there at the least, clears the lights")
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
