import SwiftUI

/// Quire radios for one of a few choices (spec §5.26, §8.3), laid out in a row 16 pt apart: each option a 14 pt
/// circle (`sheet` + `ruleStrong` off, `accentFill` with a 6 pt `onAccent` dot on; hover and press as the
/// checkbox) and its `body` label 8 pt after it.
///
/// The group is one Tab stop; ← and → move the choice (wrapping is deliberately off, as native radio groups
/// do), and the ring is drawn around the selected circle, 2 pt out because it is filled. Clicking an option
/// chooses it. VoiceOver sees the native radio group (`Picker` with `.radioGroup`), whose options report
/// `isSelected`.
///
///     QuireRadioGroup("List density", selection: $density, options: [.standard, .compact]) { $0.title }
public struct QuireRadioGroup<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String
    let focus: FocusState<Bool>.Binding?

    @FocusState private var ownFocus: Bool
    @Environment(\.quireForcedStates) private var forced

    /// - Parameters:
    ///   - title: the group's accessibility label (the Settings row label beside it).
    ///   - focus: an external focus binding, for forms that move focus themselves; the group tracks its own
    ///     otherwise.
    public init(_ title: String, selection: Binding<Value>, options: [Value], focus: FocusState<Bool>.Binding? = nil,
                label: @escaping (Value) -> String) {
        self.title = title
        _selection = selection
        self.options = options
        self.focus = focus
        self.label = label
    }

    public var body: some View {
        let groupFocused = (focus?.wrappedValue ?? ownFocus) || forced.contains(.focused)
        HStack(spacing: Quire.Space.s6) {
            ForEach(options, id: \.self) { option in
                Button {
                    selection = option
                } label: {
                    Text(label(option))
                }
                .buttonStyle(QuireRadioBody(isOn: option == selection, groupFocused: groupFocused && option == selection))
                .focusable(false)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused(focus ?? $ownFocus)
        .onMoveCommand { direction in
            switch direction {
            case .left: move(by: -1)
            case .right: move(by: 1)
            default: break
            }
        }
        .accessibilityRepresentation {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
        }
    }

    /// The choice `offset` steps along, clamped to the ends.
    func move(by offset: Int) {
        guard let next = QuireStep.index(after: options.firstIndex(of: selection), by: offset, count: options.count) else { return }
        selection = options[next]
    }
}

struct QuireRadioBody: ButtonStyle {
    let isOn: Bool
    let groupFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        QuireChoiceChrome(kind: .radio, isOn: isOn, isPressed: configuration.isPressed, groupFocused: groupFocused) {
            configuration.label
        }
    }
}
