import SwiftUI

/// Settings › Accounts › Face (spec §5.55, §5.40): the account's face as a button, 30 pt with its account ring, that
/// opens the face picker. Its layout size is the face, the ring drawn outside it as on every account face, so it takes
/// the Monogram field's old row at the same height.
///
/// Hover and pressed darken the face only (`hover`, `pressed` over the disc): a wash under the ring would drop Jade's
/// ring below 3:1 on `sheet` in Dark IC, so the spec forbids one there as on the account rows. Focused, the Quire focus
/// ring goes round the account ring. It is always a Tab stop; Space and Return open the picker, as a click does.
/// VoiceOver reads it as a button named `title` whose value is the account, never the face's own name: only the picker
/// names faces.
public struct QuireFaceButton: View {
    let face: QuireAccountFace
    let ink: Int
    let title: String
    let accountName: String
    let isOpen: Bool
    let focus: FocusState<Bool>.Binding?
    let action: () -> Void

    @FocusState private var ownFocus: Bool

    /// - Parameters:
    ///   - title: the button's accessibility label, the Settings row's label (“Face”).
    ///   - accountName: what VoiceOver reads as its value.
    ///   - isOpen: the picker is showing; the face then draws pressed.
    ///   - focus: an external focus binding, so the form can give focus back when the picker closes.
    public init(face: QuireAccountFace, ink: Int, title: String = "Face", accountName: String, isOpen: Bool = false,
                focus: FocusState<Bool>.Binding? = nil, action: @escaping () -> Void) {
        self.face = face
        self.ink = ink
        self.title = title
        self.accountName = accountName
        self.isOpen = isOpen
        self.focus = focus
        self.action = action
    }

    public var body: some View {
        let focused = focus?.wrappedValue ?? ownFocus
        Button(action: action) {
            EmptyView()
        }
        .buttonStyle(QuireFaceButtonStyle(face: face, ink: ink, isOpen: isOpen, isFocused: focused))
        .focusable()
        .focusEffectDisabled()
        .focused(focus ?? $ownFocus)
        .onKeyPress(.space) {
            action()
            return .handled
        }
        .onKeyPress(.return) {
            action()
            return .handled
        }
        .quirePointer()
        .accessibilityLabel(title)
        .accessibilityValue(accountName)
        .accessibilityHint("Choose the account's face")
    }
}

/// The face, its ring, the darkening and the focus ring, in every state of the button.
struct QuireFaceButtonStyle: ButtonStyle {
    let face: QuireAccountFace
    let ink: Int
    let isOpen: Bool
    let isFocused: Bool

    func makeBody(configuration: Configuration) -> some View {
        QuireFaceButtonFace(face: face, ink: ink, isPressed: configuration.isPressed || isOpen, isFocused: isFocused)
    }
}

struct QuireFaceButtonFace: View {
    let face: QuireAccountFace
    let ink: Int
    let isPressed: Bool
    let isFocused: Bool

    @State private var isHovered = false
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.quireForcedStates) private var forced

    var body: some View {
        let diameter = Quire.Layout.Settings.accountFace
        let state = QuireControlState(isHovered: isHovered, isPressed: isPressed, isFocused: isFocused, isWindowKey: activeState != .inactive)
            .forcing(forced)
        let ring = Quire.Border.AccountRing.gap + Quire.Border.AccountRing.width
        QuireAvatarView(account: face, ink: ink, diameter: diameter)
            .overlay {
                if state.isPressed {
                    Circle().fill(.qPressed).allowsHitTesting(false)
                } else if state.isHovered {
                    Circle().fill(.qHover).allowsHitTesting(false)
                }
            }
            .overlay {
                if state.showsFocusRing {
                    QuireFocusRingView(shape: .circle, gap: Quire.Border.FocusRing.gap)
                        .padding(-ring)
                        .allowsHitTesting(false)
                }
            }
            // The click lands anywhere on the ring, as on the rail's tile.
            .contentShape(Circle().inset(by: -ring))
            .onHover { isHovered = $0 }
            .accessibilityHidden(true)
    }
}
