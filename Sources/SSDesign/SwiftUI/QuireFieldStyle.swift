import SwiftUI

/// The Quire text-field container (spec §5.25, §8.3): a 24 pt `sheet` face (28 pt outside Settings), radius 6,
/// a 1 pt `ruleStrong` inset edge (`ink3` hovered, 1.5 pt `danger` with an error), 8 pt padding, `body` or
/// `mono` text in `ink`, and the Quire focus ring outside a 1 pt gap; never the system ring. An error adds
/// its help line 5 pt below the field, in `meta` `danger` after an `exclamationmark.triangle.fill`.
///
///     TextField("Client ID", text: $clientID, prompt: QuireFieldStyle.prompt("….apps.googleusercontent.com"))
///         .quireFieldStyle(.mono, error: idError)
///
/// It applies `.textFieldStyle(.plain)` itself, so it works on `TextField` and `SecureField` alike. Focus is
/// tracked with its own `@FocusState`, or with `focus` when the form needs to move focus itself.
public struct QuireFieldStyle: ViewModifier {
    public let variant: QuireFieldVariant
    public let error: String?
    public let height: CGFloat
    let focus: FocusState<Bool>.Binding?

    @FocusState private var ownFocus: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.quireForcedStates) private var forced
    @State private var isHovered = false

    /// - Parameters:
    ///   - error: the help line; the field draws its error edge while it is non-nil.
    ///   - height: 24 pt in Settings rows (`textField.settingsHeight`), 28 pt elsewhere (`textField.height`).
    ///   - focus: an external focus binding, for forms that move focus; the style tracks its own otherwise.
    public init(_ variant: QuireFieldVariant = .standard, error: String? = nil,
                height: CGFloat = Quire.Layout.TextField.settingsHeight, focus: FocusState<Bool>.Binding? = nil) {
        self.variant = variant
        self.error = error
        self.height = height
        self.focus = focus
    }

    /// A placeholder in `ink3`, for the field's `prompt:`.
    public static func prompt(_ text: String) -> Text {
        Text(text).foregroundStyle(Color.qInk3)
    }

    public func body(content: Content) -> some View {
        let f = Quire.Layout.TextField.self
        let focused = focus?.wrappedValue ?? ownFocus
        let state = QuireControlState(isHovered: isHovered, isFocused: focused, isEnabled: isEnabled,
                                      isWindowKey: activeState != .inactive).forcing(forced.subtracting(.pressed))
        let a = QuireFieldAppearance.resolve(hasError: error != nil, state: state)
        let shape = RoundedRectangle(cornerRadius: f.radius, style: .circular)
        VStack(alignment: .leading, spacing: f.helpGap) {
            content
                .textFieldStyle(.plain)
                .quireFont(variant.role)
                .foregroundStyle(a.text.swiftUIColor)
                .tint(Color.qAccent)
                .focusEffectDisabled()
                .modifier(QuireFieldFocusBinding(external: focus, own: $ownFocus))
                .padding(.horizontal, f.padX)
                .frame(height: height)
                .background {
                    // The padding is part of the field: a click there focuses it, as in an NSTextField.
                    QuireFace(shape: shape, fill: a.face, edge: a.edge)
                        .contentShape(shape)
                        .onTapGesture { focusField() }
                }
                .overlay {
                    if let gap = a.ringGap {
                        QuireFocusRingView(shape: .roundedRectangle(cornerRadius: f.radius), gap: gap).allowsHitTesting(false)
                    }
                }
                .onHover { isHovered = $0 }
            if let error {
                QuireFieldHelp(text: error)
            }
        }
    }

    private func focusField() {
        if let focus { focus.wrappedValue = true } else { ownFocus = true }
    }
}

/// Binds the field to the caller's focus state when there is one, else to the style's own.
struct QuireFieldFocusBinding: ViewModifier {
    let external: FocusState<Bool>.Binding?
    let own: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        content.focused(external ?? own)
    }
}

/// The error help line under a field.
struct QuireFieldHelp: View {
    let text: String

    var body: some View {
        // The glyph sits on the first line, whatever the text wraps to.
        HStack(alignment: .top, spacing: Quire.Space.s2) {
            QuireSymbolImage(name: Quire.Icon.error, size: .custom(Quire.Layout.Settings.statusGlyph))
                .frame(height: QuireFont.Role.meta.lineHeight)
            Text(text)
                .quireParagraph(.meta)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Color.qDanger)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// Wraps this text field in the Quire field container (see `QuireFieldStyle`).
    public func quireFieldStyle(_ variant: QuireFieldVariant = .standard, error: String? = nil,
                                height: CGFloat = Quire.Layout.TextField.settingsHeight,
                                focus: FocusState<Bool>.Binding? = nil) -> some View {
        modifier(QuireFieldStyle(variant, error: error, height: height, focus: focus))
    }
}
