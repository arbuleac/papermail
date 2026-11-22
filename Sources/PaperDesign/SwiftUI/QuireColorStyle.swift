import AppKit
import SwiftUI

/// A colour token as a SwiftUI shape style (spec §4.16), written `.qInk`, `.qCanvas`, … wherever SwiftUI takes one.
/// It resolves from the view's environment (`quireTheme`, and the flags `QuireThemeRoot` sets), so a theme, Graphite or
/// Increase Contrast switch changes the resolved colour and SwiftUI redraws in place. `Color.qInk` would not: its
/// provider's output changes, but SwiftUI never asks it again.
public struct QuireColorStyle: ShapeStyle {
    public let token: QuireColorToken

    public init(_ token: QuireColorToken) {
        self.token = token
    }

    public func resolve(in environment: EnvironmentValues) -> Color {
        Color.quire(token, theme: environment.quireTheme, flags: environment.quireDrawingFlags)
    }
}

extension Color {
    /// `token` in `theme`, for the few places that need a `Color` rather than a shape style (an attributed string's
    /// foreground): read `@Environment(\.quireTheme)` and pass it.
    public static func quire(_ token: QuireColorToken, theme: QuireTheme) -> Color {
        Color(nsColor: .quire(token, theme: theme))
    }

    /// `token` as a `QuireThemeRoot` subtree draws it: under the root's Graphite and Increase Contrast, so a switch of
    /// either is another colour, which SwiftUI redraws.
    static func quire(_ token: QuireColorToken, theme: QuireTheme, flags: QuireDrawingFlags?) -> Color {
        Color(nsColor: QuirePinnedColors.color(token, theme: theme, graphite: flags?.isGraphite, increaseContrast: flags?.increaseContrast))
    }
}
