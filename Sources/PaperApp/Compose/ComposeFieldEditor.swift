import AppKit

/// The composer's field editor, for To, Cc, Bcc and Subject while one is edited (spec §5.20): AppKit's own, except that
/// files and attachments dragged from a message (§5.17) are the window's to attach. AppKit hands a drag to the deepest
/// view registered for something it carries and never passes it up, and a field editor registers for files and file
/// promises, so without this a drop on the row being edited showed nothing and did nothing. Text still drops as text.
@MainActor
final class ComposeFieldEditor: NSTextView {
    /// A field editor built as AppKit builds its own.
    static func make() -> ComposeFieldEditor {
        let editor = ComposeFieldEditor(frame: .zero)
        editor.isFieldEditor = true
        return editor
    }

    private var dropTarget: ComposeContentView? {
        sequence(first: superview, next: { $0?.superview }).lazy.compactMap { $0 as? ComposeContentView }.first
    }

    private func attaches(_ drag: NSDraggingInfo) -> Bool {
        AttachmentPasteboard.carriesAttachments(drag.draggingPasteboard)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if attaches(sender) { return dropTarget?.draggingEntered(sender) ?? [] }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if attaches(sender) { return dropTarget?.draggingUpdated(sender) ?? [] }
        return super.draggingUpdated(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if let sender, attaches(sender) { dropTarget?.draggingExited(sender) }
        super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        if attaches(sender) { dropTarget?.draggingEnded(sender) }
        super.draggingEnded(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if attaches(sender) { return true }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if attaches(sender) { return dropTarget?.performDragOperation(sender) ?? false }
        return super.performDragOperation(sender)
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        if let sender, attaches(sender) { return }
        super.concludeDragOperation(sender)
    }
}
