import SwiftUI

/// The Quire checkbox (spec §5.26, §8.3): a 14 pt box, radius 3. Off: `sheet` with a `ruleStrong` edge (hover
/// and press wash the face); on: `accentFill` with a 10 pt `onAccent` checkmark; mixed (a toggle bound to
/// several values): `accentFill` with an 8 × 2 pt bar. The label is `body` `ink`, 8 pt from the box, and part
/// of the click target. Checkboxes are for options in a form; toggles apply at once.
///
///     Toggle("Show account faces in unified views", isOn: $initials).toggleStyle(.quireCheckbox)
public struct QuireCheckboxStyle: ToggleStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            configuration.label
        }
        .buttonStyle(QuireCheckboxBody(isOn: configuration.isOn, isMixed: configuration.isMixed))
        .focusEffectDisabled()
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.checkbox)
        }
    }
}

extension ToggleStyle where Self == QuireCheckboxStyle {
    /// The Quire checkbox.
    public static var quireCheckbox: QuireCheckboxStyle { QuireCheckboxStyle() }
}

struct QuireCheckboxBody: ButtonStyle {
    let isOn: Bool
    let isMixed: Bool

    func makeBody(configuration: Configuration) -> some View {
        QuireChoiceChrome(kind: .checkbox(mixed: isMixed), isOn: isOn || isMixed, isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

/// A checkbox or radio with its label, drawn from `QuireChoiceAppearance`.
struct QuireChoiceChrome<Label: View>: View {
    let kind: QuireChoiceMark.Kind
    let isOn: Bool
    let isPressed: Bool
    /// Radios in a group get their focus from the group, not from themselves.
    var groupFocused: Bool?
    @ViewBuilder let label: () -> Label

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.quireForcedStates) private var forced
    @State private var isHovered = false

    var body: some View {
        let state = QuireControlState(isHovered: isHovered, isPressed: isPressed, isFocused: groupFocused ?? isFocused,
                                      isEnabled: isEnabled, isWindowKey: activeState != .inactive)
            .forcing(groupFocused == nil ? forced : forced.subtracting(.focused))
        let a = QuireChoiceAppearance.resolve(isOn: isOn, state: state)
        HStack(spacing: Quire.Layout.Checkbox.labelGap) {
            QuireChoiceMark(kind: kind, isOn: isOn, appearance: a)
            label()
                .quireFont(.body)
                .foregroundStyle(a.label.style)
        }
        .contentShape(Rectangle())
        // A radio already chosen stays chosen whatever the click: the arrow (§4.17).
        .quirePointer(acts: !(kind == .radio && isOn))
        .onHover { isHovered = $0 }
    }
}

/// The 14 pt box or circle with its mark and ring.
struct QuireChoiceMark: View {
    enum Kind: Equatable {
        case checkbox(mixed: Bool)
        case radio
    }

    let kind: Kind
    let isOn: Bool
    let appearance: QuireChoiceAppearance

    var body: some View {
        let a = appearance
        ZStack {
            switch kind {
            case .checkbox(let mixed):
                let box = RoundedRectangle(cornerRadius: Quire.Layout.Checkbox.radius, style: .circular)
                QuireFace(shape: box, fill: a.face, edge: a.edge)
                if mixed {
                    let bar = Quire.Layout.Checkbox.mixedBar
                    RoundedRectangle(cornerRadius: bar[1] / 2, style: .circular)
                        .fill(a.mark.style)
                        .frame(width: bar[0], height: bar[1])
                } else if isOn {
                    QuireSymbolImage(name: "checkmark", size: .custom(Quire.Layout.Checkbox.glyph))
                        .foregroundStyle(a.mark.style)
                }
            case .radio:
                QuireFace(shape: Circle(), fill: a.face, edge: a.edge)
                if isOn {
                    Circle()
                        .fill(a.mark.style)
                        .frame(width: Quire.Layout.Radio.dot, height: Quire.Layout.Radio.dot)
                }
            }
        }
        .frame(width: side, height: side)
        .opacity(a.controlOpacity)
        .overlay {
            if let gap = a.ringGap {
                QuireFocusRingView(shape: kind == .radio ? .circle : .roundedRectangle(cornerRadius: Quire.Layout.Checkbox.radius),
                                   gap: gap)
                    .allowsHitTesting(false)
            }
        }
    }

    private var side: CGFloat {
        kind == .radio ? Quire.Layout.Radio.size : Quire.Layout.Checkbox.size
    }
}
