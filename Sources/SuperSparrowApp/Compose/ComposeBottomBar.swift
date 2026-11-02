import AppKit
import SSCore
import SSDesign

/// The composer's bottom bar (spec §5.20): 52 pt of `paper` under a top hairline, padding 16, everything
/// centred: the primary Send (`paperplane`, regular) with its “⌘↩” keycap 8 pt after it; 12 pt on, Attach
/// (`paperclip`) and Format (`textformat`, `accentWash` while the format row shows) as 28 pt icon buttons 2 pt
/// apart; trailing at 16, the status.
@MainActor
final class ComposeBottomBar: NSView {
    let sendButton = QuireButton(title: "Send", variant: .primary, size: .regular, symbolName: Quire.Icon.send)
    let attachButton = QuireIconButton(symbolName: Quire.Icon.attach, size: .large, accessibilityLabel: "Attach Files")
    let formatButton = QuireIconButton(symbolName: Quire.Icon.format, size: .large, accessibilityLabel: "Show Format Row")
    let statusView = ComposeStatusView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        sendButton.keycap = "⌘↩"
        sendButton.keycapGap = Quire.Layout.Composer.barKeycapGap
        sendButton.loadingTitle = "Sending…"
        attachButton.toolTip = "Attach Files…  ⇧⌘A"
        formatButton.onStyle = .quiet
        formatButton.toolTip = "Show Format Row  ⇧⌘T"
        [sendButton, attachButton, formatButton, statusView].forEach(addSubview)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ComposeBottomBar is built in code")
    }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let c = Quire.Layout.Composer.self
        let midY = bounds.height / 2
        func place(_ control: QuireControl, x: CGFloat) -> CGFloat {
            let size = control.intrinsicContentSize
            let visual = NSRect(x: x, y: (midY - size.height / 2).rounded(), width: size.width, height: size.height)
            control.frame = control.frame(forVisualRect: visual)
            return visual.maxX
        }
        var x = place(sendButton, x: c.barPadX)
        x = place(attachButton, x: x + c.barGroupGap)
        x = place(formatButton, x: x + c.barIconGap)
        let statusWidth = min(statusView.intrinsicContentSize.width, max(0, bounds.width - c.barPadX - x - c.barGroupGap))
        let height = statusView.intrinsicContentSize.height
        statusView.frame = NSRect(x: bounds.width - c.barPadX - statusWidth, y: (midY - height / 2).rounded(), width: statusWidth,
                                  height: height)
    }

    func statusDidChange() {
        needsLayout = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        // Views no longer clip to their bounds (macOS 14), and the dirty rect can reach past them.
        dirtyRect.intersection(bounds).fill()
        QuireHairline.fill(along: NSRect(x: 0, y: 0, width: bounds.width, height: 1), orientation: .horizontal,
                           width: QuireHairline.width(for: self), color: .qRule, atMaxEdge: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override var mouseDownCanMoveWindow: Bool { false }
}
