import AppKit

/// The composer's content view. Files dropped anywhere on the window become attachments; the editor only
/// accepts text drags, so file drags fall through to this view wherever they land.
@MainActor
final class ComposeDropView: NSView {
    var onDropFiles: (([URL]) -> Void)?

    private let highlight = DropHighlightView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
        highlight.isHidden = true
        highlight.autoresizingMask = [.width, .height]
        addSubview(highlight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ComposeDropView is built in code")
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // The outline must sit above everything added later, or the scroll view covers it.
        guard subview !== highlight, highlight.superview === self else { return }
        highlight.removeFromSuperview()
        addSubview(highlight)
    }

    override func layout() {
        super.layout()
        highlight.frame = bounds
    }

    // MARK: Dragging destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(in: sender).isEmpty else { return [] }
        highlight.isHidden = false
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlight.isHidden ? [] : .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        highlight.isHidden = true
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        highlight.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        highlight.isHidden = true
        let urls = fileURLs(in: sender)
        guard !urls.isEmpty else { return false }
        onDropFiles?(urls)
        return true
    }

    private func fileURLs(in info: NSDraggingInfo) -> [URL] {
        let objects = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        return objects.compactMap { $0 as? URL }
    }
}

/// Accent outline shown while a file drag hovers over the composer. Transparent to clicks and drags.
@MainActor
private final class DropHighlightView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 3, dy: 3), xRadius: 8, yRadius: 8)
        path.lineWidth = 2
        path.stroke()
    }
}
