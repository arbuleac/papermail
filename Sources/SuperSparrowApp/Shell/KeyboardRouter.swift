import AppKit
import SSCore
import SSDesign

/// The single-key shortcuts of the main window.
enum KeyCommand: Equatable {
    case next
    case previous
    /// ⇧J / ⇧K (and ⇧↓ / ⇧↑): grow or shrink the selection (spec §6, §5.19).
    case extendNext
    case extendPrevious
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
    /// L: the Later menu for the selection (spec §5.45).
    case later
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
    /// The view whose bottom centre the g-sequence HUD sits at: the list pane, where the toast sits (§5.32).
    var sequenceHUDHost: NSView? { get }
    /// The HUD is about to show. It replaces a visible toast, which does not come back.
    func sequenceHUDWillAppear()
    /// Later's tile is in the rail, so G L goes there and the HUD lists it (§5.2, §5.32).
    var showsLater: Bool { get }
}

extension KeyboardRouterTarget {
    var sequenceHUDHost: NSView? { keyboardWindow?.contentView }
    func sequenceHUDWillAppear() {}
    var showsLater: Bool { false }
}

/// A local key monitor for the main window. It only acts when the main window is key and the first responder
/// is not a place to type, so `e` in the search field or the quick reply stays an `e`.
///
/// Every key press first finishes running animations (`Quire.Motion.finishAll()`, spec §4.10), so held keys
/// never queue motion. G arms a sequence for 2000 ms (§5.32): I, S, T, D, # or A completes it, and L while Later shows;
/// any other key (Esc included) disarms it and is consumed, and the HUD shows from 500 ms until the sequence ends. ? opens
/// the keyboard cheat sheet; while it is open every key goes to it.
///
/// ⌘-shortcuts are left to the main menu (which disables mail actions while typing), except ⌘⌫ and ⌘Z, which
/// mean "delete to line start" and text undo inside text and must not be claimed by menu items there.
@MainActor
final class KeyboardRouter {
    /// `motion.duration.gSequenceWindow`: long enough that the HUD, which appears at 500 ms, stays readable.
    static let sequenceTimeout: TimeInterval = Quire.Motion.gSequenceWindow
    /// `motion.duration.gHudDelay`: typing “G I” quickly never shows the HUD.
    static let hudDelay: TimeInterval = Quire.Motion.gHudDelay

    private weak var target: KeyboardRouterTarget?
    private var monitor: Any?
    private var sequenceArmed = false
    private var hudTimer: Timer?
    private var sequenceTimer: Timer?
    private var hud: QuireSequenceHUDView?

    init(target: KeyboardRouterTarget) {
        self.target = target
    }

    /// The installed router, for the debug snapshots (`--snapshot-hud`), which have no other way to reach it.
    private(set) static weak var active: KeyboardRouter?

