import AppKit
import SSCore
import SSDesign

/// The composer's bottom bar (spec §5.20): 52 pt of `paper` under a top hairline, padding 16, everything on one centre
/// line: Send, a regular split button (§5.23: `paperplane`, “Send” and its “⌘↩” keycap on the face, the drop-down's
/// chevron behind the divider); 12 pt on, Attach (`paperclip`) and Format (`textformat`, `accentWash` while the format row
/// shows) as 28 pt icon buttons 2 pt apart; trailing at 16, the status. Help me write has no control here: it works in
/// the body (⌘J, §5.56).
@MainActor
final class ComposeBottomBar: NSView {
    let send = QuireSplitButton(title: "Send", symbolName: Quire.Icon.send, size: .regular, keycap: SendKey.commandReturn.legend,
                                menuAccessibilityLabel: "Send Options")
    /// Send's action segment: what a click, ⌘↩ and Message › Send do (§5.23).
    var sendButton: QuireSplitSegment { send.actionSegment }
    /// Send's drop-down, its menu segment: the menu that chooses what Send and ⌘↩ do (§5.23). A click never sends.
    var sendOptionsButton: QuireSplitSegment { send.menuSegment }
    let attachButton = QuireIconButton(symbolName: Quire.Icon.attach, size: .large, accessibilityLabel: "Attach Files")
    let formatButton = QuireIconButton(symbolName: Quire.Icon.format, size: .large, accessibilityLabel: "Show Format Row")
    let statusView = ComposeStatusView()
    /// Unused since Help me write moved into the body (§5.56): never added or laid out, kept only so code that still
    /// names it compiles until it goes.
    let writeControl = WriteToolControl()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        sendButton.loadingTitle = "Sending…"
        // VoiceOver hears the key the face shows, as it hears a menu item's (the name says what Send does, §5.23).
        sendButton.setAccessibilityHelp(SendKey.commandReturn.spoken)
        sendOptionsButton.toolTip = "Send Options"
        attachButton.toolTip = "Attach Files…  ⇧⌘A"
        formatButton.onStyle = .quiet
        formatButton.toolTip = "Show Format Row  ⇧⌘T"
        [send, attachButton, formatButton, statusView].forEach(addSubview)
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
        // Every control is centred on the bar's middle: the 28 pt split button and the 28 pt icon buttons share it.
        func centred(_ size: NSSize, x: CGFloat) -> NSRect {
            NSRect(x: x, y: (midY - size.height / 2).rounded(), width: size.width, height: size.height)
        }
        let sendFace = centred(send.intrinsicContentSize, x: c.barPadX)
        send.frame = send.frame(forVisualRect: sendFace)
        var x = sendFace.maxX + c.barGroupGap
        for button in [attachButton, formatButton] {
            let face = centred(button.intrinsicContentSize, x: x)
            button.frame = button.frame(forVisualRect: face)
            x = face.maxX + c.barIconGap
        }
        x -= c.barIconGap
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
