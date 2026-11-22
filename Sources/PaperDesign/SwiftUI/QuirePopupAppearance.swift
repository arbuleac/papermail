import SwiftUI

/// What a Quire popup button draws in one state (spec §5.27, `layout.popup`).
public struct QuirePopupAppearance: Equatable, Sendable {
    /// `raised`, washed `hover` / `pressed` (pressed: its menu is open); `fill` when disabled. The borderless
    /// variant has no face until hovered.
    public var face: QuireFill
    public var edge: QuireStroke?
    public var label: QuireColorToken
    public var chevron: QuireColorToken
    public var ringGap: CGFloat?

    public init(face: QuireFill, edge: QuireStroke?, label: QuireColorToken, chevron: QuireColorToken, ringGap: CGFloat?) {
        self.face = face
        self.edge = edge
        self.label = label
        self.chevron = chevron
        self.ringGap = ringGap
    }

    public static func resolve(borderless: Bool = false, state live: QuireControlState) -> QuirePopupAppearance {
        let state = live.interactive
        let ring = state.showsFocusRing ? Quire.Border.FocusRing.gap : nil
        guard state.isEnabled else {
            return QuirePopupAppearance(face: borderless ? .clear : QuireFill(wash: .fill), edge: nil,
                                        label: .inkDisabled, chevron: .inkDisabled, ringGap: nil)
        }
        let wash: QuireColorToken? = state.isPressed ? .pressed : state.isHovered ? .hover : nil
        let face: QuireFill
        if borderless {
            face = wash == nil ? .clear : QuireFill(.raised, wash: wash)
        } else {
            face = QuireFill(.raised, wash: wash)
        }
        return QuirePopupAppearance(face: face, edge: borderless ? nil : .strong, label: .ink, chevron: .ink2, ringGap: ring)
    }
}
