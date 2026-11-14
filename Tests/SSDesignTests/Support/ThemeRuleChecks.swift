import Foundation
@testable import SSDesign

/// The theme rules R0–R11 (spec §4.16) over the generated per-theme values, mirroring docs/design/source/theme_rules.py
/// with the constants tokens.json carries (`themeRules`), which the generated `ThemeRuleTests` pass in. Study, the
/// default theme, is the reference: a rule holds a theme to Study's own value wherever Study sits under the floor.
struct ThemeRuleChecks {
    struct Rules {
        var sheetWhiteMaxDE00: Double
        var sheetMaxChroma: Double
        var focusOnPageMinContrast: Double
        var fillVsAccentAssetMaxDE00: Double
        var neutralLuminanceTolerance: Double
        var ratioLockTolerance: Double
        var nightInkMinOnFindCurrent: Double
        var accentVsInfoMinDE00: Double
        var accentVsInfoMinAnyVision: Double
        var accentVsAccountMinAnyVision: Double
        var inklessAccentVsAccountMinDE00: Double
        var accentVsMeaningMinDE00: Double
        var textVsMeaningMinAnyVision: Double
        var bannerVsPageMinDE00: Double
        var selectionKeyVsIdleMinDE00: Double
        var avatarFaceVsSurfaceMinDE00: Double
        var linkUnderlineMinDE00: Double
        var linkUnderlineMinAnyVision: Double
        var neutralTokens: [String]
        var ratioLock: [(token: String, reference: String)]
        var bannerWashes: [String]
        var avatarSurfaces: [String]
        var pageText: [QuireMode: [String]]
        var accentAsset: [QuireMode: String]
        var linkOnPage: [QuireMode: String]
    }

    let rules: Rules
    private static let meanings = ["success", "warning", "star", "danger"]

    /// A token's value in `theme` (alpha dropped: every rule reads the colour itself, as the python does).
    static func value(_ token: String, _ theme: QuireTheme, _ mode: QuireMode) -> RGBA {
        guard let t = QuireColorToken(rawValue: token) else { preconditionFailure("unknown colour token \(token)") }
        let v = t.values(theme: theme)[mode]
        return RGBA(r: Double((v >> 24) & 0xFF) / 255, g: Double((v >> 16) & 0xFF) / 255, b: Double((v >> 8) & 0xFF) / 255, a: 1)
    }

    static func de(_ a: RGBA, _ b: RGBA) -> Double { ColorLib.de2000(ColorLib.rgb2lab(a), ColorLib.rgb2lab(b)) }
    static func deMin(_ a: RGBA, _ b: RGBA) -> Double { ColorLib.deAll(a, b).values.min()! }
    static func chroma(_ c: RGBA) -> Double {
        let lab = ColorLib.rgb2lab(c)
        return (lab.a * lab.a + lab.b * lab.b).squareRoot()
    }

    /// R10's flag against `ink` (every link) or `ink2` (links inside quotes).
    func underlines(_ theme: QuireTheme, _ mode: QuireMode, against ink: String) -> Bool {
        let accent = Self.value("accent", theme, mode), text = Self.value(ink, theme, mode)
        return Self.de(accent, text) < rules.linkUnderlineMinDE00 || Self.deMin(accent, text) < rules.linkUnderlineMinAnyVision
    }

