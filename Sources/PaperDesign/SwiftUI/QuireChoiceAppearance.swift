import SwiftUI

/// What a Quire checkbox or radio draws in one state (spec §5.26, `layout.checkbox`, `layout.radio`).
public struct QuireChoiceAppearance: Equatable, Sendable {
    /// Off: `sheet`, washed `hover` / `pressed`; on (and mixed): `accentFill`, `accentFillHover` when hovered
    /// and `controlOnPressed` when pressed, which keeps ≥ 3:1 on `sheet` and `canvas` where
    /// `accentFillPressed` would not.
    public var face: QuireFill
    /// Off: the 1 pt `ruleStrong` edge; on: none.
    public var edge: QuireStroke?
    /// The checkmark, mixed bar or radio dot.
    public var mark: QuireColorToken
    /// 1 pt off, 2 pt on (a ring never touches a fill of its own hue).
    public var ringGap: CGFloat?
    public var controlOpacity: CGFloat
    public var label: QuireColorToken

    public init(face: QuireFill, edge: QuireStroke?, mark: QuireColorToken, ringGap: CGFloat?, controlOpacity: CGFloat,
                label: QuireColorToken) {
        self.face = face
        self.edge = edge
        self.mark = mark
        self.ringGap = ringGap
        self.controlOpacity = controlOpacity
        self.label = label
    }

    /// `isOn` covers mixed too: a mixed checkbox is filled like an on one and differs only by its mark.
    public static func resolve(isOn: Bool, state live: QuireControlState) -> QuireChoiceAppearance {
        let state = live.interactive
        let face: QuireFill
        if isOn {
            face = QuireFill(state.isPressed ? .controlOnPressed : state.isHovered ? .accentFillHover : .accentFill)
        } else {
            face = QuireFill(.sheet, wash: state.isPressed ? .pressed : state.isHovered ? .hover : nil)
        }
        return QuireChoiceAppearance(
            face: face,
            edge: isOn ? nil : .strong,
            mark: .onAccent,
            ringGap: state.showsFocusRing ? (isOn ? Quire.Border.FocusRing.gapOnAccentFill : Quire.Border.FocusRing.gap) : nil,
            controlOpacity: state.isEnabled ? 1 : Quire.Layout.Checkbox.disabledOpacity,
            label: state.isEnabled ? .ink : .inkDisabled)
    }
}
