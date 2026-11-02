import AppKit

/// An elevation level (spec §4.8): shadow layers for the light and the dark appearance. Increase Contrast
/// keeps its base appearance's shadows and adds an edge instead (`border.icOutline`). A two-layer level is a
/// key shadow on a container layer plus a contact shadow on one sublayer.
public struct QuireElevationLevel: Equatable, Sendable {
    public let light: [QuireShadowLayer]
    public let dark: [QuireShadowLayer]

    public init(light: [QuireShadowLayer], dark: [QuireShadowLayer]) {
        self.light = light
        self.dark = dark
    }

    public func layers(for mode: QuireMode) -> [QuireShadowLayer] { mode.isDark ? dark : light }

    public func layers(for appearance: NSAppearance) -> [QuireShadowLayer] { layers(for: QuireMode(appearance)) }

    /// The key shadow: the first layer, which AppKit puts on the container.
    public func key(for mode: QuireMode) -> QuireShadowLayer? { layers(for: mode).first }

    /// The contact shadow, when the level has one.
    public func contact(for mode: QuireMode) -> QuireShadowLayer? { layers(for: mode).dropFirst().first }
}
