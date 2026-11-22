import SwiftUI

/// What a Quire toggle draws in one state (spec §5.26, `layout.toggle`). Neither the track nor the knob ever
/// takes a wash: a wash on the off track would drop the knob's edge under 3:1, so a press is a shape change
/// (the knob stretches from 14 to 18 pt toward the track's centre) and hover changes nothing.
public struct QuireToggleAppearance: Equatable, Sendable {
    /// Off: a `fill` wash over the surface beneath; on: `accentFill`.
    public var track: QuireFill
    /// Off: the 1 pt `ruleStrong` edge; on: none.
    public var trackEdge: QuireStroke?
    public var knobFace: QuireColorToken
    /// The 1 pt `ruleStrong` knob edge in both states: it is what shows where the knob sits.
    public var knobEdge: QuireStroke
    public var knobWidth: CGFloat
    /// The knob's leading edge, measured from the track's leading edge.
    public var knobX: CGFloat
    public var ringGap: CGFloat?
    /// 0.45 on the control when disabled; the label goes `inkDisabled` instead of fading.
    public var controlOpacity: CGFloat
    public var label: QuireColorToken

    public init(track: QuireFill, trackEdge: QuireStroke?, knobFace: QuireColorToken, knobEdge: QuireStroke,
                knobWidth: CGFloat, knobX: CGFloat, ringGap: CGFloat?, controlOpacity: CGFloat, label: QuireColorToken) {
        self.track = track
        self.trackEdge = trackEdge
        self.knobFace = knobFace
        self.knobEdge = knobEdge
        self.knobWidth = knobWidth
        self.knobX = knobX
        self.ringGap = ringGap
        self.controlOpacity = controlOpacity
        self.label = label
    }

    public static func resolve(isOn: Bool, state live: QuireControlState) -> QuireToggleAppearance {
        let state = live.interactive
        let t = Quire.Layout.Toggle.self
        let knobWidth = state.isPressed ? t.knobPressedWidth : t.knob
        // Off, the knob's leading edge stays at the inset and it grows toward the centre; on, its trailing edge
        // stays at the inset and it grows back toward the centre.
        let knobX = isOn ? t.width - t.inset - knobWidth : t.inset
        let edgeToken = QuireColorToken(rawValue: t.knobEdgeColor) ?? .ruleStrong
        return QuireToggleAppearance(
            track: isOn ? QuireFill(.accentFill) : QuireFill(wash: .fill),
            trackEdge: isOn ? nil : .strong,
            knobFace: .knob,
            knobEdge: QuireStroke(edgeToken, width: t.knobEdge),
            knobWidth: knobWidth,
            knobX: knobX,
            ringGap: state.showsFocusRing ? (isOn ? Quire.Border.FocusRing.gapOnAccentFill : Quire.Border.FocusRing.gap) : nil,
            controlOpacity: state.isEnabled ? 1 : Quire.Layout.Checkbox.disabledOpacity,
            label: state.isEnabled ? .ink : .inkDisabled)
    }
}
