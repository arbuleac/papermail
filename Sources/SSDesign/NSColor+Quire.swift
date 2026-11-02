import AppKit

extension NSColor {
    /// A static sRGB colour from 0xRRGGBBAA. sRGB because tokens are tuned (and contrast-checked) in sRGB;
    /// a generic RGB space would shift every value on a wide-gamut display.
    public convenience init(quireRGBA rgba: UInt32) {
        self.init(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255,
                  green: CGFloat((rgba >> 16) & 0xFF) / 255,
                  blue: CGFloat((rgba >> 8) & 0xFF) / 255,
                  alpha: CGFloat(rgba & 0xFF) / 255)
    }

    /// The dynamic provider behind every generated `NSColor.q…` token (spec §8.2).
    ///
    /// Light or dark comes from the appearance through `bestMatch`, so a view with an explicit appearance
    /// draws its own half. Increase Contrast comes from `bestMatch` as well and, because AppKit only reports
    /// it for appearances it derives itself, from `QuireEnvironment` (see `QuireMode.init(_:)`). Graphite is
    /// in no appearance at all, so tokens with a substitution consult `QuireEnvironment.isGraphite`. The
    /// environment is a lock-protected snapshot, read once per resolution, because AppKit resolves colours on
    /// whatever thread draws.
    public static func quire(_ name: String, _ values: QuireColorValues, graphite: QuireColorValues? = nil) -> NSColor {
        let standard = values.colors
        let substitute = graphite?.colors
        return NSColor(name: NSColor.Name("q." + name)) { appearance in
            let environment = QuireEnvironment.shared.snapshot
            let mode = QuireMode(appearance, environmentContrast: environment.increaseContrast)
            if let substitute, environment.isGraphite {
                return substitute[mode.index]
            }
            return standard[mode.index]
        }
    }
}
