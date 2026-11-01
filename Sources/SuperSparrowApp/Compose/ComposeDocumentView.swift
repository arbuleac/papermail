import AppKit

/// The scroll view's document: the editor followed by the quoted original. Clicking the empty space under
/// the text puts the caret at the end, so the whole page feels like one editor rather than a short box.
@MainActor
final class ComposeDocumentView: NSView {
    weak var editor: NSTextView?

    override var isFlipped: Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let editor, let window else {
            super.mouseDown(with: event)
            return
        }
        window.makeFirstResponder(editor)
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
