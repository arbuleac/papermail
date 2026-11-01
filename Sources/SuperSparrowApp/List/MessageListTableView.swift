import AppKit

/// Return and keypad Enter open the selected conversation. Every other key falls through the responder chain
/// so the window controller can map j/k and friends; type-select is off so letters are not swallowed here.
final class MessageListTableView: NSTableView {
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76

    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isOpenKey = event.keyCode == MessageListTableView.returnKeyCode
            || event.keyCode == MessageListTableView.keypadEnterKeyCode
        if isOpenKey, modifiers.isEmpty, let onReturn {
            onReturn()
            return
        }
        super.keyDown(with: event)
    }
}
