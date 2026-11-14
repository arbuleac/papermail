import AppKit
import SwiftUI

/// The Quire switch (spec §5.26, §8.3): a 30 × 18 capsule track (`fill` + `ruleStrong` edge off,
/// `accentFill` on) and a 14 pt knob with its `ruleStrong` edge and static contact shadow
/// (`layout.toggle.knobShadow`). The knob travels in `dur.quick` `ease.glide` (instant under Reduce Motion);
/// a press stretches it to 18 pt toward the centre at once and lets it back in `dur.quick`. The label is
/// `body` `ink`, 8 pt from the track, and part of the click target. Toggles apply at once.
///
///     Toggle("Load by default", isOn: $loadImages).toggleStyle(.quire)
///
/// Internally the toggle is a button (for `isPressed`) whose accessibility representation is the native
/// switch, so VoiceOver reads it as one.
public struct QuireToggleStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(QuireToggleBody(isOn: configuration.isOn))
        .focusEffectDisabled()
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

extension ToggleStyle where Self == QuireToggleStyle {
    /// The Quire switch.
    public static var quire: QuireToggleStyle { QuireToggleStyle() }
}

struct QuireToggleBody: ButtonStyle {
    let isOn: Bool

    func makeBody(configuration: Configuration) -> some View {
        QuireToggleChrome(isOn: isOn, isPressed: configuration.isPressed) { configuration.label }
    }
}

struct QuireToggleChrome<Label: View>: View {
    let isOn: Bool
    let isPressed: Bool
    @ViewBuilder let label: () -> Label

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.quireForcedStates) private var forced
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let state = QuireControlState(isPressed: isPressed, isFocused: isFocused, isEnabled: isEnabled,
                                      isWindowKey: activeState != .inactive).forcing(forced)
        let a = QuireToggleAppearance.resolve(isOn: isOn, state: state)
        HStack(spacing: Quire.Layout.Checkbox.labelGap) {
            QuireToggleTrack(appearance: a, travel: travel, release: isPressed ? nil : travel, isOn: isOn,
                             isPressed: state.isPressed)
            label()
                .quireFont(.body)
                .foregroundStyle(a.label.style)
        }
        .contentShape(Rectangle())
    }

    /// Knob travel: `dur.quick` `ease.glide`, instant under Reduce Motion (spec §4.10).
    private var travel: Animation? {
        .quire(Quire.Motion.plan(Quire.Motion.quick, .glide, reduced: .instant,
                                 reduceMotion: reduceMotion || QuireEnvironment.reduceMotion))
    }
}

struct QuireToggleTrack: View {
    let appearance: QuireToggleAppearance
    let travel: Animation?
    /// Nil while pressed: the stretch is instant on mouse-down and animates only on the way back.
    let release: Animation?
    let isOn: Bool
    let isPressed: Bool

    var body: some View {
        let t = Quire.Layout.Toggle.self
        let a = appearance
        ZStack(alignment: .leading) {
            QuireFace(shape: Capsule(style: .circular), fill: a.track, edge: a.trackEdge)
            QuireFace(shape: Capsule(style: .circular), fill: QuireFill(a.knobFace), edge: a.knobEdge)
                .frame(width: a.knobWidth, height: t.knob)
                .shadow(color: QuireToggleTrack.knobShadow.color, radius: QuireToggleTrack.knobShadow.radius,
                        x: Quire.Layout.Toggle.KnobShadow.x, y: Quire.Layout.Toggle.KnobShadow.y)
                .offset(x: a.knobX)
                .animation(travel, value: isOn)
                .animation(release, value: isPressed)
        }
        .frame(width: t.width, height: t.height)
        .opacity(a.controlOpacity)
        .overlay {
            if let gap = a.ringGap {
                QuireFocusRingView(shape: .capsule, gap: gap).allowsHitTesting(false)
            }
        }
    }

    /// The knob's contact shadow (`layout.toggle.knobShadow`): one colour per mode, blur 2. SwiftUI's shadow
    /// radius is the CSS blur / 2, as `CALayer.shadowRadius` is (spec §4.8).
    static let knobShadow: (color: Color, radius: CGFloat) = {
        let s = Quire.Layout.Toggle.KnobShadow.self
        let values = QuireColorValues(light: rgba(s.light), dark: rgba(s.dark), lightHC: rgba(s.lightHC), darkHC: rgba(s.darkHC))
        return (Color(nsColor: NSColor.quire("toggle.knobShadow", values)), s.blur / 2)
    }()

    /// "#RRGGBBAA" (or "#RRGGBB") from tokens.json.
    static func rgba(_ hex: String) -> UInt32 {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        let value = UInt32(digits, radix: 16) ?? 0
        return digits.count == 6 ? (value << 8) | 0xFF : value
    }
}
