import AppKit
import XCTest
@testable import PaperDesign

/// Elevation shadows fall down on screen (spec §4.8, §5.26). The window server applies a flipped view's
/// geometry to the shadow offsets of its layers, while `cacheDisplay` renders some hierarchies the other way,
/// so the direction is checked on the offsets and on a window-server composite of a real window.
@MainActor
final class ShadowDirectionTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    func testOffsetsFollowTheLayerGeometry() {
        let e2 = Quire.Elevation.e2.key(for: .light)!
        XCTAssertEqual(e2.layerOffset(flipped: false), CGSize(width: 0, height: -e2.y), "bottom-up layers fall toward -y")
        XCTAssertEqual(e2.layerOffset(flipped: true), CGSize(width: 0, height: e2.y), "top-down layers fall toward +y")
        let layer = CALayer()
        e2.apply(to: layer, in: QuireFlippedView(frame: .zero))
        XCTAssertGreaterThan(layer.shadowOffset.height, 0)
    }

    func testSurfacesAndTheKnobUseTheFlippedOffsets() {
        let sheet = QuireSheetView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        sheet.elevation = Quire.Elevation.e3
        sheet.surface.apply()
        let layers = Quire.Elevation.e3.layers(for: .light)
        XCTAssertEqual(sheet.surface.resolvedShadowOffsets[0].height, layers[0].y, "key shadow falls down in the flipped surface")
        if layers.count > 1 {
            XCTAssertEqual(sheet.surface.resolvedShadowOffsets[1].height, layers[1].y, "contact shadow falls down too")
        }
        let toggle = QuireToggle(isOn: true)
        toggle.appearanceDidChange()
        XCTAssertEqual(toggle.knob.shadowOffset.height, Quire.Layout.Toggle.KnobShadow.y, "the knob's contact shadow falls 1 pt down")
    }

    /// A sheet with a hard red shadow 10 pt down, in a real window composited by the window server: the red
    /// must show below the sheet and never above it.
    func testShadowFallsDownInTheWindowServerComposite() throws {
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        // CGWindowListCreateImage is obsoleted in the macOS 15 SDK but still served at run time; a test that
        // cannot reach it is skipped rather than failed.
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else {
            throw XCTSkip("CGWindowListCreateImage is not available")
        }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let hard = QuireShadowLayer(x: 0, y: 10, blur: 0, spread: 0, rgba: 0xFF0000FF)
        let sheet = QuireSheetView(frame: NSRect(x: 40, y: 40, width: 120, height: 40))
        sheet.elevation = QuireElevationLevel(light: [hard], dark: [hard])
        sheet.showsEdge = false
        let host = SnapshotHost(frame: NSRect(x: 0, y: 0, width: 200, height: 120))
        host.fill = .white
        host.addSubview(sheet)
        let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 200, height: 120), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        guard let image = createImage(.null, 1 << 3, UInt32(window.windowNumber), 1)?.takeRetainedValue() else {
            throw XCTSkip("the window server returned no image")
        }
        let rep = NSBitmapImageRep(cgImage: image)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        func isRed(atY y: CGFloat) -> Bool {
            let c = ComponentSnapshot.rgba(of: rep, x: Int(100 * scale), y: Int(y * scale))
            return c.r > 0.8 && c.g < 0.3 && c.b < 0.3
        }
        guard (0..<120).contains(where: { isRed(atY: CGFloat($0)) }) else {
            throw XCTSkip("the composite holds no shadow pixels (window not composited)")
        }
        XCTAssertTrue(isRed(atY: 85), "shadow below the sheet's bottom edge (y 80–90)")
        XCTAssertFalse(isRed(atY: 35), "no shadow above the sheet's top edge (y 40)")
    }
}
