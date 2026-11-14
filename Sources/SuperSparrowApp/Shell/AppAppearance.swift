import AppKit

/// Settings › Appearance › Appearance (spec §5.40, §4.16): which half of the theme's light and dark pair the app shows.
/// macOS has no per-app appearance setting, so without it a theme chosen for its night is out of reach by day.
enum AppAppearance: String, CaseIterable, Sendable {
    /// Follows macOS, as the app always did.
    case automatic
    case light
    case dark

    /// What `NSApp.appearance` takes: nil follows the system, the path a system switch already takes, so every window,
    /// web view and colour provider re-resolves exactly as it does then. Never an Increase Contrast appearance:
    /// `QuireEnvironment` carries that, because AppKit does not report it for an appearance the app sets.
    var nsAppearance: NSAppearance? {
        switch self {
        case .automatic: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
