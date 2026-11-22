import AppKit
import XCTest
@testable import PaperDesign

@MainActor
final class QuireLayerColorsTests: XCTestCase {
    override func setUp() async throws {
        try await super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() async throws {
        QuireTestEnvironment.reset()
        try await super.tearDown()
    }

    private func hex(_ cg: CGColor?) -> String? {
        guard let cg, let c = NSColor(cgColor: cg)?.usingColorSpace(.sRGB) else { return nil }
        return ColorLib.rgb2hex(RGBA(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent)))
    }

    func testResolvesUnderTheViewsAppearanceAndFollowsIt() {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.appearance = QuireMode.light.appearance
        let colors = QuireLayerColors(view: view)
        let shape = CAShapeLayer()
        colors.set(.qPaper, for: \CALayer.backgroundColor, of: view.layer!)
        colors.set(.qAccent, for: \CAShapeLayer.strokeColor, of: shape)
        XCTAssertEqual(hex(view.layer?.backgroundColor), "#FBFAF6")
        XCTAssertEqual(hex(shape.strokeColor), "#1E5468")

        view.appearance = QuireMode.dark.appearance
        colors.refresh()
        XCTAssertEqual(hex(view.layer?.backgroundColor), "#1C1B18")
        XCTAssertEqual(hex(shape.strokeColor), "#6DB6C9")
        XCTAssertEqual(colors.count, 2)

        // Increase Contrast arrives as an environment change and refreshes without a call.
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: true, reduceMotion: false, reduceTransparency: false))
        XCTAssertEqual(hex(view.layer?.backgroundColor), "#121110")
        XCTAssertEqual(hex(shape.strokeColor), "#93D3E3")
    }

    func testEnvironmentChangesRefreshWithoutAnAppearanceChange() {
        let view = NSView(frame: .zero)
        view.appearance = QuireMode.light.appearance
        let colors = QuireLayerColors(view: view)
        let layer = CALayer()
        colors.set(.qSelRule, for: \CALayer.borderColor, of: layer)
        var shadow: CGColor?
        colors.bind("shadow", .qFocus) { shadow = $0 }
        XCTAssertEqual(hex(layer.borderColor), "#1E5468")
        QuireEnvironment.shared.setOverrides(.init(isGraphite: true))
        XCTAssertEqual(hex(layer.borderColor), "#1D1B18", "selRule → ink under Graphite, applied by the notification")
        XCTAssertEqual(hex(shadow), "#1D1B18")
        colors.unbind("shadow")
        XCTAssertEqual(colors.count, 1)
    }

    func testRebindingReplacesAndNilClears() {
        let view = NSView(frame: .zero)
        view.appearance = QuireMode.light.appearance
        let colors = QuireLayerColors(view: view)
        let layer = CALayer()
        colors.set(.qPaper, for: \CALayer.backgroundColor, of: layer)
        colors.set(.qSheet, for: \CALayer.backgroundColor, of: layer)
        XCTAssertEqual(colors.count, 1)
        XCTAssertEqual(hex(layer.backgroundColor), "#FFFEFB")
        colors.set(nil, for: \CALayer.backgroundColor, of: layer)
        XCTAssertNil(layer.backgroundColor)
        XCTAssertEqual(colors.count, 0)
    }

    func testReleasedLayersAreDropped() {
        let view = NSView(frame: .zero)
        let colors = QuireLayerColors(view: view)
        do {
            let layer = CALayer()
            colors.set(.qRule, for: \CALayer.backgroundColor, of: layer)
            XCTAssertEqual(colors.count, 1)
        }
        colors.refresh()
        XCTAssertEqual(colors.count, 0)
    }

    func testAlphaTokensKeepTheirAlpha() {
        let view = NSView(frame: .zero)
        view.appearance = QuireMode.dark.appearance
        let colors = QuireLayerColors(view: view)
        let cg = colors.resolve(.qHover)
        XCTAssertEqual(cg.alpha, 0x0E / 255, accuracy: 1e-6)
    }
}
