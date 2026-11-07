import AppKit
import os

/// The system settings Quire draws differently for (spec §3.1, §3.3): the Graphite accent, Increase Contrast,
/// Reduce Motion and Reduce Transparency; and the one app setting every component draws for, the Font
/// setting (spec §4.4), which the app sets with `setTypeface(_:)` because no system setting holds it.
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
        var overrides: Overrides
        var current: Snapshot
    }

    private let state: OSAllocatedUnfairLock<State>

    private override init() {
        let system = QuireEnvironment.readSystem()
        state = OSAllocatedUnfairLock(initialState: State(system: system, typeface: .newYork, overrides: Overrides(), current: system))
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

    /// The part of the environment drawn colours and type depend on: the resolved mode (Increase Contrast
    /// included), the Graphite flag and the typeface. Row and avatar caches key on it, never on window key state
    /// (spec §8.2).
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

    @objc private func systemSettingsDidChange(_ note: Notification) {
        refresh()
    }

    private func update(_ change: (inout State) -> Void) {
        let changed: Bool = state.withLock { s in
            let before = s.current
            change(&s)
            var base = s.system
            base.typeface = s.typeface
            s.current = QuireEnvironment.apply(s.overrides, to: base)
            return s.current != before
        }
        guard changed else { return }
        if Thread.isMainThread {
            NotificationCenter.default.post(name: QuireEnvironment.didChangeNotification, object: self)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: QuireEnvironment.didChangeNotification, object: self)
            }
        }
    }

    // MARK: System

    static func apply(_ o: Overrides, to s: Snapshot) -> Snapshot {
        Snapshot(isGraphite: o.isGraphite ?? s.isGraphite,
                 increaseContrast: o.increaseContrast ?? s.increaseContrast,
                 reduceMotion: o.reduceMotion ?? s.reduceMotion,
                 reduceTransparency: o.reduceTransparency ?? s.reduceTransparency,
                 typeface: o.typeface ?? s.typeface)
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
