import SwiftUI

/// Interaction states a Quire SwiftUI style draws even when the pointer and keyboard are not producing them,
/// so a gallery, a snapshot or a test can show every state of a control side by side.
///
/// Set them with `.quireForcedStates(_:)` (the `quireForcedStates` environment value). Every Quire style in
/// this folder reads it and ORs it into the live state: `QuireButtonStyle`, `QuireToggleStyle`,
/// `QuireCheckboxStyle`, `QuireRadioGroup`, `QuirePopupLabel`, `QuireFieldStyle`, `QuireFocusRingModifier`, the +/−
/// buttons of `QuireAccountGroup` and the banner's dismiss button. Forcing never changes enabled or window-key
/// state: disable with `.disabled(true)` and show a non-key window with
/// `.environment(\.controlActiveState, .inactive)`. A forced ring is still hidden in a non-key window or on a
/// disabled control, exactly as a real one is (spec §3.4).
public struct QuireForcedStates: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// Draw as if the pointer were over the control.
    public static let hovered = QuireForcedStates(rawValue: 1 << 0)
    /// Draw as if the mouse button were down on it (a popup: as if its menu were open).
    public static let pressed = QuireForcedStates(rawValue: 1 << 1)
    /// Draw as if it had keyboard focus.
    public static let focused = QuireForcedStates(rawValue: 1 << 2)
}

private struct QuireForcedStatesKey: EnvironmentKey {
    static let defaultValue: QuireForcedStates = []
}

extension EnvironmentValues {
    /// States every Quire style below this point draws regardless of the pointer and the keyboard.
    public var quireForcedStates: QuireForcedStates {
        get { self[QuireForcedStatesKey.self] }
        set { self[QuireForcedStatesKey.self] = newValue }
    }
}

extension View {
    /// Forces `states` on every Quire control below this view (see `QuireForcedStates`).
    public func quireForcedStates(_ states: QuireForcedStates) -> some View {
        environment(\.quireForcedStates, states)
    }
}
