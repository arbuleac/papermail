import SwiftUI

/// The Quire focus ring for any SwiftUI view (spec §4.1, §8.3): turns off the system focus effect, tracks focus
/// with `@FocusState`, and overlays a 2 pt `focus` ring (3 pt under Increase Contrast) outside the view, `gap`
/// away from it. The system ring's alpha falls below 3:1 on `canvas`, so no control in Settings may keep it.
///
/// The Quire styles draw this ring themselves (a button style cannot attach `@FocusState` to its button), so
/// this modifier is for everything else: a custom focusable view, or a control whose style is not Quire's.
/// The ring is hidden while the window is not key (`controlActiveState == .inactive`, spec §3.4) and when the
/// view is disabled. `.quireForcedStates(.focused)` shows it without focus.
public struct QuireFocusRing: ViewModifier {
    public let shape: QuireFocusRingShape
    public let gap: CGFloat
    public let makesFocusable: Bool

    @FocusState private var isFocused: Bool
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.quireForcedStates) private var forced

    /// - Parameters:
    ///   - shape: the control's outline; the ring follows it plus the gap.
    ///   - gap: 1 pt (`border.focusRing.gap`); 2 pt around anything filled with `accentFill` and around
    ///     sheets (`gapOnAccentFill`, `gapAroundSheets`).
    ///   - focusable: adds `.focusable()` for views that are not focusable on their own. Leave it off for
    ///     controls (text fields, buttons), whose focusability the system decides.
    public init(_ shape: QuireFocusRingShape, gap: CGFloat = Quire.Border.FocusRing.gap, focusable: Bool = false) {
        self.shape = shape
        self.gap = gap
        self.makesFocusable = focusable
    }

    public func body(content: Content) -> some View {
        let state = QuireControlState(isFocused: isFocused, isEnabled: isEnabled, isWindowKey: activeState != .inactive)
            .forcing(forced.intersection(.focused))
        return content
            .modifier(QuireOptionalFocusable(isOn: makesFocusable))
            .focusEffectDisabled()
            .focused($isFocused)
            .overlay {
                if state.showsFocusRing {
                    QuireFocusRingView(shape: shape, gap: gap).allowsHitTesting(false)
                }
            }
    }
}

/// `.focusable()` only when asked: `.focusable(false)` would take a button out of the key view loop.
struct QuireOptionalFocusable: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.focusable()
        } else {
            content
        }
    }
}

extension View {
    /// Draws the Quire focus ring around this view while it has keyboard focus (see `QuireFocusRing`).
    public func quireFocusRing(_ shape: QuireFocusRingShape, gap: CGFloat = Quire.Border.FocusRing.gap,
                               focusable: Bool = false) -> some View {
        modifier(QuireFocusRing(shape, gap: gap, focusable: focusable))
    }
}
