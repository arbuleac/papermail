import AppKit
import XCTest
@testable import PaperDesign

/// Spec §8.7 `WindowChromeTests`: the main window built off screen with the §3.2 configuration puts the lights
/// on the 52 pt band, the rail derived from them has its centre on theirs, and the line clear of them, which the
/// minimal masthead counts from, stays 4 pt past their end. A failure here means a macOS release moved the lights:
/// re-derive the title-bar metrics (§3.2) rather than nudging numbers.
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
        XCTAssertEqual(content.bounds.size, NSSize(width: 1318, height: 800), "the reader keeps its keycaps beside the day column (§3.2)")
        let l = Quire.Layout.self
        XCTAssertEqual(l.Window.defaultWidth, l.Rail.width26 + l.List.defaultWidth + l.Window.readerKeycapsMin + l.CalendarPane.columnWidth)
        XCTAssertGreaterThanOrEqual(l.Window.minWidth, l.Rail.namesWidth + l.List.minWidth + l.Window.readerMinWidth + l.CalendarPane.stripWidth,
                                    "the narrowest window holds the rail with its names (§5.2)")
        XCTAssertEqual(window.contentMinSize, NSSize(width: 960, height: 600))
    }

    // MARK: The lights

    func testCloseButtonCentreIsOnTheBandCentreLine() {
        let metrics = QuireWindowChrome.metrics(of: mainWindow())
        XCTAssertEqual(metrics.lightsCenterY, Quire.Layout.TrafficLights.centerY, accuracy: Quire.Layout.TrafficLights.tolerance)
        XCTAssertEqual(metrics.titlebarZone, Quire.Layout.Window.titlebarZone)
    }

    func testTheLightsAreReadWhereTheyAreDrawn() throws {
        let window = mainWindow()
        let content = try XCTUnwrap(window.contentView)
        let close = try XCTUnwrap(window.standardWindowButton(.closeButton))
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        let closeMinX = close.convert(close.bounds, to: content).minX
        let zoomMaxX = zoom.convert(zoom.bounds, to: content).maxX
        let metrics = QuireWindowChrome.metrics(of: window)
        // The drawn lights: the frames' ends, or up to 2 pt inside them in the compatibility appearance.
        XCTAssertGreaterThanOrEqual(metrics.lightsStart, closeMinX - 0.01)
        XCTAssertLessThanOrEqual(metrics.lightsStart, closeMinX + 2)
        XCTAssertLessThanOrEqual(metrics.lightsEnd, zoomMaxX + 0.01)
        XCTAssertGreaterThanOrEqual(metrics.lightsEnd, zoomMaxX - 2)
        XCTAssertEqual(metrics.lightsCenterX, (metrics.lightsStart + metrics.lightsEnd) / 2)
    }

    /// The owner's report (23 November 2026): the tiles' column stood 7 pt to the left of the lights. The rail is the
    /// lights' leading inset mirrored past their end, so its centre, where the tiles are, is the lights' centre.
    func testTheRailsCentreIsTheLightsCentre() throws {
        let metrics = QuireWindowChrome.metrics(of: mainWindow())
        XCTAssertEqual(metrics.railWidth / 2, metrics.lightsCenterX, accuracy: 0.5, "tiles centred on the rail sit under the lights")
        XCTAssertEqual(metrics.railWidth.truncatingRemainder(dividingBy: 2), 0, "the rail width is even so tiles centre on whole points")
        XCTAssertGreaterThanOrEqual(metrics.railWidth, metrics.lightsEnd + metrics.lightsStart - 0.01, "the trailing inset is the leading one at least")
        XCTAssertGreaterThanOrEqual(metrics.railWidth, Quire.Layout.Rail.minWidth)
    }

    /// What stands in the title-bar zone beside the lights did not move when the rail grew: it counts from the line
    /// clear of the lights, 4 pt past their end, not from the rail.
    func testTheLineClearOfTheLightsIsFourPointsPastThem() throws {
        let window = mainWindow()
        let content = try XCTUnwrap(window.contentView)
        let zoom = try XCTUnwrap(window.standardWindowButton(.zoomButton))
        let zoomMaxX = zoom.convert(zoom.bounds, to: content).maxX
        let metrics = QuireWindowChrome.metrics(of: window)
        XCTAssertGreaterThanOrEqual(metrics.lightsClearX, zoomMaxX + Quire.Layout.Rail.lightsClearance)
        XCTAssertLessThan(metrics.lightsClearX, zoomMaxX + Quire.Layout.Rail.lightsClearance + 2 + 0.01, "the smallest even number that clears them")
        XCTAssertEqual(metrics.lightsClearX.truncatingRemainder(dividingBy: 2), 0)
        XCTAssertEqual(metrics.mastheadMinimalX, metrics.lightsClearX + Quire.Layout.ListHeader.mastheadMinimalGap)
        XCTAssertLessThanOrEqual(metrics.lightsClearX, metrics.railWidth, "the rail holds the lights and their clearance")
    }

    func testRailWidthPerRelease() {
        let metrics = QuireWindowChrome.metrics(of: mainWindow())
        let lights = Quire.Layout.TrafficLights.self
        if isMacOS26OrLater {
            XCTAssertEqual(metrics.lightsStart, lights.originX26, accuracy: 0.5)
            XCTAssertEqual(metrics.lightsEnd, lights.endX26, accuracy: 0.5)
            XCTAssertEqual(metrics.railWidth, Quire.Layout.Rail.width26)
            XCTAssertEqual(metrics.railWidth, 98)
            XCTAssertEqual(metrics.lightsClearX, lights.clearX26)
            XCTAssertEqual(metrics.mastheadMinimalX, Quire.Layout.ListHeader.mastheadMinimalX26)
            XCTAssertEqual(metrics.mastheadMinimalX, 92, "where it stood while the rail was 84 pt")
        } else {
            XCTAssertEqual(metrics.lightsStart, lights.originX, accuracy: 0.5)
            XCTAssertEqual(metrics.lightsEnd, lights.endX, accuracy: 0.5)
            XCTAssertEqual(metrics.railWidth, Quire.Layout.Rail.width)
            XCTAssertEqual(metrics.railWidth, 92)
            XCTAssertEqual(metrics.lightsClearX, lights.clearX)
            XCTAssertEqual(metrics.mastheadMinimalX, Quire.Layout.ListHeader.mastheadMinimalX)
            XCTAssertEqual(metrics.mastheadMinimalX, 84, "where it stood while the rail was 76 pt")
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
        XCTAssertEqual(try XCTUnwrap(QuireWindowChrome.drawnLeadingEdge(of: light)), 1, accuracy: 0.01)
        XCTAssertNil(QuireWindowChrome.drawnTrailingEdge(of: NSView(frame: NSRect(x: 0, y: 0, width: 14, height: 16))))
        XCTAssertNil(QuireWindowChrome.drawnLeadingEdge(of: NSView(frame: NSRect(x: 0, y: 0, width: 14, height: 16))))
    }

    func testRailWidthMaths() {
        XCTAssertEqual(QuireWindowChrome.railWidth(lightsStart: 20, lightsEnd: 72), 92, "macOS 15: the lights' centre is 46")
        XCTAssertEqual(QuireWindowChrome.railWidth(lightsStart: 19, lightsEnd: 79), 98, "macOS 26 and later: the lights' centre is 49")
        XCTAssertEqual(QuireWindowChrome.railWidth(lightsStart: 19, lightsEnd: 80), 100, "rounded up to an even number")
        XCTAssertEqual(QuireWindowChrome.railWidth(lightsStart: 19.5, lightsEnd: 79.5), 100)
        XCTAssertEqual(QuireWindowChrome.railWidth(lightsStart: 8, lightsEnd: 60), 76, "never narrower than 76")
        XCTAssertEqual(QuireWindowChrome.fallbackMetrics.railWidth, Quire.Layout.Rail.width)
        XCTAssertEqual(Quire.Layout.Rail.tileCenterX, Quire.Layout.Rail.width / 2)
    }

    /// The rule the rail's width followed until 1.20, kept for what stands beside the lights.
    func testTheLightsClearLineMaths() {
        XCTAssertEqual(QuireWindowChrome.lightsClearX(lightsEnd: 60), 76, "never under 76")
        XCTAssertEqual(QuireWindowChrome.lightsClearX(lightsEnd: 72), 76, "macOS 15")
        XCTAssertEqual(QuireWindowChrome.lightsClearX(lightsEnd: 79), 84, "macOS 26 and later")
        XCTAssertEqual(QuireWindowChrome.lightsClearX(lightsEnd: 80), 84)
        XCTAssertEqual(QuireWindowChrome.lightsClearX(lightsEnd: 81), 86, "the smallest even number with 4 pt to spare")
        XCTAssertEqual(QuireWindowChrome.fallbackMetrics.lightsClearX, Quire.Layout.TrafficLights.clearX)
        XCTAssertEqual(QuireWindowChrome.fallbackMetrics.mastheadMinimalX, Quire.Layout.ListHeader.mastheadMinimalX)
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
