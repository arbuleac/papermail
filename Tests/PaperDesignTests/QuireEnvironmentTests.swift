import AppKit
import XCTest
@testable import PaperDesign

final class QuireEnvironmentTests: XCTestCase {
    override func tearDown() {
        QuireTestEnvironment.reset()
        super.tearDown()
    }

    func testGraphiteDecision() {
        // Spec §3.1: the Graphite control tint, or an accent with saturation below the platform threshold.
        XCTAssertTrue(QuireEnvironment.isGraphiteAccent(controlTint: .graphiteControlTint, accentSaturation: 0.8))
        XCTAssertTrue(QuireEnvironment.isGraphiteAccent(controlTint: .blueControlTint, accentSaturation: 0.05))
        XCTAssertFalse(QuireEnvironment.isGraphiteAccent(controlTint: .blueControlTint, accentSaturation: 0.1))
        XCTAssertFalse(QuireEnvironment.isGraphiteAccent(controlTint: .defaultControlTint, accentSaturation: 0.71))
    }

    func testOverridesWinAndAnnounceChanges() {
        QuireTestEnvironment.forceDefaults()
        let changed = expectation(forNotification: QuireEnvironment.didChangeNotification, object: QuireEnvironment.shared)
        QuireEnvironment.shared.setOverrides(.init(isGraphite: true, increaseContrast: true, reduceMotion: true, reduceTransparency: true))
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(QuireEnvironment.shared.snapshot, .init(isGraphite: true, increaseContrast: true, reduceMotion: true, reduceTransparency: true))
        XCTAssertTrue(QuireEnvironment.isGraphite)
        XCTAssertTrue(QuireEnvironment.reduceMotion)
        XCTAssertTrue(QuireEnvironment.reduceTransparency)
        XCTAssertTrue(QuireEnvironment.increaseContrast)
    }

    func testNoNotificationWithoutAChange() {
        QuireTestEnvironment.forceDefaults()
        let quiet = expectation(forNotification: QuireEnvironment.didChangeNotification, object: QuireEnvironment.shared)
        quiet.isInverted = true
        QuireTestEnvironment.forceDefaults()
        wait(for: [quiet], timeout: 0.2)
    }

