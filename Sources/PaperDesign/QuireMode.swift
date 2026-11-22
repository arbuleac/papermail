import AppKit

/// The four colour modes every token has a value for (spec §3.3): Light, Dark, and the Increase Contrast
/// variant of each.
public enum QuireMode: String, CaseIterable, Sendable {
    case light
    case dark
    case lightHC
    case darkHC

    /// The appearances a provider can be asked to resolve for, in the order `bestMatch` ranks them.
    static let appearanceNames: [NSAppearance.Name] = [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]

    /// The mode a dynamic colour resolves to under `appearance`.
    ///
    /// `bestMatch` reports the high-contrast variants only for appearances AppKit derives while the system
    /// setting is on; `NSAppearance(named: .accessibilityHighContrastAqua)` hands back plain Aqua (verified on
    /// macOS 27). So Increase Contrast also comes from `QuireEnvironment` (the system flag, or an override),
    /// and from `performAsCurrent`, which is how tests and off-screen renders ask for an IC mode explicitly.
    public init(_ appearance: NSAppearance) {
        self.init(appearance, environmentContrast: QuireEnvironment.increaseContrast)
    }

    /// The provider's path: the environment snapshot is read once per resolution, by the caller.
    init(_ appearance: NSAppearance, environmentContrast: Bool) {
        let forced = QuireMode.forcedIncreaseContrast
        self.init(appearance, increaseContrast: forced ?? environmentContrast, allowAppearanceContrast: forced == nil)
    }

    /// The mode for `appearance` with Increase Contrast decided by the caller (on top of what the appearance
    /// itself reports).
    public init(_ appearance: NSAppearance, increaseContrast: Bool) {
        self.init(appearance, increaseContrast: increaseContrast, allowAppearanceContrast: true)
    }

    private init(_ appearance: NSAppearance, increaseContrast: Bool, allowAppearanceContrast: Bool) {
        let base: QuireMode
        switch appearance.bestMatch(from: QuireMode.appearanceNames) {
        case .darkAqua?: base = .dark
        case .accessibilityHighContrastAqua?: base = allowAppearanceContrast ? .lightHC : .light
        case .accessibilityHighContrastDarkAqua?: base = allowAppearanceContrast ? .darkHC : .dark
        default: base = .light
        }
        self = increaseContrast ? base.increased : base
    }

    /// The appearance whose light or dark half this mode is. For the IC modes it is the plain appearance:
    /// resolve inside `performAsCurrent` to get their values.
    public var appearanceName: NSAppearance.Name { isDark ? .darkAqua : .aqua }

    public var appearance: NSAppearance {
        // Both names are system appearances, so the lookup cannot fail on a supported macOS.
        NSAppearance(named: appearanceName) ?? NSAppearance.currentDrawing()
    }

    public var isDark: Bool { self == .dark || self == .darkHC }
    public var isIncreasedContrast: Bool { self == .lightHC || self == .darkHC }

    var increased: QuireMode { isDark ? .darkHC : .lightHC }

    var index: Int {
        switch self {
        case .light: return 0
        case .dark: return 1
        case .lightHC: return 2
        case .darkHC: return 3
        }
    }

    // MARK: Resolving in a given mode

    private static let forcedKey = "QuireMode.forcedIncreaseContrast"

    /// Set on this thread while `performAsCurrent` runs.
    static var forcedIncreaseContrast: Bool? {
        Thread.current.threadDictionary[forcedKey] as? Bool
    }

    /// Runs `body` with this mode as the current drawing mode on this thread: its appearance as the current
    /// drawing appearance and its contrast forced, whatever the system says. Dynamic Quire colours resolved
    /// inside (`cgColor`, `usingColorSpace`, `set()`) take this mode's values.
    public func performAsCurrent<T>(_ body: () -> T) -> T {
        let dictionary = Thread.current.threadDictionary
        let previous = dictionary[QuireMode.forcedKey]
        dictionary[QuireMode.forcedKey] = isIncreasedContrast
        defer { dictionary[QuireMode.forcedKey] = previous }
        var result: T?
        appearance.performAsCurrentDrawingAppearance {
            result = body()
        }
        // performAsCurrentDrawingAppearance runs its block synchronously, exactly once.
        return result!
    }
}