    func install() {
        guard monitor == nil else { return }
        Self.active = self
        // Local monitors run on the main thread, inside the event dispatch, so the closure stays main-actor.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handle(event) else { return event }
            return nil
        }
    }

    func uninstall() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        disarmSequence(animated: false)
    }

    // MARK: Routing

    private func handle(_ event: NSEvent) -> Bool {
        Quire.Motion.finishAll()
        guard let target, let window = target.keyboardWindow, event.window === window else { return false }
        let cheatSheet = CheatSheetController.shared
        if cheatSheet.isPresented(in: window) { return cheatSheet.route(event) }
        guard window.isKeyWindow else { return false }
        guard !Self.isTextInput(window.firstResponder) else {
            disarmSequence()
            return false
        }
        let characters = event.charactersIgnoringModifiers ?? ""
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])

        if sequenceArmed {
            disarmSequence()
            // A menu shortcut still works; it just ends the sequence.
            guard modifiers.intersection([.command, .control, .option]).isEmpty else { return false }
            if let view = Self.sequenceView(characters: characters) {
                _ = target.perform(.goTo(view))
            }
            // Any other key, Esc included, disarms the sequence and does nothing else.
            return true
        }

        if Self.opensCheatSheet(characters: characters, modifiers: modifiers) {
            cheatSheet.present(in: window)
            return true
        }

        let outcome = Self.command(
            characters: characters,
            keyCode: event.keyCode,
            modifiers: modifiers,
            pendingG: false,
            readerFocused: target.isReaderFocused
        )
        if outcome.startsSequence {
            armSequence()
            return true
        }
        // Keys the table does not know may still be a menu's single-key shortcut (N, P and . belong to the
        // reader's Next Message, Previous Message and Show Quoted Text). The menu bar refuses plain keys, so
        // they are performed from here, outside text fields; a disabled item lets the key go on.
        guard let command = outcome.command else { return MainMenuBar.performSingleKey(event) }
        return target.perform(command)
    }

    /// The second key of a G sequence and the view it opens.
    static func sequenceView(characters: String) -> MailboxView? {
        switch characters.lowercased() {
        case "i": return .inbox
        case "l": return .later
        case "s": return .starred
        case "t": return .sent
        case "d": return .drafts
        case "#": return .trash
        case "a": return .all
        default: return nil
        }
    }

    /// ? (Shift-/ on most layouts) opens the cheat sheet; ⌘/ is Help › Keyboard Shortcuts.
    static func opensCheatSheet(characters: String, modifiers: NSEvent.ModifierFlags) -> Bool {
        characters == "?" && modifiers.subtracting(.shift).isEmpty
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

        if pendingG {
            return (sequenceView(characters: characters).map { .goTo($0) }, false)
        }

        switch keyCode {
        case 53: return (modifiers.isEmpty ? .clearSearch : nil, false) // Esc
        case 125: return (readerFocused ? nil : modifiers.contains(.shift) ? .extendNext : .next, false) // ↓
        case 126: return (readerFocused ? nil : modifiers.contains(.shift) ? .extendPrevious : .previous, false) // ↑
        case 36, 76: return (modifiers.isEmpty ? .open : nil, false) // Return, keypad Enter
        // → opens like ↩ from the list (§6); in the reader it is the web view's (horizontal scroll).
        case 124: return (!readerFocused && modifiers.isEmpty ? .open : nil, false)
        // ← goes back to the list from the reader along Esc's path, so a visible toast still goes first (§6.1).
        case 123: return (readerFocused && modifiers.isEmpty ? .clearSearch : nil, false)
        default: break
        }

        if characters == "#" { return (.trash, false) }
        if modifiers == .shift {
            switch key {
            case "i": return (.moveToInbox, false)
            case "j": return (.extendNext, false)
            case "k": return (.extendPrevious, false)
            default: break
            }
        }
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
        case "l": return (.later, false)
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

    // MARK: G sequence

    private func armSequence() {
        disarmSequence(animated: false)
        sequenceArmed = true
        hudTimer = Self.timer(after: Self.hudDelay) { [weak self] in self?.showHUD() }
        // The window ends silently: the HUD leaves with the sequence and nothing else happens.
        sequenceTimer = Self.timer(after: Self.sequenceTimeout) { [weak self] in self?.disarmSequence() }
    }

    /// Ends the sequence and fades the HUD out with it: the HUD never outlives the sequence.
    func disarmSequence(animated: Bool = true) {
        sequenceArmed = false
        hudTimer?.invalidate()
        hudTimer = nil
        sequenceTimer?.invalidate()
        sequenceTimer = nil
        guard let hud else { return }
        self.hud = nil
        if animated {
            hud.hide { hud.removeFromSuperview() }
        } else {
            hud.removeFromSuperview()
        }
    }

    /// `force` skips the key-window check for `--snapshot-hud`: a window launched from a terminal is never key.
    private func showHUD(force: Bool = false) {
        hudTimer = nil
        guard sequenceArmed, hud == nil, let target, let host = target.sequenceHUDHost, force || host.window?.isKeyWindow == true else { return }
        target.sequenceHUDWillAppear()
        // Later's row only while its tile is there: otherwise G L does nothing, like any key the HUD does not list.
        let rows = QuireSequenceHUDView.sequenceRows().filter { target.showsLater || $0.keys != "L" }
        let view = QuireSequenceHUDView(rows: rows)
        place(view, in: host)
        host.addSubview(view, positioned: .above, relativeTo: nil)
        hud = view
        view.show()
    }

    /// Bottom centre of the host, where the toast sits: 16 pt above the sync line.
    private func place(_ view: QuireSequenceHUDView, in host: NSView) {
        let size = view.intrinsicContentSize
        let inset = Quire.Layout.SyncLine.height + Quire.Layout.Toast.aboveSyncLine
        let y = host.isFlipped ? host.bounds.height - inset - size.height : inset
        view.frame = NSRect(x: (host.bounds.midX - size.width / 2).rounded(), y: y.rounded(), width: size.width, height: size.height)
        view.autoresizingMask = host.isFlipped ? [.minXMargin, .maxXMargin, .minYMargin] : [.minXMargin, .maxXMargin, .maxYMargin]
    }

    /// Debug aid for `--snapshot-hud`: arms the sequence and shows the HUD at once.
    func showSequenceHUDNow() {
        armSequence()
        hudTimer?.invalidate()
        hudTimer = nil
        sequenceTimer?.invalidate()
        sequenceTimer = nil
        showHUD(force: true)
        hud?.layer?.opacity = 1
    }

    private static func timer(after interval: TimeInterval, _ block: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: false) { _ in
            MainActor.assumeIsolated { block() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
