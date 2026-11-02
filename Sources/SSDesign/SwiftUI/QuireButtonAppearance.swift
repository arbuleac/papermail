import SwiftUI

/// What a Quire button draws in one state: the state → token table of spec §5.24, resolved.
public struct QuireButtonAppearance: Equatable, Sendable {
    public var fill: QuireFill
    public var edge: QuireStroke?
    public var label: QuireColorToken
    public var font: QuireFont.Role
    /// The link underline: on hover and press, and at rest under Graphite (spec §3.1).
    public var underline: Bool
    /// The gap between the control and its focus ring, or nil when no ring shows.
    public var ringGap: CGFloat?
    public var height: CGFloat
    /// Fixed width for icon buttons; text buttons size to their label plus `padX` on each side.
    public var width: CGFloat?
    public var padX: CGFloat
    public var cornerRadius: CGFloat

    public init(fill: QuireFill, edge: QuireStroke?, label: QuireColorToken, font: QuireFont.Role, underline: Bool,
                ringGap: CGFloat?, height: CGFloat, width: CGFloat?, padX: CGFloat, cornerRadius: CGFloat) {
        self.fill = fill
        self.edge = edge
        self.label = label
        self.font = font
        self.underline = underline
        self.ringGap = ringGap
        self.height = height
        self.width = width
        self.padX = padX
        self.cornerRadius = cornerRadius
    }

    public static func resolve(_ variant: QuireButtonVariant, size: QuireButtonSize, state live: QuireControlState) -> QuireButtonAppearance {
        let state = live.interactive
        // A primary button in a window that is not key draws as a secondary one, as native default buttons
        // do (spec §3.4); its ring is hidden there anyway.
        let variant = (variant == .primary && !state.isWindowKey) ? .secondary : variant
        let ring = state.showsFocusRing
        let gap = Quire.Border.FocusRing.gap
        let gapOnFill = Quire.Border.FocusRing.gapOnAccentFill

        var a = QuireButtonAppearance(fill: .clear, edge: nil, label: .ink, font: size.font, underline: false,
                                      ringGap: nil, height: size.height, width: nil, padX: size.padX,
                                      cornerRadius: size.radius)
        switch variant {
        case .primary, .destructive:
            let primary = variant == .primary
            a.font = size.fontStrong
            a.ringGap = ring ? gapOnFill : nil
            if !state.isEnabled {
                a.fill = QuireFill(wash: .fill)
                a.label = .inkDisabled
            } else if state.isPressed {
                a.fill = QuireFill(primary ? .accentFillPressed : .dangerFillPressed)
            } else if state.isHovered {
                a.fill = QuireFill(primary ? .accentFillHover : .dangerFillHover)
            } else {
                a.fill = QuireFill(primary ? .accentFill : .dangerFill)
            }
            if state.isEnabled { a.label = primary ? .onAccent : .onDanger }

        case .secondary:
            a.ringGap = ring ? gap : nil
            if !state.isEnabled {
                a.fill = QuireFill(wash: .fill)
                a.label = .inkDisabled
            } else {
                a.fill = QuireFill(.raised, wash: state.isPressed ? .pressed : state.isHovered ? .hover : nil)
                a.edge = .strong
            }

        case .ghost, .icon:
            a.ringGap = ring ? gap : nil
            if variant == .icon {
                a.width = size.iconSide
                a.height = size.iconSide
                a.padX = 0
                a.cornerRadius = size.iconRadius
            }
            if !state.isEnabled {
                a.label = .inkDisabled
            } else if state.isPressed {
                a.fill = QuireFill(wash: .pressed)
            } else if state.isHovered {
                a.fill = QuireFill(wash: .hover)
            }
            if state.isEnabled { a.label = (state.isPressed || state.isHovered) ? .ink : .ink2 }

        case .link:
            a.ringGap = ring ? gap : nil
            // The specimen's link box: 4 pt either side of the words, at least the minimum hit height.
            a.padX = Quire.Layout.Button.linkPadX
            a.height = max(size.height, Quire.Layout.Button.minHit)
            if !state.isEnabled {
                a.label = .inkDisabled
            } else {
                a.label = state.isPressed ? .ink2 : .accent
            }
            a.underline = state.isGraphite || (state.isEnabled && (state.isPressed || state.isHovered))
        }
        return a
    }
}
