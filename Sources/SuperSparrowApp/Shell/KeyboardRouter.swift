import AppKit
import SSCore

/// The single-key shortcuts of the main window.
enum KeyCommand: Equatable {
    case next
    case previous
    case open
    case archive
    case toggleStar
    case toggleRead
    case trash
    case reply
    case replyAll
    case forward
    case compose
    case search
    /// Esc outside the search field: drop the search and go back to the mailbox.
    case clearSearch
    /// Back to the inbox, out of the trash or the archive.
    case moveToInbox
    case undo
    case goTo(MailboxView)
}

@MainActor
protocol KeyboardRouterTarget: AnyObject {
    var keyboardWindow: NSWindow? { get }
    /// True while focus is inside the rendered conversation, where arrows scroll the message instead.
    var isReaderFocused: Bool { get }
    /// Returns false when the command had nothing to act on, so the key goes on to the responder chain.
    func perform(_ command: KeyCommand) -> Bool
}

/// A local key monitor for the main window. It only acts when the main window is key and the first responder
/// is not a place to type, so `e` in the search field or the quick reply stays an `e`.
///
/// ⌘-shortcuts are left to the main menu (which disables mail actions while typing), except ⌘⌫ and ⌘Z, which
/// mean "delete to line start" and text undo inside text and must not be claimed by menu items there.
@MainActor
final class KeyboardRouter {
    static let sequenceTimeout: TimeInterval = 1.5

    private weak var target: KeyboardRouterTarget?
    private var monitor: Any?
    private var pendingGAt: TimeInterval?

    init(target: KeyboardRouterTarget) {
        self.target = target
    }

    func install() {
        guard monitor == nil else { return }
        // Local monitors run on the main thread, inside the event dispatch, so the closure stays main-actor.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    // MARK: Routing

    private func handle(_ event: NSEvent) -> Bool {
        guard let target, let window = target.keyboardWindow, window.isKeyWindow, event.window === window else { return false }
        guard !Self.isTextInput(window.firstResponder) else {
            pendingGAt = nil
            return false
        }
        let now = event.timestamp
        let pendingG = pendingGAt.map { now - $0 < Self.sequenceTimeout } ?? false
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let outcome = Self.command(
            characters: event.charactersIgnoringModifiers ?? "",
            keyCode: event.keyCode,
            modifiers: modifiers,
            pendingG: pendingG,
            readerFocused: target.isReaderFocused
        )
        pendingGAt = outcome.startsSequence ? now : nil
        if outcome.startsSequence { return true }
        guard let command = outcome.command else { return false }
        return target.perform(command)
    }

    /// The pure key table. `startsSequence` means "g was pressed; wait for the second key".
    static func command(
        characters: String,
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags,
        pendingG: Bool,
        readerFocused: Bool
    ) -> (command: KeyCommand?, startsSequence: Bool) {
        let key = characters.lowercased()
        if modifiers == .command {
            switch keyCode {
            case 51: return (.trash, false) // ⌘⌫
            default: break
            }
            if key == "z" { return (.undo, false) }
            return (nil, false)
        }
        guard modifiers.subtracting(.shift).isEmpty else { return (nil, false) }

        if pendingG, modifiers.isEmpty {
            switch key {
            case "i": return (.goTo(.inbox), false)
            case "s": return (.goTo(.starred), false)
            case "t": return (.goTo(.sent), false)
            case "a": return (.goTo(.all), false)
            case "d": return (.goTo(.drafts), false)
            default: break
            }
        }

        switch keyCode {
        case 53: return (modifiers.isEmpty ? .clearSearch : nil, false) // Esc
        case 125: return (readerFocused ? nil : .next, false) // ↓
        case 126: return (readerFocused ? nil : .previous, false) // ↑
        case 36, 76: return (modifiers.isEmpty ? .open : nil, false) // Return, keypad Enter
        default: break
        }

        if characters == "#" { return (.trash, false) }
        if modifiers == .shift, key == "i" { return (.moveToInbox, false) }
        guard modifiers.isEmpty else { return (nil, false) }
        switch key {
        case "j": return (.next, false)
        case "k": return (.previous, false)
        case "e": return (.archive, false)
        case "s": return (.toggleStar, false)
        case "u": return (.toggleRead, false)
        case "r": return (.reply, false)
        case "a": return (.replyAll, false)
        case "f": return (.forward, false)
        case "c": return (.compose, false)
        case "/": return (.search, false)
        case "z": return (.undo, false)
        case "g": return (nil, true)
        default: return (nil, false)
        }
    }

    /// Places where a key is text: any editable text view (which includes the field editor behind search,
    /// token and text fields) and editable text fields themselves.
    static func isTextInput(_ responder: NSResponder?) -> Bool {
        if let textView = responder as? NSTextView {
            return textView.isEditable || textView.isFieldEditor
        }
        if let field = responder as? NSTextField {
            return field.isEditable
        }
        return false
    }
}
