import AppKit
import SwiftUI
import XCTest
@testable import SSDesign

/// The generated runtime against docs/design/tokens.json: if someone edits tokens.json and forgets to run the
/// generator (or hand-edits a generated file), these fail. `quire-tokens.swift --check` in scripts/test.sh
/// catches the same thing earlier; this catches it inside plain `swift test` too.
final class TokenDriftTests: XCTestCase {
    private let file = DesignTokensFile.shared

    override func setUp() {
        super.setUp()
        QuireTestEnvironment.forceDefaults()
    }

    override func tearDown() {
        QuireTestEnvironment.reset()
        super.tearDown()
    }

    /// 0xRRGGBBAA of a resolved colour, rounded the way the token was written.
    private func rgba(_ color: NSColor, _ mode: QuireMode) -> UInt32 {
        let c = TokenResolver.rgba(color, mode)
        func byte(_ x: Double) -> UInt32 { UInt32((x * 255).rounded()) }
        return byte(c.r) << 24 | byte(c.g) << 16 | byte(c.b) << 8 | byte(c.a)
    }

    private func rgba(hex: String) -> UInt32 {
        var h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        if h.count == 6 { h += "FF" }
        return UInt32(h, radix: 16)!
    }

    private func hex(_ v: UInt32) -> String { String(format: "#%08X", v) }

    func testEveryColourTokenResolvesToItsFourValues() {
        let colors = file.object("color")
        XCTAssertEqual(Set(colors.keys), Set(QuireColorToken.allCases.map(\.rawValue)), "the token set changed without regenerating")
        for token in QuireColorToken.allCases {
            guard let entry = colors[token.rawValue] as? [String: Any] else { continue }
            for mode in QuireMode.allCases {
                let want = rgba(hex: entry[mode.rawValue] as! String)
                XCTAssertEqual(hex(rgba(token.color, mode)), hex(want), "color.\(token.rawValue).\(mode.rawValue)")
                XCTAssertEqual(hex(token.values[mode]), hex(want), "QuireColorToken.\(token.rawValue).values[\(mode.rawValue)]")
            }
        }
    }

    func testSwiftUIColoursMatchTheirProviders() {
        // Color(nsColor:) must wrap the same dynamic provider, not a snapshot of one appearance.
        for mode in QuireMode.allCases {
            XCTAssertEqual(rgba(NSColor(Color.qPaper), mode), rgba(NSColor.qPaper, mode), "\(mode)")
            XCTAssertEqual(rgba(NSColor(Color.qAccent), mode), rgba(NSColor.qAccent, mode), "\(mode)")
        }
    }

    func testGraphiteSubstitutesEveryListedTokenPerMode() {
        let colors = file.object("color")
        let graphite = file.object("graphite")
        XCTAssertFalse(graphite.isEmpty)
        QuireEnvironment.shared.setOverrides(.init(isGraphite: true, increaseContrast: false, reduceMotion: false, reduceTransparency: false))
        for token in QuireColorToken.allCases {
            for mode in QuireMode.allCases {
                let got = rgba(token.color, mode)
                if let entry = graphite[token.rawValue] as? [String: Any] {
                    let stack = (entry["value"] as? String).map { [$0] } ?? (entry["value"] as! [String])
                    XCTAssertEqual(token.graphiteStack, stack, token.rawValue)
                    // The generator pre-composites the stack per mode, as the CSS block writes it.
                    let layers = stack.map { ColorLib.hex2rgba((colors[$0] as! [String: Any])[mode.rawValue] as! String) }
                    var composite = layers[0]
                    for layer in layers.dropFirst() { composite = ColorLib.over(layer, composite) }
                    XCTAssertEqual(hex(got), hex(rgba(hex: ColorLib.rgb2hex(composite))), "graphite.\(token.rawValue).\(mode.rawValue)")
                } else {
                    let want = rgba(hex: (colors[token.rawValue] as! [String: Any])[mode.rawValue] as! String)
                    XCTAssertEqual(hex(got), hex(want), "\(token.rawValue) must not change under Graphite (\(mode.rawValue))")
                    XCTAssertNil(token.graphiteStack, token.rawValue)
                }
            }
        }
        // Account inks are identity, not accent (spec §3.1).
        let persimmon = (file.array("accountPalette").first as! [String: Any])["light"] as! String
        XCTAssertEqual(hex(rgba(NSColor.qAccount(0), .light)), hex(rgba(hex: persimmon)))
    }

