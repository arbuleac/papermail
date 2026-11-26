import AppKit
import PaperCore
import PaperDesign

/// The row under a conversation's content (spec §5.7, §3.4): its fill, the margin rule and the separator.
///
/// Selection is a wash plus the 3 pt margin rule, never a solid block, so text never inverts and the cached
/// strings stay valid. The wash and rule are emphasized (`selWash` + `selRule`) whenever the window is key,
/// whatever the first responder, because j/k drive the list from the reader too; they turn idle only when the
/// window is not key. `isEmphasized`, which AppKit ties to first-responder state, is deliberately ignored.
/// Hover is a wash over `paper`, never drawn on a selected row. No shadow, no animation.
///
/// A swipe (spec §5.7) slides all of that, and the cell's content with it, by `swipeOffset`: both draw moved, and the
/// button the content uncovers (`QuireSwipeButton`) fills the rest of the row. No frame moves, so nothing the table lays
/// out can undo it, and a row at rest draws exactly as before.
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
        // As the cell: the wash and the separator are redrawn at a new width, not scaled to it.
        layerContentsRedrawPolicy = .duringViewResize
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
        resetSwipe()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if swipeOffset != 0 { layoutSwipeButton() }
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        (subview as? ConversationCellView)?.swipeOffset = swipeOffset
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
        guard swipeOffset != 0 else { return drawContent() }
        // The content where the swipe has slid it, and only there: the button fills what it uncovered.
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds.intersection(bounds.offsetBy(dx: swipeOffset, dy: 0))).addClip()
        NSGraphicsContext.current?.cgContext.translateBy(x: swipeOffset, y: 0)
        drawContent()
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawContent() {
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

    // MARK: Swipe (§5.7)

    /// The swipe moving this row, as `RowSwipeGesture` described it: which edge offers which button. Nil at rest.
    private(set) var swipeRow: RowSwipeGesture.Row?
    /// How far the content has slid: negative to the left, uncovering the trailing edge's button; positive to the right,
    /// the leading edge's.
    private(set) var swipeOffset: CGFloat = 0
    /// The button the content uncovers, sized to all of it; nil at rest.
    private(set) var swipeButton: QuireSwipeButton?
    /// A click on the button, or VoiceOver's press, with this row.
    var onSwipePress: ((ConversationRowView) -> Void)?
    private var swipeAnimation: QuireFrameAnimation?
    /// A settle is running (tests read it).
    var isSettlingSwipe: Bool { swipeAnimation != nil }

    /// Puts the content at `offset`, under the fingers: any settle still running stops where it is.
    func setSwipe(_ row: RowSwipeGesture.Row, offset: CGFloat) {
        swipeAnimation?.cancel()
        swipeAnimation = nil
        swipeRow = row
        applySwipeOffset(offset)
    }

    /// Settles the content at `offset` over `duration` along `curve`; under Reduce Motion it is there at once. Back at
    /// rest, the button goes.
    func settleSwipe(to offset: CGFloat, _ duration: TimeInterval, _ curve: Quire.Motion.Curve) {
        swipeAnimation?.cancel()
        swipeAnimation = nil
        guard swipeRow != nil || swipeOffset != 0 else { return }
        swipeAnimation = QuireFrameAnimation.run(from: swipeOffset, to: offset, duration, curve, reduced: .instant, in: self,
                                                 step: { [weak self] value in self?.applySwipeOffset(value) },
                                                 completion: { [weak self] in
            guard let self else { return }
            self.swipeAnimation = nil
            if offset == 0 { self.swipeRow = nil }
            self.swipeButton?.pointerRegionsDidChange()
        })
    }

    /// Back at rest at once, with nothing running.
    func resetSwipe() {
        swipeAnimation?.cancel()
        swipeAnimation = nil
        applySwipeOffset(0)
        swipeRow = nil
    }

    private func applySwipeOffset(_ offset: CGFloat) {
        guard offset != swipeOffset else { return }
        swipeOffset = offset
        for case let cell as ConversationCellView in subviews { cell.swipeOffset = offset }
        needsDisplay = true
        layoutSwipeButton()
    }

    /// The button over everything the content uncovered, the row's full height.
    private func layoutSwipeButton() {
        let edge: RowSwipe.Edge? = swipeOffset < 0 ? .trailing : swipeOffset > 0 ? .leading : nil
        guard let edge, let content = swipeRow?.button(edge) else {
            if let button = swipeButton {
                swipeButton = nil
                button.removeFromSuperview()
                // The table cut the button's area out of the row's pointing hand; it gives it back.
                (superview as? QuirePointerTarget)?.pointerRegionsDidChange()
            }
            return
        }
        let hadButton = swipeButton != nil
        let button: QuireSwipeButton
        if let existing = swipeButton {
            button = existing
            button.kind = content.kind
            button.title = content.title
            button.textSize = metrics.textSize
        } else {
            button = QuireSwipeButton(kind: content.kind, title: content.title, textSize: metrics.textSize)
            button.onPress = { [weak self] in
                guard let self else { return }
                self.onSwipePress?(self)
            }
            addSubview(button, positioned: .above, relativeTo: nil)
            swipeButton = button
        }
        let width = abs(swipeOffset)
        button.frame = NSRect(x: edge == .trailing ? bounds.width - width : 0, y: 0, width: width, height: bounds.height)
        button.needsDisplay = true
        if !hadButton { button.pointerRegionsDidChange() }
    }
}
