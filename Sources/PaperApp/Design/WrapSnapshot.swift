#if DEBUG
import AppKit
import PaperDesign

/// `--snapshot-state=wrap-text` or `wrap-word` (debug builds): a long paragraph typed with no Return, or one long unbroken
/// word (an address), into the quick reply of the window `--snapshot` or `--snapshot-reader-window` renders, and into the
/// body of the composer `--snapshot-compose` renders, so a render shows how the field wraps and grows as it is typed.
/// With `wrap-narrow` the window is at its narrowest first, with `wrap-wide` as wide as the screen; `wrap-shrink` types at
/// the screen's width and then takes the window to its narrowest, so the render shows the text wrapping again.
/// `wrap-new` renders a new message instead of a reply. The composer keeps its drafts in a temporary folder for the run.
@MainActor
enum WrapSnapshot {
    static let paragraph = "Tuesday at ten works for me, and I will bring the draft budget along with the notes from the "
        + "last review so we can go through the open questions on the venue, the catering and the travel together before "
        + "anyone books anything. If the room is taken we could meet in the small office on the second floor instead, "
        + "which has a screen, or move the whole thing to Wednesday afternoon when the rest of the team is back."

    static let word = "https://example.com/shared/folders/quarterly-planning/2026/budget-review-final-version-with-every-"
        + "comment-from-the-team-and-the-venue-shortlist-attached-for-tuesday.pdf"

    private static let states: Set<String> = {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot-state=") }) else { return [] }
        return Set(argument.dropFirst("--snapshot-state=".count).split(separator: ",").map(String.init))
    }()

    /// What is typed, or nil when no wrap state is asked for.
    static var text: String? {
        if states.contains("wrap-word") { return word }
        if states.contains("wrap-text") { return paragraph }
        return nil
    }

    static var opensNewMessage: Bool { states.contains("wrap-new") }

    /// Sizes `window` for the run, types `text` into `field` as keystrokes would put it there, and sizes the window again
    /// for `wrap-shrink`.
    static func type(into field: NSTextView, in window: NSWindow?) {
        guard let text, let window else { return }
        if states.contains("wrap-narrow") { narrowest(window) }
        if states.contains("wrap-wide") || states.contains("wrap-shrink") { widest(window) }
        window.layoutIfNeeded()
        window.makeFirstResponder(field)
        for character in text {
            field.insertText(String(character), replacementRange: field.selectedRange())
        }
        if states.contains("wrap-shrink") { narrowest(window) }
        window.layoutIfNeeded()
    }

    /// `--snapshot-compose` with a wrap state: opens a reply to the selected conversation (a new message for `wrap-new`),
    /// types the sample into its body and renders the window to `path` once it has laid out; false, doing nothing, when no
    /// wrap state is asked for. Its drafts go to a temporary folder for the run, so the demo's Drafts never hold the sample.
    static func writeComposeSnapshot(from main: MainWindowController?, to path: String) -> Bool {
        guard text != nil, let main else { return false }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperWrapSnapshot-\(ProcessInfo.processInfo.processIdentifier)")
        ComposeDraftStore.shared.useDirectory(folder)
        if opensNewMessage { main.composeNew() } else { _ = main.openReplyComposer() }
        guard let composer = ComposeWindowRegistry.shared.openControllers.first else { return true }
        type(into: composer.bodyEditor, in: composer.window)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                guard let view = composer.window?.contentView?.superview ?? composer.window?.contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                SnapshotRenderer.writePNG(bitmap, to: path)
            }
        }
        return true
    }

    private static func narrowest(_ window: NSWindow) {
        let size = window.frameRect(forContentRect: NSRect(origin: .zero, size: window.contentMinSize)).size
        let minimum = NSSize(width: max(size.width, window.minSize.width), height: max(size.height, window.minSize.height))
        window.setFrame(NSRect(origin: window.frame.origin, size: NSSize(width: minimum.width, height: window.frame.height)), display: true)
    }

    private static func widest(_ window: NSWindow) {
        guard let screen = window.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        window.setFrame(NSRect(x: visible.minX, y: window.frame.minY, width: visible.width, height: window.frame.height), display: true)
    }
}
#endif