    func testAccountAndAvatarPalettes() {
        let accounts = file.array("accountPalette").map { $0 as! [String: Any] }
        XCTAssertEqual(Quire.accountInkNames, accounts.map { $0["name"] as! String })
        for (slot, entry) in accounts.enumerated() {
            for mode in QuireMode.allCases {
                XCTAssertEqual(hex(rgba(NSColor.qAccount(slot), mode)), hex(rgba(hex: entry[mode.rawValue] as! String)), "\(entry["name"]!) \(mode)")
            }
        }
        // Slots wrap in both directions, so any stored slot draws.
        XCTAssertEqual(rgba(NSColor.qAccount(10), .light), rgba(NSColor.qAccount(0), .light))
        XCTAssertEqual(rgba(NSColor.qAccount(-1), .light), rgba(NSColor.qAccount(9), .light))

        let avatars = file.array("avatarPalette").map { $0 as! [String: Any] }
        XCTAssertEqual(Quire.avatarTintNames, avatars.map { $0["name"] as! String })
        XCTAssertEqual(avatars.count, file.object("platform")["avatarTintCount"] as? Int)
        for (i, entry) in avatars.enumerated() {
            for mode in QuireMode.allCases {
                let m = entry[mode.rawValue] as! [String: String]
                XCTAssertEqual(hex(rgba(NSColor.qAvatarFace(i), mode)), hex(rgba(hex: m["face"]!)), "\(entry["name"]!) face \(mode)")
                XCTAssertEqual(hex(rgba(NSColor.qAvatarInk(i), mode)), hex(rgba(hex: m["ink"]!)), "\(entry["name"]!) ink \(mode)")
            }
        }
    }

    func testEveryTypographyRoleMatchesItsEntry() {
        let roles = file.object("typography")
        XCTAssertEqual(Set(roles.keys), Set(QuireFont.Role.allCases.map(\.rawValue)))
        for role in QuireFont.Role.allCases {
            let e = roles[role.rawValue] as! [String: Any]
            let s = role.spec
            XCTAssertEqual(s.family.rawValue, e["family"] as? String, role.rawValue)
            XCTAssertEqual(Double(s.size), (e["size"] as! NSNumber).doubleValue, role.rawValue)
            XCTAssertEqual(Double(s.weight), (e["weight"] as! NSNumber).doubleValue, role.rawValue)
            XCTAssertEqual(Double(s.lineHeight), (e["lineHeight"] as! NSNumber).doubleValue, role.rawValue)
            XCTAssertEqual(Double(s.tracking), (e["tracking"] as! NSNumber).doubleValue, accuracy: 1e-9, role.rawValue)
            XCTAssertEqual(s.twin?.rawValue, e["twin"] as? String, role.rawValue)
            XCTAssertEqual(s.twinOf?.rawValue, e["twinOf"] as? String, role.rawValue)
            XCTAssertEqual(s.variantOf?.rawValue, e["variantOf"] as? String, role.rawValue)
            XCTAssertEqual(s.italic, e["style"] as? String == "italic", role.rawValue)
            XCTAssertEqual(s.tabular, e["numeric"] as? String == "tabular", role.rawValue)
            XCTAssertEqual(s.uppercase, e["case"] as? String == "upper", role.rawValue)
            XCTAssertEqual(s.unreadWeight.map(Double.init), (e["unreadWeight"] as? NSNumber)?.doubleValue, role.rawValue)
            XCTAssertEqual(s.sizeRatio.map(Double.init), (e["sizeRatio"] as? NSNumber)?.doubleValue, role.rawValue)
            XCTAssertEqual(s.minSize.map(Double.init), (e["minSize"] as? NSNumber)?.doubleValue, role.rawValue)
        }
    }

    func testScalesAndMotion() {
        let space = file.object("space")
        XCTAssertEqual(Quire.Space.scale.map(Double.init), (1...12).map { (space["s\($0)"] as! NSNumber).doubleValue })
        XCTAssertEqual(Double(Quire.Radius.lg), file.number("radius.lg"))
        XCTAssertEqual(Double(Quire.Radius.tile), file.number("radius.tile"))
        XCTAssertEqual(Quire.Motion.standard * 1000, file.number("motion.duration.standard")!, accuracy: 1e-9)
        XCTAssertEqual(Quire.Motion.reducedFade * 1000, file.number("motion.duration.reducedFade")!, accuracy: 1e-9)
        XCTAssertEqual(Quire.Motion.gSequenceWindow * 1000, file.number("motion.duration.gSequenceWindow")!, accuracy: 1e-9)
        XCTAssertEqual(Quire.Motion.undoSendChoices.map { $0 * 1000 }, (file.value("motion.duration.undoSendChoices") as! [NSNumber]).map(\.doubleValue))
        let curves = file.object("motion")["curve"] as! [String: [NSNumber]]
        XCTAssertEqual(Set(curves.keys), Set(Quire.Motion.Curve.allCases.map(\.rawValue)))
        for curve in Quire.Motion.Curve.allCases {
            let p = curve.controlPoints
            XCTAssertEqual([p.0, p.1, p.2, p.3].map(Double.init), curves[curve.rawValue]!.map { Double(Float(truncating: $0)) }, curve.rawValue)
            var c: [Float] = [0, 0]
            curve.timingFunction.getControlPoint(at: 1, values: &c)
            XCTAssertEqual(c[0], p.0)
            XCTAssertEqual(c[1], p.1)
        }
        let e2 = Quire.Elevation.e2
        XCTAssertEqual(e2.light.count, 2)
        let e2Light = file.value("elevation.e2.light") as! [[String: Any]]
        XCTAssertEqual(e2.light.map { Double($0.blur) }, e2Light.map { ($0["blur"] as! NSNumber).doubleValue })
        XCTAssertEqual(e2.light.map { Double($0.y) }, e2Light.map { ($0["y"] as! NSNumber).doubleValue })
        XCTAssertEqual(e2.key(for: .dark)?.shadowRadius, 12)
        XCTAssertEqual(e2.key(for: .darkHC)?.layerOffset, CGSize(width: 0, height: -8))
        XCTAssertEqual(e2.key(for: .light)?.opacity ?? 0, 0x24 / 255, accuracy: 1e-6)
        XCTAssertEqual(Quire.Elevation.e0.light, [])
    }

