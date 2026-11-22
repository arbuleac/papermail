import SwiftUI

/// The theme a SwiftUI subtree draws (spec §4.16), and the Graphite and Increase Contrast flags it was drawn under.
///
/// SwiftUI does not resolve `Color(nsColor:)` again when a provider's output changes, so a theme switch would leave
/// Settings in the old theme. Rebuilding the subtree (`QuireEnvironmentRefresh`) would drop keyboard focus and every
/// field's state. Instead `QuireThemeRoot` puts the theme and the flags in the environment, and `QuireColorStyle`
/// resolves from them: a change of either is a change of the resolved colour, which SwiftUI redraws in place.
extension EnvironmentValues {
    /// The theme `QuireColorStyle` draws. A `QuireThemeRoot` sets it to the app's, so a change redraws in place; where
    /// nothing sets it, it is `QuireEnvironment`'s theme when the view draws (Study until the app sets one).
    public var quireTheme: QuireTheme {
        get { self[QuireThemeKey.self] ?? QuireEnvironment.theme }
        set { self[QuireThemeKey.self] = newValue }
    }

    /// Graphite and Increase Contrast as `QuireThemeRoot` last read them; nil outside a root, where colours read them
    /// from `QuireEnvironment` while drawing, as AppKit's do.
    var quireDrawingFlags: QuireDrawingFlags? {
        get { self[QuireDrawingFlagsKey.self] }
        set { self[QuireDrawingFlagsKey.self] = newValue }
    }
}

extension EnvironmentValues {
    /// Whether a link drawn here takes its underline at rest (spec §3.1, §4.16): under Graphite, and where this view's
    /// theme draws its ink too near its text ink in this view's mode. The SwiftUI side of
    /// `QuireEnvironment.underlinesLinksAtRest(for:)`, read from the environment so a switch redraws in place.
    var quireUnderlinesLinksAtRest: Bool {
        let isGraphite = quireDrawingFlags?.isGraphite ?? QuireEnvironment.isGraphite
        let increased = colorSchemeContrast == .increased || (quireDrawingFlags?.increaseContrast ?? QuireEnvironment.increaseContrast)
        let mode: QuireMode = colorScheme == .dark ? (increased ? .darkHC : .dark) : (increased ? .lightHC : .light)
        return isGraphite || quireTheme.underlinesLinksAtRest(mode)
    }
}

struct QuireDrawingFlags: Equatable, Sendable {
    var isGraphite: Bool
    var increaseContrast: Bool
}

private struct QuireThemeKey: EnvironmentKey {
    static let defaultValue: QuireTheme? = nil
}

private struct QuireDrawingFlagsKey: EnvironmentKey {
    static let defaultValue: QuireDrawingFlags? = nil
}
