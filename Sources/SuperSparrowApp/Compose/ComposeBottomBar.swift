import AppKit
import SSCore
import SSDesign

/// The composer's bottom bar (spec §5.20): 52 pt of `paper` under a top hairline, padding 16, everything
/// centred: the primary Send (`paperplane`, regular), 2 pt after it its drop-down (a 28 pt `chevron.down` menu button,
/// §5.23), the “⌘↩” keycap 8 pt after that; 12 pt on, Attach (`paperclip`) and Format (`textformat`, `accentWash` while
/// the format row shows) as 28 pt icon buttons 2 pt apart; trailing at 16, the status.
@MainActor
final class ComposeBottomBar: NSView {
    let sendButton = QuireButton(title: "Send", variant: .primary, size: .regular, symbolName: Quire.Icon.send)
    /// Send's drop-down: the menu that chooses what Send and ⌘↩ do (§5.23). It never sends.
    let sendOptionsButton = QuireIconButton(symbolName: Quire.Icon.titleMenu, size: .large, accessibilityLabel: "Send Options")
    let sendKeycap = QuireKeycap("⌘↩")
    let attachButton = QuireIconButton(symbolName: Quire.Icon.attach, size: .large, accessibilityLabel: "Attach Files")
    let formatButton = QuireIconButton(symbolName: Quire.Icon.format, size: .large, accessibilityLabel: "Show Format Row")
    let statusView = ComposeStatusView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        sendButton.loadingTitle = "Sending…"
        // At rest Send is as wide as its own label, 80 pt as the specimen draws it; it grows once when it sends.
        sendButton.reservesLoadingWidth = false
        // A pull-down's chevron, at the popup chevron's size (§4.11), on the bar's 28 pt icon button.
        sendOptionsButton.symbolSize = .custom(Quire.Layout.Popup.chevron)
        sendOptionsButton.isMenuButton = true
        sendOptionsButton.toolTip = "Send Options"
        // The keycap names Send's key, so it follows Send's group, drop-down included; it is not a control.
        sendKeycap.setAccessibilityElement(false)
        attachButton.toolTip = "Attach Files…  ⇧⌘A"
        formatButton.onStyle = .quiet
        formatButton.toolTip = "Show Format Row  ⇧⌘T"
        [sendButton, sendOptionsButton, sendKeycap, attachButton, formatButton, statusView].forEach(addSubview)
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
        x = place(sendOptionsButton, x: x + c.barIconGap)
        let cap = sendKeycap.intrinsicContentSize
        sendKeycap.frame = NSRect(x: x + c.barKeycapGap, y: (midY - cap.height / 2).rounded(), width: cap.width, height: cap.height)
        x = sendKeycap.frame.maxX
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
