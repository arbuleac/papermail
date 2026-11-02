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

    /// The uppercased label in its role, built once per title change.
    static func title(_ text: String) -> NSAttributedString {
        QuireFont.attributedString(text, role: .runningHead, color: .qInk3)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        bounds.fill()
        let compact = density == .compact
        let x = compact ? Head.compactLabelX : Head.labelX
        let top = compact ? Head.compactLabelY : Head.labelY
        let lineHeight = QuireFont.Role.runningHead.lineHeight
        let maxWidth = bounds.width - x - Quire.Layout.Row.trailing
        title.draw(with: NSRect(x: x, y: top, width: max(0, maxWidth), height: lineHeight), options: QuireFont.drawingOptions, context: nil)

        let ruleX = x + titleWidth + Head.ruleGap
        let ruleEnd = bounds.width - Quire.Layout.Row.trailing
        guard ruleEnd > ruleX else { return }
        let ruleY = compact ? Head.compactRuleY : Head.ruleY
        let width = QuireHairline.width(for: self)
        NSColor.qRule.setFill()
        NSRect(x: ruleX, y: (ruleY - width / 2), width: ruleEnd - ruleX, height: width).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {}
    override func drawSeparator(in dirtyRect: NSRect) {}
    override func drawBackground(in dirtyRect: NSRect) {}

    // MARK: Accessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { NSAccessibility.Role(rawValue: "AXHeading") }
    override func accessibilityLabel() -> String? { spokenTitle }
}
