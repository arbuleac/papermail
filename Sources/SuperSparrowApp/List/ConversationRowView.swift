import AppKit
import SSDesign

/// The row under a conversation's content (spec §5.7, §3.4): its fill, the margin rule and the separator.
///
/// Selection is a wash plus the 3 pt margin rule, never a solid block, so text never inverts and the cached
/// strings stay valid. The wash and rule are emphasized (`selWash` + `selRule`) whenever the window is key,
/// whatever the first responder, because j/k drive the list from the reader too; they turn idle only when the
/// window is not key. `isEmphasized`, which AppKit ties to first-responder state, is deliberately ignored.
/// Hover is a wash over `paper`, never drawn on a selected row. No shadow, no animation.
final class ConversationRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("ConversationRow")

    /// The row's density and Text size, which place the margin rule and the separator (spec §5.7, §4.15).
    var metrics = QuireRowMetrics.standard(.default) {
        didSet { if oldValue != metrics { needsDisplay = true } }
    }

    /// Set by the table's single tracking area, never by the row itself, so live scroll can pause it.
    var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    /// The wash stays light, so labels keep their normal colours whether or not the row is selected.
    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = ConversationRowView.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    // AppKit redraws rows when these flip; the separator above a selected row depends on the next row.
    override var isNextRowSelected: Bool {
        didSet { if oldValue != isNextRowSelected { needsDisplay = true } }
    }

    override var isSelected: Bool {
        didSet { if oldValue != isSelected { needsDisplay = true } }
    }

    /// Forces the key state drawn (state renders and tests, where no window is key); nil follows the window.
    var windowKeyOverride: Bool? {
        didSet { needsDisplay = true }
    }

    private var isWindowKey: Bool { windowKeyOverride ?? window?.isKeyWindow ?? false }

    override func draw(_ dirtyRect: NSRect) {
        if isSelected {
            (isWindowKey ? NSColor.qSelWash : NSColor.qSelWashIdle).setFill()
            bounds.fill()
            QuireMarginRule.draw(in: NSRect(x: 0, y: metrics.marginRuleY, width: Quire.Border.MarginRule.width, height: metrics.marginRuleHeight),
                                 isWindowKey: isWindowKey)
        } else {
            NSColor.qPaper.setFill()
            bounds.fill()
            if isHovered {
                NSColor.qHover.setFill()
                bounds.fill(using: .sourceOver)
            }
        }
        // The separator is hidden on the selected row and on the row above it, so the wash reads as one block.
        guard !isSelected, !isNextRowSelected else { return }
        let x = metrics.separatorX
        let width = QuireHairline.width(for: self)
        NSColor.qRule.setFill()
        NSRect(x: x, y: bounds.maxY - width, width: max(0, bounds.width - x), height: width).fill()
    }

    // The default implementations would paint AppKit's own selection and separators under ours.
    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}
}
