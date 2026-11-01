import AppKit

/// Draws the Sparrow-style selection: a soft tint across the whole row with a thin accent bar on the leading
/// edge, instead of AppKit's solid accent fill that would force the cell's text to switch to white.
final class ConversationRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("ConversationRow")

    private static let accentBarWidth: CGFloat = 3
    private static let separatorInset: CGFloat = ConversationCellView.Metrics.textX

    override var isFlipped: Bool { true }

    /// The tint stays light, so the labels keep their normal colors whether or not the row is selected.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = ConversationRowView.identifier
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let tint = isEmphasized
            ? NSColor.controlAccentColor.withAlphaComponent(0.14)
            : NSColor.secondaryLabelColor.withAlphaComponent(0.10)
        tint.setFill()
        bounds.fill()
        if isEmphasized {
            NSColor.controlAccentColor.setFill()
            NSRect(x: 0, y: 0, width: ConversationRowView.accentBarWidth, height: bounds.height).fill()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // A hairline inset to the text column reads as a list of messages rather than a grid.
        let height = 1 / max(1, window?.backingScaleFactor ?? 1)
        NSColor.separatorColor.setFill()
        NSRect(
            x: ConversationRowView.separatorInset,
            y: bounds.maxY - height,
            width: max(0, bounds.width - ConversationRowView.separatorInset),
            height: height
        ).fill()
    }
}
