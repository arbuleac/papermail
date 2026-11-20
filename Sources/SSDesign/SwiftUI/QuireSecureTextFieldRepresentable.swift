import AppKit
import SwiftUI

/// The AppKit secure field inside `QuireSecureField`. SwiftUI's `SecureField` ignores `kerning` and
/// `tracking`, so its bullets cannot take Quire's 2 pt spacing; this is the same borderless secure field the
/// AppKit `QuireTextField` uses, with text and focus bridged to SwiftUI.
struct QuireSecureTextFieldRepresentable: NSViewRepresentable {
    @Binding var text: String
    let prompt: String?
    let role: QuireFont.Role
    /// Set while the field edits, so the SwiftUI container draws the focus ring.
    @Binding var isFocused: Bool
    /// Return, or the field losing focus: the owner saves what was typed (Settings › AI's API key, §5.40).
    var onCommit: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> QuireSecureInnerTextField {
        let field = QuireSecureInnerTextField(frame: .zero)
        field.delegate = context.coordinator
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.onFocusChange = { [weak coordinator = context.coordinator] focused in coordinator?.focusDidChange(focused) }
        return field
    }

    func updateNSView(_ field: QuireSecureInnerTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        let enabled = context.environment.isEnabled
        field.isEnabled = enabled
        let font = QuireFont.font(role)
        field.font = font
        field.textColor = enabled ? .qInk : .qInkDisabled
        if let prompt {
            field.placeholderAttributedString = NSAttributedString(string: prompt, attributes: [
                .font: font,
                .foregroundColor: enabled ? NSColor.qInk3 : NSColor.qInkDisabled,
            ])
        } else {
            field.placeholderAttributedString = nil
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: QuireSecureInnerTextField, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 120, height: nsView.intrinsicContentSize.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: QuireSecureTextFieldRepresentable

        init(_ parent: QuireSecureTextFieldRepresentable) {
            self.parent = parent
        }

        func controlTextDidChange(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func focusDidChange(_ focused: Bool) {
            if parent.isFocused != focused { parent.isFocused = focused }
        }

        func controlTextDidEndEditing(_ note: Notification) {
            parent.onCommit?()
        }
    }
}