    /// Every rule `theme` breaks, one line each; empty when it keeps them all.
    func failures(_ theme: QuireTheme, declaredDeeper: [QuireMode: Set<String>]) -> [String] {
        var out: [String] = []
        func need(_ ok: Bool, _ message: @autoclosure () -> String) { if !ok { out.append("\(theme.rawValue) \(message())") } }
        let white = ColorLib.hex2rgba("#FFFFFF")
        let accounts = Quire.AccountInk.allCases
        for mode in QuireMode.allCases {
            func v(_ token: String) -> RGBA { Self.value(token, theme, mode) }
            func study(_ token: String) -> RGBA { Self.value(token, .study, mode) }
            func ink(_ a: Quire.AccountInk) -> RGBA { ColorLib.hex2rgba(String(format: "#%06X", a.values[mode] >> 8)) }
            let deeper = declaredDeeper[mode] ?? []
            // R1, R2: the light sheet is the page, raised is white, and the focus ring reads on the white page
            if !mode.isDark {
                need(Self.de(v("sheet"), white) <= rules.sheetWhiteMaxDE00 && Self.chroma(v("sheet")) <= rules.sheetMaxChroma, "R1 \(mode) sheet is not the page")
                need(v("raised") == white, "R1 \(mode) raised is not white")
                need(ColorLib.contrast(v("focus"), white) >= rules.focusOnPageMinContrast, "R2 \(mode) focus on the white page")
            }
            need(v("originalPage") == white, "R1 \(mode) originalPage is not white")
            // R3: native chrome reads the compiled asset once, so a coloured fill stays near it
            if !theme.isInkless {
                need(Self.de(v("accentFill"), ColorLib.hex2rgba(rules.accentAsset[mode]!)) <= rules.fillVsAccentAssetMaxDE00 + 1e-9, "R3 \(mode) fill vs the asset")
            }
            // R4: the luminance lock, except where the theme declares depth (or, inkless, the Graphite-family knob)
            for token in rules.neutralTokens where !deeper.contains(token) && !(theme.isInkless && QuireColorToken(rawValue: token)?.graphiteStack != nil) {
                let a = ColorLib.luminance(v(token)) + 0.05, b = ColorLib.luminance(study(token)) + 0.05
                need(abs(a - b) / b <= rules.neutralLuminanceTolerance, "R4 \(mode) \(token) luminance moved \(String(format: "%.1f", 100 * abs(a - b) / b)) %")
            }
            // R4b: declared depth never weakens a hairline, the idle selection or a quiet toggle's on state
            if !deeper.isEmpty {
                for (token, reference) in rules.ratioLock {
                    let theirs = ColorLib.contrast(v(token), v(reference)), ours = ColorLib.contrast(study(token), study(reference))
                    need(theirs >= ours * (1 - rules.ratioLockTolerance) - 1e-9, "R4b \(mode) \(token) on \(reference)")
                }
                if deeper.contains("ink") {
                    need(ColorLib.contrast(v("ink"), v("findCurrent")) >= rules.nightInkMinOnFindCurrent - 1e-9, "R4b \(mode) night ink on findCurrent")
                }
            }
            // R5: the ink against info, the account inks and the meanings
            need(Self.de(v("accent"), v("info")) >= rules.accentVsInfoMinDE00, "R5 \(mode) accent vs info")
            need(Self.deMin(v("accent"), v("info")) >= rules.accentVsInfoMinAnyVision, "R5 \(mode) accent vs info under CVD")
            let studyFloor = accounts.map { Self.deMin(study("accent"), ink($0)) }.min()!
            let closest = accounts.map { Self.deMin(v("accent"), ink($0)) }.min()!
            need(closest >= min(rules.accentVsAccountMinAnyVision, studyFloor) - 1e-9, "R5 \(mode) accent vs an account ink under CVD")
            if theme.isInkless {
                need(accounts.map { Self.de(v("accent"), ink($0)) }.min()! >= rules.inklessAccentVsAccountMinDE00, "R5 \(mode) inkless ink vs an account ink")
            }
            need(Self.meanings.map { Self.de(v("accent"), v($0)) }.min()! >= rules.accentVsMeaningMinDE00, "R5 \(mode) accent vs a meaning")
            // R6: a meaning never reads as text
            let text = ["ink", "ink2", "ink3"].flatMap { i in Self.meanings.map { Self.deMin(v(i), v($0)) } }.min()!
            need(text >= rules.textVsMeaningMinAnyVision, "R6 \(mode) text vs a meaning")
            // R7: banners stay banners on the page and on the desk
            for wash in rules.bannerWashes {
                need(min(Self.de(v(wash), v("sheet")), Self.de(v(wash), v("paper"))) >= rules.bannerVsPageMinDE00 - 1e-9, "R7 \(mode) \(wash) on the page")
                let floor = min(rules.bannerVsPageMinDE00, Self.de(study(wash), study("canvas")))
                need(Self.de(v(wash), v("canvas")) >= floor - 1e-9, "R7 \(mode) \(wash) on canvas")
            }
            // R8: key and not-key selection stay apart (an inkless theme tells them apart by the rule)
            if !theme.isInkless {
                need(Self.de(v("selWash"), v("selWashIdle")) >= rules.selectionKeyVsIdleMinDE00 - 1e-9, "R8 \(mode)")
            }
            // R9: no avatar face sinks further into a surface than it does in Study
            for tint in Quire.AvatarTint.allCases {
                let face = ColorLib.hex2rgba(String(format: "#%06X", tint.faceValues[mode] >> 8))
                for surface in rules.avatarSurfaces {
                    let reference = theme.isInkless && surface == "selWash" ? "selWashIdle" : surface
                    let floor = min(rules.avatarFaceVsSurfaceMinDE00, Self.de(face, study(reference)))
                    need(Self.de(face, v(surface)) >= floor - 0.05, "R9 \(mode) \(tint.name) on \(surface)")
                }
            }
            // R10: the generated flags are the ones the rule computes
            need(theme.underlinesLinksAtRest(mode) == underlines(theme, mode, against: "ink"), "R10 \(mode) link flag")
            need(theme.underlinesQuoteLinksAtRest(mode) == underlines(theme, mode, against: "ink2"), "R10 \(mode) quote-link flag")
            // R11: a link the sender left uncoloured is never closer to the page's text than Study's accent is
            let page = rules.pageText[mode]!.map(ColorLib.hex2rgba)
            let link = ColorLib.hex2rgba(rules.linkOnPage[mode]!)
            let ours = (page.map { Self.de(link, $0) }.min()!, page.map { Self.deMin(link, $0) }.min()!)
            let reference = (page.map { Self.de(study("accent"), $0) }.min()!, page.map { Self.deMin(study("accent"), $0) }.min()!)
            need(ours.0 >= reference.0 - 1e-9 && ours.1 >= reference.1 - 1e-9, "R11 \(mode) link on the page")
        }
        return out
    }
}