    func testRefreshKeepsOverridesOnTop() {
        QuireEnvironment.shared.setOverrides(.init(isGraphite: true))
        QuireEnvironment.shared.refresh()
        XCTAssertTrue(QuireEnvironment.isGraphite)
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false))
        QuireEnvironment.shared.refresh()
        XCTAssertFalse(QuireEnvironment.isGraphite)
    }

    func testCacheKeyFollowsModeContrastAndGraphite() {
        QuireTestEnvironment.forceDefaults()
        let light = QuireEnvironment.cacheKey(for: QuireMode.light.appearance)
        let dark = QuireEnvironment.cacheKey(for: QuireMode.dark.appearance)
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: true, reduceMotion: false, reduceTransparency: false))
        let darkHC = QuireEnvironment.cacheKey(for: QuireMode.dark.appearance)
        XCTAssertEqual(Set([light, dark, darkHC]).count, 3)
        XCTAssertTrue(darkHC.hasPrefix("darkHC"), darkHC)
        QuireEnvironment.shared.setOverrides(.init(isGraphite: true, increaseContrast: false, reduceMotion: false, reduceTransparency: false))
        XCTAssertNotEqual(QuireEnvironment.cacheKey(for: QuireMode.light.appearance), light)
        // Reduce Motion does not change a single pixel of a cached row, so it is not part of the key.
        QuireEnvironment.shared.setOverrides(.init(isGraphite: false, increaseContrast: false, reduceMotion: true, reduceTransparency: false))
        XCTAssertEqual(QuireEnvironment.cacheKey(for: QuireMode.light.appearance), light)
        XCTAssertEqual(QuireMode.light.appearance.performAsCurrentDrawingAppearanceReturning { QuireEnvironment.cacheKey }, light)
    }

    func testModesResolveFromAppearances() {
        QuireTestEnvironment.forceDefaults()
        XCTAssertEqual(QuireMode(QuireMode.light.appearance), .light)
        XCTAssertEqual(QuireMode(QuireMode.dark.appearance), .dark)
        XCTAssertEqual(QuireMode(NSAppearance(named: .vibrantDark)!), .dark)
        XCTAssertEqual(QuireMode(NSAppearance(named: .vibrantLight)!), .light)
        XCTAssertEqual(QuireMode(NSAppearance(named: .aqua)!, increaseContrast: true), .lightHC)
        XCTAssertEqual(QuireMode(NSAppearance(named: .darkAqua)!, increaseContrast: true), .darkHC)
        // AppKit hands back plain Aqua for the high-contrast names, which is why the flag exists at all.
        XCTAssertEqual(QuireMode(NSAppearance(named: .accessibilityHighContrastDarkAqua)!), .dark)
        // performAsCurrent makes every mode resolvable, whatever the system and the overrides say.
        QuireEnvironment.shared.setOverrides(.init(increaseContrast: true))
        for mode in QuireMode.allCases {
            XCTAssertEqual(mode.performAsCurrent { QuireMode(NSAppearance.currentDrawing()) }, mode)
        }
        XCTAssertEqual(QuireMode(QuireMode.light.appearance), .lightHC, "the IC flag upgrades a plain appearance")
    }

    func testIncreaseContrastFlagSwitchesProviders() {
        QuireTestEnvironment.forceDefaults()
        let view = NSView()
        view.appearance = QuireMode.light.appearance
        var ink = ""
        view.effectiveAppearance.performAsCurrentDrawingAppearance { ink = ColorLib.rgb2hex(self.srgb(.qInk)) }
        XCTAssertEqual(ink, "#1D1B18")
        QuireEnvironment.shared.setOverrides(.init(increaseContrast: true))
        view.effectiveAppearance.performAsCurrentDrawingAppearance { ink = ColorLib.rgb2hex(self.srgb(.qInk)) }
        XCTAssertEqual(ink, "#0F0E0C", "ink takes its Light IC value under Increase Contrast")
    }

    private func srgb(_ color: NSColor) -> RGBA {
        let c = color.usingColorSpace(.sRGB)!
        return RGBA(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    func testGraphiteSwitchesAccentProvidersLive() {
        QuireTestEnvironment.forceDefaults()
        let accent = TokenResolver.rgba(.qAccent, .light)
        XCTAssertEqual(ColorLib.rgb2hex(accent), "#1E5468")
        QuireEnvironment.shared.setOverrides(.init(isGraphite: true))
        XCTAssertEqual(ColorLib.rgb2hex(TokenResolver.rgba(.qAccent, .light)), "#1D1B18", "accent → ink under Graphite")
        XCTAssertEqual(ColorLib.rgb2hex(TokenResolver.rgba(.qOnAccent, .dark)), "#1C1B18", "onAccent → paper under Graphite")
        XCTAssertEqual(ColorLib.rgb2hex(TokenResolver.rgba(.qSelRuleIdle, .light)), "#625C55", "selRuleIdle is not substituted")
    }

    func testFlagsAreReadableFromAnyThreadWhileChanging() {
        let readers = expectation(description: "readers")
        readers.expectedFulfillmentCount = 4
        for _ in 0..<4 {
            DispatchQueue.global().async {
                for _ in 0..<2_000 {
                    _ = QuireEnvironment.isGraphite
                    _ = TokenResolver.rgba(.qAccentFill, .dark)
                }
                readers.fulfill()
            }
        }
        for i in 0..<200 { QuireEnvironment.shared.setOverrides(.init(isGraphite: i % 2 == 0)) }
        wait(for: [readers], timeout: 30)
    }
}

private extension NSAppearance {
    func performAsCurrentDrawingAppearanceReturning<T>(_ body: () -> T) -> T {
        var result: T?
        performAsCurrentDrawingAppearance { result = body() }
        return result!
    }
}
