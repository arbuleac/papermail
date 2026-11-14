import AppKit
import os

extension NSColor {
    /// A static sRGB colour from 0xRRGGBBAA. sRGB because tokens are tuned (and contrast-checked) in sRGB;
    /// a generic RGB space would shift every value on a wide-gamut display.
    public convenience init(quireRGBA rgba: UInt32) {
        self.init(srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255,
                  green: CGFloat((rgba >> 16) & 0xFF) / 255,
                  blue: CGFloat((rgba >> 8) & 0xFF) / 255,
                  alpha: CGFloat(rgba & 0xFF) / 255)
    }

    /// The dynamic provider behind every generated `NSColor.q…` token that is the same in every theme (spec §8.2).
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

    /// The provider behind a token that differs across themes (spec §4.16): one set of values per theme, in `QuireTheme`
    /// order, and per theme its Graphite values. It reads the theme from the same snapshot as Graphite and Increase
    /// Contrast. A theme's colours are made the first time that theme is drawn, so a theme never chosen costs only its
    /// static integers, and a resolution allocates nothing.
    public static func quire(_ name: String, themes: [QuireColorValues], graphite: [QuireColorValues]? = nil) -> NSColor {
        let sets = QuireThemedColorSets(themes: themes, graphite: graphite)
        return NSColor(name: NSColor.Name("q." + name)) { appearance in
            let environment = QuireEnvironment.shared.snapshot
            let mode = QuireMode(appearance, environmentContrast: environment.increaseContrast)
            return sets.colors(environment.theme, graphite: environment.isGraphite)[mode.index]
        }
    }

    /// `token` pinned to `theme`: it still resolves Light, Dark and Increase Contrast from the appearance and Graphite from
    /// `QuireEnvironment`, but draws `theme` whatever the app's theme is. SwiftUI uses it through `QuireColorStyle`, which
    /// picks the theme from the view's environment, and a theme tile draws another theme than the app's. The same token
    /// and theme give the same colour object, so SwiftUI sees no change where there is none.
    public static func quire(_ token: QuireColorToken, theme: QuireTheme) -> NSColor {
        QuirePinnedColors.color(token, theme: theme, graphite: nil, increaseContrast: nil)
    }

    /// True for a colour made by one of the providers above (its name starts with `q.`).
    var isQuireToken: Bool {
        type == .catalog && colorNameComponent.hasPrefix("q.")
    }
}

/// A themed token's colours, made per theme (and per Graphite) on first use.
final class QuireThemedColorSets: @unchecked Sendable {
    private let themes: [QuireColorValues]
    private let graphite: [QuireColorValues]?
    private let cache = LockedCache<Int, [NSColor]>()

    /// How many colour sets each theme has made, across every token: a theme never drawn makes none (spec §4.16).
    static let made = OSAllocatedUnfairLock(initialState: [Int](repeating: 0, count: QuireTheme.allCases.count))

    init(themes: [QuireColorValues], graphite: [QuireColorValues]?) {
        precondition(themes.count == QuireTheme.allCases.count, "one set of values per theme")
        self.themes = themes
        self.graphite = graphite
    }

    func colors(_ theme: QuireTheme, graphite isGraphite: Bool) -> [NSColor] {
        let substitute = isGraphite && graphite != nil
        return cache.value(for: theme.index * 2 + (substitute ? 1 : 0)) {
            QuireThemedColorSets.made.withLock { $0[theme.index] += 1 }
            return (substitute ? graphite![theme.index] : themes[theme.index]).colors
        }
    }
}

/// The pinned providers, one per token, theme and fixed flags, made on first use and kept, so asking again returns the
/// same object.
enum QuirePinnedColors {
    private struct Key: Hashable {
        let token: QuireColorToken
        let theme: QuireTheme
        let graphite: Bool?
        let increaseContrast: Bool?
    }

    private static let cache = LockedCache<Key, NSColor>()

    /// `graphite` and `increaseContrast` fix those flags when set, so a SwiftUI style resolved under one value returns
    /// another colour object under the other; nil reads them from `QuireEnvironment`, as every provider does.
    static func color(_ token: QuireColorToken, theme: QuireTheme, graphite: Bool?, increaseContrast: Bool?) -> NSColor {
        cache.value(for: Key(token: token, theme: theme, graphite: graphite, increaseContrast: increaseContrast)) {
            let standard = token.values(theme: theme).colors
            let substitute = token.graphiteValues(theme: theme)?.colors
            let name = "q.\(token.rawValue).\(theme.rawValue)"
            return NSColor(name: NSColor.Name(name)) { appearance in
                let environment = QuireEnvironment.shared.snapshot
                let mode = QuireMode(appearance, environmentContrast: increaseContrast ?? environment.increaseContrast)
                if let substitute, graphite ?? environment.isGraphite {
                    return substitute[mode.index]
                }
                return standard[mode.index]
            }
        }
    }
}
