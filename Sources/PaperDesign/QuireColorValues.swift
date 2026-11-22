import AppKit

/// A colour token's four values as 0xRRGGBBAA in sRGB, exactly as tokens.json writes them. Alpha tokens keep
/// their alpha: they are always composited over the surface beneath (spec §4.1).
public struct QuireColorValues: Hashable, Sendable {
    public let light: UInt32
    public let dark: UInt32
    public let lightHC: UInt32
    public let darkHC: UInt32

    public init(light: UInt32, dark: UInt32, lightHC: UInt32, darkHC: UInt32) {
        self.light = light
        self.dark = dark
        self.lightHC = lightHC
        self.darkHC = darkHC
    }

    public subscript(mode: QuireMode) -> UInt32 {
        switch mode {
        case .light: return light
        case .dark: return dark
        case .lightHC: return lightHC
        case .darkHC: return darkHC
        }
    }

    /// One static colour per mode, in `QuireMode.index` order, so a provider never allocates while drawing.
    var colors: [NSColor] {
        QuireMode.allCases.map { NSColor(quireRGBA: self[$0]) }
    }
}
