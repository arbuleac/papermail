import AppKit
import os

/// The system settings Quire draws differently for (spec §3.1, §3.3): the Graphite accent, Increase Contrast,
/// Reduce Motion and Reduce Transparency; the two app settings Quire draws type for, the Font setting (spec §4.4) and
/// Text size (spec §4.15); and the theme (spec §4.16), which every themed colour provider draws. The app sets those
/// three with `setTypeface(_:)`, `setTextSize(_:)` and `setTheme(_:)` because no system setting holds them.
///
/// The flags live in a lock-protected snapshot rather than main-actor state because the dynamic colour
/// providers read `isGraphite`, and AppKit resolves colours on whatever thread draws. Changes are observed
/// on the main thread and announced with `didChangeNotification`, posted on the main thread; layer-backed
/// views re-resolve their colours on it (`QuireLayerColors`), views that hold a font or a laid-out string
/// re-apply it, and caches add `cacheKey(for:)` to their keys. Fonts are built off the main thread too, which
/// is why the typeface lives in the same snapshot rather than in main-actor app state.
public final class QuireEnvironment: NSObject, @unchecked Sendable {
    public static let shared = QuireEnvironment()

    /// Posted on the main thread, by `shared`, whenever a field of the snapshot changes (the typeface
    /// included). Appearance changes are not posted here: views learn those from
    /// `viewDidChangeEffectiveAppearance()`.
    public static let didChangeNotification = Notification.Name("QuireEnvironmentDidChange")

    private struct State: Sendable {
        var system: Snapshot
        /// The app's Font setting, kept apart from `system` so a re-read of the system settings cannot reset it.
        var typeface: QuireFont.Typeface
        /// The app's Text size, kept apart for the same reason.
        var textSize: QuireFont.TextSize
        /// The app's theme, kept apart for the same reason.
        var theme: QuireTheme
        var overrides: Overrides
        var current: Snapshot
    }

    private let state: OSAllocatedUnfairLock<State>

    private override init() {
        let system = QuireEnvironment.readSystem()
        state = OSAllocatedUnfairLock(initialState: State(system: system, typeface: .newYork, textSize: .default, theme: .study,
                                                             overrides: Overrides(), current: system))
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(systemSettingsDidChange(_:)),
                                               name: NSColor.systemColorsDidChangeNotification, object: nil)
        // AppKit posts the accessibility change to the workspace's centre; the default centre is observed too
        // because a refresh is idempotent and some releases have posted it there.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(systemSettingsDidChange(_:)),
                                                          name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(systemSettingsDidChange(_:)),
                                               name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    // MARK: Reading

    public var snapshot: Snapshot { state.withLock { $0.current } }
    public var overrides: Overrides { state.withLock { $0.overrides } }

    /// True while every accent-family token draws its Graphite substitution (spec §3.1).
    public static var isGraphite: Bool { shared.snapshot.isGraphite }
    public static var increaseContrast: Bool { shared.snapshot.increaseContrast }
    public static var reduceMotion: Bool { shared.snapshot.reduceMotion }
    public static var reduceTransparency: Bool { shared.snapshot.reduceTransparency }
    /// The face New York roles are set in (spec §4.4): New York until the app says otherwise.
    public static var typeface: QuireFont.Typeface { shared.snapshot.typeface }
    /// Settings › Appearance › Text size (spec §4.15): Default until the app says otherwise. Only the surfaces where
    /// mail is read and written ask for it.
    public static var textSize: QuireFont.TextSize { shared.snapshot.textSize }
    /// The theme every themed colour draws (spec §4.16): Study until the app says otherwise.
    public static var theme: QuireTheme { shared.snapshot.theme }

    /// Whether a link in the ink draws its underline at rest under `appearance` (spec §3.1, §4.16): under Graphite, and
    /// wherever the theme's ink sits too near its text ink for colour alone to mark a link. Per appearance, because the
    /// theme's flag is per mode. False for Study outside Graphite in every mode.
    public static func underlinesLinksAtRest(for appearance: NSAppearance) -> Bool {
        let s = shared.snapshot
        return s.isGraphite || s.theme.underlinesLinksAtRest(QuireMode(appearance, environmentContrast: s.increaseContrast))
    }

    /// The part of the environment drawn colours and type depend on: the resolved mode (Increase Contrast
    /// included), the Graphite flag and the typeface. Row and avatar caches key on it, never on window key state
    /// (spec §8.2). Not the Text size, which only the surfaces that ask for it depend on: they add it to their own
    /// keys, so an avatar face, which no size changes, is never drawn again for one. Not the theme either, for the same
    /// reason: a sender's face is drawn only from the avatar palette, which no theme changes; the row content and the
    /// account faces, which draw themed tokens, add it to their keys.
    public static func cacheKey(for appearance: NSAppearance) -> String {
        let s = shared.snapshot
        return "\(QuireMode(appearance).rawValue)|ic\(s.increaseContrast ? 1 : 0)|g\(s.isGraphite ? 1 : 0)|f\(s.typeface.rawValue)"
    }

