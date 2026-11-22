import PaperCore
import PaperDesign
import SwiftUI

/// Settings › Accounts › Signature (spec §5.40): `SignatureEditorView` in the Quire field container, 360 pt wide (the
/// field column) and three writing lines tall, scrolling past them. It shows the selected account's signature and
/// hands back the HTML to keep once editing ends.
struct SignatureField: View {
    let account: Account
    let onCommit: (String?, AccountID) -> Void

    @State private var isEditing = false

    var body: some View {
        let s = Quire.Layout.Settings.self
        SignatureEditorRepresentable(account: account, onCommit: onCommit, isEditing: $isEditing)
            .quireTextAreaStyle(height: s.signatureFieldHeight, isFocused: isEditing)
            .frame(width: s.fieldWidth)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Signature")
    }
}

private struct SignatureEditorRepresentable: NSViewRepresentable {
    let account: Account
    let onCommit: (String?, AccountID) -> Void
    @Binding var isEditing: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SignatureEditorView {
        let editor = SignatureEditorView(frame: .zero)
        editor.onCommit = { html, id in context.coordinator.onCommit?(html, id) }
        editor.onFocusChange = { focused in context.coordinator.onFocusChange?(focused) }
        return editor
    }

    func updateNSView(_ editor: SignatureEditorView, context: Context) {
        context.coordinator.onCommit = onCommit
        let binding = $isEditing
        context.coordinator.onFocusChange = { focused in
            if binding.wrappedValue != focused { binding.wrappedValue = focused }
        }
        editor.load(account.signature, for: account.id)
    }

    static func dismantleNSView(_ editor: SignatureEditorView, coordinator: Coordinator) {
        editor.commitIfNeeded()
    }

    /// The closures of the latest update, so the editor always reports to the form as it is now.
    @MainActor
    final class Coordinator {
        var onCommit: ((String?, AccountID) -> Void)?
        var onFocusChange: ((Bool) -> Void)?
    }
}
