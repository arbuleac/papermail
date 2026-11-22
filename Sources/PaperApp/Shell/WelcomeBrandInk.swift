import AppKit
import PaperDesign

/// The colour the welcome screen draws the brand mark and the wordmark in (spec §4.11, §5.39, docs/brand): the brand's
/// own two colours, ink (`layout.brand.ink`) on a light page and paper (`layout.brand.paper`) on a dark one. The mark is
/// black and white only, so no theme, Increase Contrast or Graphite changes it: a theme's `ink` would tint it warm,
/// blue, green or violet.
enum WelcomeBrandInk {
    static let color = NSColor(name: "Paper.brandInk") { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? paper : ink
    }

    private static let ink = brand(Quire.Layout.Brand.ink)
    private static let paper = brand(Quire.Layout.Brand.paper)

    /// `#RRGGBB` in sRGB. The values are generated, and the drift tests hold them to tokens.json.
    private static func brand(_ hex: String) -> NSColor {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
}