    /// `cacheKey(for:)` under the current drawing appearance (inside `draw(_:)` or
    /// `performAsCurrentDrawingAppearance`).
    public static var cacheKey: String { cacheKey(for: NSAppearance.currentDrawing()) }

    // MARK: Changing

    /// Re-reads the system settings. Called on the system's change notifications; callable directly after
    /// launch or in tests.
    public func refresh() {
        let system = QuireEnvironment.readSystem()
        update { $0.system = system }
    }

    public func setOverrides(_ overrides: Overrides) {
        update { $0.overrides = overrides }
    }

    /// The Font setting (spec §4.4). The app calls it at launch, before its first window, and on every change;
    /// a change is posted like any other, so everything on screen re-applies its fonts at once.
    public func setTypeface(_ typeface: QuireFont.Typeface) {
        update { $0.typeface = typeface }
    }

    /// Text size (spec §4.15). Like the typeface: set at launch, before the first window, and on every change, which
    /// is posted so the list, the reader and every composer set their text again at once.
    public func setTextSize(_ textSize: QuireFont.TextSize) {
        update { $0.textSize = textSize }
    }

    /// The theme (spec §4.16). Like the Text size: set at launch, before the first window, and on every change, which is
    /// posted once. A change then marks every view of every window for redrawing (`redrawEveryWindow()`).
    public func setTheme(_ theme: QuireTheme) {
        update { $0.theme = theme }
    }

    @objc private func systemSettingsDidChange(_ note: Notification) {
        refresh()
    }

    private func update(_ change: (inout State) -> Void) {
        let (changed, themeChanged): (Bool, Bool) = state.withLock { s in
            let before = s.current
            change(&s)
            var base = s.system
            base.typeface = s.typeface
            base.textSize = s.textSize
            base.theme = s.theme
            s.current = QuireEnvironment.apply(s.overrides, to: base)
            return (s.current != before, s.current.theme != before.theme)
        }
        guard changed else { return }
        let announce = {
            NotificationCenter.default.post(name: QuireEnvironment.didChangeNotification, object: self)
            if themeChanged { MainActor.assumeIsolated { QuireEnvironment.redrawEveryWindow() } }
        }
        if Thread.isMainThread {
            announce()
        } else {
            DispatchQueue.main.async(execute: announce)
        }
    }

    /// The redraw sweep after a theme change (spec §4.16). Graphite and Increase Contrast touch only accent tokens, which
    /// every view already resolves while drawing; a theme changes every surface, and views that paint `paper`, `sheet`,
    /// `rule` or `ink` in `draw(_:)` otherwise redraw only on an appearance change. So every view of every window is
    /// marked, from the frame view down so the window background redraws too, and a window whose background is a Quire
    /// token takes it again, because AppKit keeps the resolved background until the colour is assigned.
    @MainActor
    static func redrawEveryWindow() {
        for window in NSApplication.shared.windows {
            if let background = window.backgroundColor, background.isQuireToken {
                window.backgroundColor = background
            }
            guard let root = window.contentView?.superview ?? window.contentView else { continue }
            markNeedsDisplay(root)
        }
    }

    @MainActor
    private static func markNeedsDisplay(_ view: NSView) {
        view.needsDisplay = true
        for subview in view.subviews { markNeedsDisplay(subview) }
    }

    // MARK: System

    static func apply(_ o: Overrides, to s: Snapshot) -> Snapshot {
        Snapshot(isGraphite: o.isGraphite ?? s.isGraphite,
                 increaseContrast: o.increaseContrast ?? s.increaseContrast,
                 reduceMotion: o.reduceMotion ?? s.reduceMotion,
                 reduceTransparency: o.reduceTransparency ?? s.reduceTransparency,
                 typeface: o.typeface ?? s.typeface,
                 textSize: o.textSize ?? s.textSize,
                 theme: o.theme ?? s.theme)
    }

    static func readSystem() -> Snapshot {
        let workspace = NSWorkspace.shared
        let saturation = NSColor.controlAccentColor.usingColorSpace(.sRGB)?.saturationComponent ?? 1
        return Snapshot(isGraphite: isGraphiteAccent(controlTint: NSColor.currentControlTint, accentSaturation: saturation),
                        increaseContrast: workspace.accessibilityDisplayShouldIncreaseContrast,
                        reduceMotion: workspace.accessibilityDisplayShouldReduceMotion,
                        reduceTransparency: workspace.accessibilityDisplayShouldReduceTransparency)
    }

    /// The Graphite test of spec §3.1. The saturation half treats any accent that is effectively grey as
    /// Graphite, so the control tint is not the only signal the decision rests on.
    public static func isGraphiteAccent(controlTint: NSControlTint, accentSaturation: CGFloat) -> Bool {
        controlTint == .graphiteControlTint || accentSaturation < CGFloat(Quire.Platform.graphiteSaturationMax)
    }
}
