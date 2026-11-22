import AppKit
import PaperDesign

/// Presents the keyboard cheat sheet (spec §5.32) in the main window: an in-window overlay over the whole
/// content view, under the title bar's controls (the traffic lights stay above it and usable), generated
/// from `cheatSheetContent`. It traps focus while open and gives it back to whatever had it when it closes.
@MainActor
final class CheatSheetController {
    static let shared = CheatSheetController()

    private var overlay: QuireCheatSheetOverlay?
    private weak var window: NSWindow?
    private weak var returnFocus: NSResponder?

    /// App-level shortcuts that keep working over the sheet: Quit, Hide, Hide Others, Minimize, Settings and
    /// cycling windows. ⌘/ and ⌘W close the sheet itself. Every other menu shortcut acts on what is behind
    /// it, so it is swallowed (“nothing behind it responds to keys”).
    private static let passThroughCommands: Set<String> = ["q", "h", "m", ",", "`", "/", "w"]

    /// Reader mode's row (§5.59), in View after Load images and Original colors, listed while its key works.
    static let readerModeRow = QuireCheatSheetRow(keys: "⇧⌘R", label: "Reader mode")

    /// The sheet's sections: Quire's, with `readerModeRow` while Settings › Experimental offers reader mode. Kept out of
    /// the generated content, which lists only what every user has.
    static func sections(offeringReaderMode: Bool) -> [QuireCheatSheetSection] {
        guard offeringReaderMode else { return Quire.cheatSheet }
        return Quire.cheatSheet.map { section in
            guard section.title == "View" else { return section }
            var rows = section.rows
            let place = rows.firstIndex { $0.keys == "⇧⌘I ⇧⌘O" }.map { $0 + 1 } ?? rows.count
            rows.insert(readerModeRow, at: place)
            return QuireCheatSheetSection(title: section.title, rows: rows)
        }
    }

    func isPresented(in window: NSWindow?) -> Bool {
        overlay != nil && window != nil && self.window === window
    }

    func toggle(in window: NSWindow) {
        if isPresented(in: window) { dismiss() } else { present(in: window) }
    }

    func present(in window: NSWindow, animated: Bool = true) {
        guard overlay == nil, let host = window.contentView else { return }
        KeyboardRouter.active?.disarmSequence(animated: false)
        // ⌘/ from the search field leaves its field editor as first responder; focus goes back to the field
        // itself, since making a field editor first responder directly does not restart editing.
        if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView {
            returnFocus = field
        } else {
            returnFocus = window.firstResponder
        }
        let overlay = QuireCheatSheetOverlay(frame: host.bounds, sections: Self.sections(offeringReaderMode: AppSettings.shared.offersReaderMode))
        overlay.autoresizingMask = [.width, .height]
        // VoiceOver treats the panel as a modal group titled “Keyboard Shortcuts” (the panel names itself).
        overlay.panel.setAccessibilityModal(true)
        overlay.onDismiss = { [weak self] in self?.dismiss() }
        host.addSubview(overlay, positioned: .above, relativeTo: nil)
        self.overlay = overlay
        self.window = window
        overlay.present(animated: animated)
    }

    func dismiss(animated: Bool = true) {
        guard let overlay else { return }
        self.overlay = nil
        let window = self.window
        let focus = returnFocus
        returnFocus = nil
        overlay.dismiss(animated: animated) {
            overlay.removeFromSuperview()
            guard let window else { return }
            // Focus returns to where it was, if that is still in the window.
            if let view = focus as? NSView, view.window === window {
                window.makeFirstResponder(view)
            } else {
                window.makeFirstResponder(nil)
            }
        }
    }

    /// A key in the main window while the sheet is open. Plain keys go to the overlay (it is first responder,
    /// and swallows what it does not use); menu shortcuts pass only when they are the app's own.
    func route(_ event: NSEvent) -> Bool {
        guard let overlay else { return false }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        if modifiers.contains(.command) {
            let key = (event.charactersIgnoringModifiers ?? "").lowercased()
            return !Self.passThroughCommands.contains(key)
        }
        // ⌥ and ⌃ chords are swallowed as well, so no menu shortcut, today's or a later one, acts behind the
        // sheet. Plain keys inside the panel take the normal path, so the close button still answers Space.
        if let responder = overlay.window?.firstResponder as? NSView, responder === overlay || responder.isDescendant(of: overlay),
           modifiers.isEmpty {
            return false
        }
        overlay.keyDown(with: event)
        return true
    }
}
