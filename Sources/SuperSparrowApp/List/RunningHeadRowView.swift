import AppKit
import SSDesign

/// A running head (spec §5.8): a plain group row, never sticky, never selectable. The label is `runningHead`
/// (SF Pro 11 Semibold, uppercase, 0.6 pt tracking) in `ink3`; a hairline runs from 10 pt after it to 16 pt
/// before the trailing edge, on the label's centre line.
final class RunningHeadRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("RunningHeadRow")

    private typealias Head = Quire.Layout.RunningHead

    var title = NSAttributedString() {
        didSet { if oldValue != title { needsDisplay = true; titleWidth = ceil(title.size().width) } }
    }

    /// The head's words before uppercasing, which is what VoiceOver should read.
    var spokenTitle = ""

    var density = AppSettings.ListDensity.standard {
        didSet { if oldValue != density { needsDisplay = true } }
    }

    /// The label's line follows the Text size; the head keeps its height and the label its place (spec §4.15).
    var textSize = QuireFont.TextSize.default {
        didSet { if oldValue != textSize { needsDisplay = true } }
    }

    private var titleWidth: CGFloat = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = RunningHeadRowView.identifier
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// The uppercased label in its role at `textSize`, built once per title change.
    static func title(_ text: String, textSize: QuireFont.TextSize = .default) -> NSAttributedString {
        QuireFont.attributedString(text, role: .runningHead, color: .qInk3, textSize: textSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        bounds.fill()
        let compact = density == .compact
        let x = compact ? Head.compactLabelX : Head.labelX
        let top = compact ? Head.compactLabelY : Head.labelY
        let lineHeight = QuireFont.Role.runningHead.lineHeight(at: textSize)
        let maxWidth = bounds.width - x - Quire.Layout.Row.trailing
        title.draw(with: NSRect(x: x, y: top, width: max(0, maxWidth), height: lineHeight), options: QuireFont.drawingOptions, context: nil)

        let ruleX = x + titleWidth + Head.ruleGap
        let ruleEnd = bounds.width - Quire.Layout.Row.trailing
        guard ruleEnd > ruleX else { return }
        // On the label's centre, which moves by half its line's step.
        let ruleY = (compact ? Head.compactRuleY : Head.ruleY) + QuireFont.Role.runningHead.step(at: textSize) / 2
        let width = QuireHairline.width(for: self)
        NSColor.qRule.setFill()
        // On the device grid: centred on the label's line, a hairline straddled two pixel rows at half
        // strength and read softer than every other rule (§4.7).
        let y = Self.pixelAligned(ruleY - width / 2, scale: window?.backingScaleFactor ?? 2)
        NSRect(x: ruleX, y: y, width: ruleEnd - ruleX, height: width).fill()
    }

    /// `y` moved down to the device pixel it starts in, so a one-pixel rule fills exactly one row.
    static func pixelAligned(_ y: CGFloat, scale: CGFloat) -> CGFloat {
        guard scale > 0 else { return y }
        return (y * scale + 0.001).rounded(.down) / scale
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { NSAccessibility.Role(rawValue: "AXHeading") }
    override func accessibilityLabel() -> String? { spokenTitle }
}
