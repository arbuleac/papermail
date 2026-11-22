import SwiftUI

/// What a Quire text field draws in one state (spec §5.25, `layout.textField`).
public struct QuireFieldAppearance: Equatable, Sendable {
    /// `sheet`; `fill` when disabled.
    public var face: QuireFill
    /// 1 pt `ruleStrong` at rest and focused (focus is the ring, never an edge colour), `ink3` hovered,
    /// 1.5 pt `danger` with an error, none when disabled.
    public var edge: QuireStroke?
    public var text: QuireColorToken
    public var placeholder: QuireColorToken
    public var ringGap: CGFloat?

    public init(face: QuireFill, edge: QuireStroke?, text: QuireColorToken, placeholder: QuireColorToken, ringGap: CGFloat?) {
        self.face = face
        self.edge = edge
        self.text = text
        self.placeholder = placeholder
        self.ringGap = ringGap
    }

    public static func resolve(hasError: Bool, state live: QuireControlState) -> QuireFieldAppearance {
        let state = live.interactive
        guard state.isEnabled else {
            return QuireFieldAppearance(face: QuireFill(wash: .fill), edge: nil, text: .inkDisabled, placeholder: .inkDisabled,
                                        ringGap: nil)
        }
        let edge: QuireStroke
        if hasError {
            edge = .error
        } else if state.isHovered {
            edge = QuireStroke(.ink3)
        } else {
            edge = .strong
        }
        return QuireFieldAppearance(face: QuireFill(.sheet), edge: edge, text: .ink, placeholder: .ink3,
                                    ringGap: state.showsFocusRing ? Quire.Border.FocusRing.gap : nil)
    }
}
