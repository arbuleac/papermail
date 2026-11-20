import SwiftUI

/// A Quire secure field (spec §5.25 Secure, §5.40 Client secret): bullets 2 pt apart
/// (`textField.secureTracking`) in the Quire field container, and a reveal button (`eye`, a small icon button)
/// that shows only while the pointer is over the field. Revealed, the text shows in a `TextField` and the
/// button (`eye.slash`) stays until it hides the text again. The bullets come from the AppKit secure field
/// Quire uses (SwiftUI's `SecureField` cannot space them).
///
///     QuireSecureField("Client secret", text: $secret, prompt: "Optional")
///
/// `.quireForcedStates(.hovered)` shows the button for a gallery.
public struct QuireSecureField: View {
    let title: String
    @Binding var text: String
    let prompt: String?
    let variant: QuireFieldVariant
    let error: String?
    let height: CGFloat
    let onCommit: (() -> Void)?

    @State private var isRevealed = false
    @State private var isHovered = false
    @State private var isEditingSecret = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.quireForcedStates) private var forced

    /// - Parameters:
    ///   - prompt: the placeholder, drawn as `QuireFieldStyle.prompt(_:)` draws it.
    ///   - variant: `mono` by default: OAuth secrets set in SF Mono (§5.25).
    ///   - error: the help line, as in `QuireFieldStyle`.
    ///   - height: 24 pt in Settings rows (`textField.settingsHeight`), 28 pt elsewhere.
    ///   - onCommit: Return, or the field losing focus, for a field that saves as editing ends (an API key, §5.40).
    public init(_ title: String, text: Binding<String>, prompt: String? = nil, variant: QuireFieldVariant = .mono,
                error: String? = nil, height: CGFloat = Quire.Layout.TextField.settingsHeight, onCommit: (() -> Void)? = nil) {
        self.title = title
        _text = text
        self.prompt = prompt
        self.variant = variant
        self.error = error
        self.height = height
        self.onCommit = onCommit
    }

    /// The reveal button sits as far from the trailing edge as from the field's top and bottom.
    private var buttonInset: CGFloat { max(1, ((height - QuireButtonSize.small.iconSide) / 2).rounded(.down)) }

    /// The text stops 4 pt before the button, which keeps its room even while hidden so the text never moves.
    private var reservedTrailing: CGFloat {
        buttonInset + QuireButtonSize.small.iconSide + Quire.Space.s2 - Quire.Layout.TextField.padX
    }

    public var body: some View {
        let showsButton = isEnabled && (isHovered || forced.contains(.hovered) || isRevealed)
        field
            .padding(.trailing, max(0, reservedTrailing))
            .modifier(styled)
            .overlay(alignment: .topTrailing) {
                if showsButton {
                    Button { isRevealed.toggle() } label: {
                        QuireButtonLabel(glyph: isRevealed ? Quire.Icon.conceal : Quire.Icon.reveal,
                                         accessibilityLabel: isRevealed ? "Hide secret" : "Show secret")
                    }
                    .buttonStyle(.quire(.icon, size: .small))
                    .help(isRevealed ? "Hide Secret" : "Show Secret")
                    .frame(height: height)
                    .padding(.trailing, buttonInset)
                }
            }
            .onHover { isHovered = $0 }
    }

    /// The container; while the secret is hidden its focus comes from the AppKit field.
    private var styled: QuireFieldStyle {
        var style = QuireFieldStyle(variant, error: error, height: height)
        if !isRevealed { style.bridgedFocus = isEditingSecret }
        return style
    }

    @ViewBuilder
    private var field: some View {
        if isRevealed {
            TextField(title, text: $text, prompt: prompt.map { QuireFieldStyle.prompt($0) })
                .onSubmit { onCommit?() }
        } else {
            QuireSecureTextFieldRepresentable(text: $text, prompt: prompt, role: variant.role, isFocused: $isEditingSecret,
                                              onCommit: onCommit)
                .accessibilityLabel(title)
        }
    }
}
