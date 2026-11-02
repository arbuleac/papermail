import SwiftUI

/// Everything a Quire control's look depends on besides its own value. The `resolve` functions of the
/// appearance types turn it into tokens; they are pure, so the state → token tables of spec §5.24–§5.27 and
/// §5.40 are tested without rendering anything.
public struct QuireControlState: Equatable, Sendable {
    public var isHovered: Bool
    public var isPressed: Bool
    public var isFocused: Bool
    public var isEnabled: Bool
    /// False while the control's window is not key (`controlActiveState == .inactive`): selection turns idle,
    /// primary buttons draw as secondary and focus rings are hidden (spec §3.4).
    public var isWindowKey: Bool
    /// The system accent is Graphite (spec §3.1). Colours follow it on their own through the token providers;
    /// this flag carries the one structural change, the link underline at rest.
    public var isGraphite: Bool

    public init(isHovered: Bool = false, isPressed: Bool = false, isFocused: Bool = false, isEnabled: Bool = true,
                isWindowKey: Bool = true, isGraphite: Bool = false) {
        self.isHovered = isHovered
        self.isPressed = isPressed
        self.isFocused = isFocused
        self.isEnabled = isEnabled
        self.isWindowKey = isWindowKey
        self.isGraphite = isGraphite
    }

    /// The state with `forced` added on top of the live one.
    public func forcing(_ forced: QuireForcedStates) -> QuireControlState {
        var s = self
        if forced.contains(.hovered) { s.isHovered = true }
        if forced.contains(.pressed) { s.isPressed = true }
        if forced.contains(.focused) { s.isFocused = true }
        return s
    }

    /// A disabled control takes no hover or press, whatever the pointer does.
    var interactive: QuireControlState {
        guard !isEnabled else { return self }
        var s = self
        s.isHovered = false
        s.isPressed = false
        return s
    }

    /// The ring shows on the focused control of a key window only, never on a disabled one (spec §3.4, §4.1).
    var showsFocusRing: Bool { isFocused && isEnabled && isWindowKey }
}