    func testLayoutSample() {
        let samples: [(String, CGFloat)] = [
            ("layout.row.height", Quire.Layout.Row.height),
            ("layout.row.textX", Quire.Layout.Row.textX),
            ("layout.rowCompact.pipY", Quire.Layout.RowCompact.pipY),
            ("layout.rail.faceAlpha", Quire.Layout.Rail.faceAlpha),
            ("layout.listHeader.height", Quire.Layout.ListHeader.height),
            ("layout.window.titlebarZone", Quire.Layout.Window.titlebarZone),
            ("layout.trafficLights.tolerance", Quire.Layout.TrafficLights.tolerance),
            ("layout.button.regular.height", Quire.Layout.Button.Regular.height),
            ("layout.toggle.knobShadow.blur", Quire.Layout.Toggle.KnobShadow.blur),
            ("layout.undoPanel.shadowMarginBottom", Quire.Layout.UndoPanel.shadowMarginBottom),
            ("layout.cheatSheet.width", Quire.Layout.CheatSheet.width),
            ("layout.iconSize.row", Quire.Layout.IconSize.row),
        ]
        for (path, value) in samples {
            XCTAssertEqual(Double(value), file.number(path)!, accuracy: 1e-9, path)
        }
        XCTAssertEqual(Quire.Layout.Button.Small.font, file.value("layout.button.small.font") as? String)
        XCTAssertEqual(Quire.Layout.TrafficLights.mechanism, file.value("layout.trafficLights.mechanism") as? String)
        XCTAssertEqual(Quire.Layout.Progress.spinnerStroke.map(Double.init), (file.value("layout.progress.spinnerStroke") as! [NSNumber]).map(\.doubleValue))
        XCTAssertEqual(Quire.Layout.Toggle.KnobShadow.darkHC, file.value("layout.toggle.knobShadow.darkHC") as? String)
        // Every role a button names exists.
        for name in [Quire.Layout.Button.Small.font, Quire.Layout.Button.Regular.fontStrong, Quire.Layout.Button.Large.font] {
            XCTAssertNotNil(QuireFont.Role(rawValue: name), name)
        }
    }

    func testContentTables() {
        let icons = file.object("icon") as! [String: String]
        XCTAssertEqual(Quire.Icon.archive, icons["archive"])
        XCTAssertEqual(Quire.Icon.compose, icons["compose"])
        XCTAssertEqual(Quire.readerSymbols, file.array("readerSymbols") as! [String])
        XCTAssertEqual(Set(Quire.CustomGlyph.allCases.map(\.rawValue)), Set(file.object("customGlyphs").keys))
        let sections = file.array("cheatSheetContent").map { $0 as! [String: Any] }
        XCTAssertEqual(Quire.cheatSheet.map(\.title), sections.map { $0["section"] as! String })
        XCTAssertEqual(Quire.cheatSheet.map(\.rows.count), sections.map { ($0["rows"] as! [Any]).count })
        XCTAssertEqual(Quire.cheatSheet[2].rows[0].parts.map(\.isKeycap), [true, false, true]) // "G then I"
        XCTAssertEqual(Quire.Platform.graphiteSaturationMax, file.number("platform.graphiteSaturationMax"))
        XCTAssertEqual(Quire.Platform.minTextSize, 11)
        XCTAssertEqual(Quire.AccountRules.promisedDistinct, 6)
        XCTAssertEqual(Quire.AccountRules.standardMinContrast, file.number("accountRules.standardMinContrast"))
        XCTAssertEqual(Quire.Deferred.TextSize.rowHeights, [64, 68, 72, 76])
        XCTAssertEqual(Quire.version, file.root["version"] as? String)
        XCTAssertEqual(Double(Quire.Border.FocusRing.widthHC), file.number("border.focusRing.widthHC"))
        XCTAssertEqual(Quire.Border.Hairline.width, "1px-device")
    }
}
