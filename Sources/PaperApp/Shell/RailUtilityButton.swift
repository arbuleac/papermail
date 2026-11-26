import AppKit
import PaperDesign

/// Add Account or Settings at the rail's foot (spec §5.2). While the rail shows its tiles alone it is the 28 pt icon
/// button `QuireIconButton` draws: the symbol in `ink2` on no fill, `hover` and `pressed` washes with the symbol in
/// `ink`, `inkDisabled` while disabled, the focus ring outside a 1 pt gap. While the rail shows its names it is a row
/// (`RailRow`) of that height: the same symbol in the tile-wide box at the leading end, on the folders' line, then its
/// name, with the washes, the ring and the clicks taking the whole row.
@MainActor
final class RailUtilityButton: QuireControl {
    let symbolName: String
    /// The name beside the symbol while the rail shows its names, and what VoiceOver calls the button.
    let title: String

    /// The rail shows its names (§5.2). The rail lays the button out again for it: a square, or a row.
    var showsName = false {
        didSet {
            guard oldValue != showsName else { return }
            needsDisplay = true
            pointerRegionsDidChange()
        }
    }

    init(symbolName: String, title: String) {
        self.symbolName = symbolName
        self.title = title
        super.init(frame: .zero)
        setAccessibilityLabel(title)
        let side = Quire.Layout.Rail.utility
        setFrameSize(frame(forAlignmentRect: NSRect(x: 0, y: 0, width: side, height: side)).size)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    /// Frames are set by hand; a new size redraws the row at its new width.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    /// Where the symbol is centred: the button's square, or the tile-wide box at the row's leading end.
    var glyphRect: NSRect {
        let face = faceRect
        return showsName ? RailRow.glyphBox(in: face, rightToLeft: userInterfaceLayoutDirection == .rightToLeft) : face
    }

    override func draw(_ dirtyRect: NSRect) {
        let face = faceRect
        let radius = QuireIconButton.Size.large.cornerRadius
        let state = interactionState
        if isEnabled {
            if state == .pressed {
                QuireDraw.fill(face, radius: radius, .qPressed)
            } else if state == .hover {
                QuireDraw.fill(face, radius: radius, .qHover)
            }
        }
        let ink: NSColor = !isEnabled ? .qInkDisabled : state == .rest ? .qInk2 : .qInk
        QuireSymbol.draw(symbolName, size: .custom(Quire.Layout.Rail.utilityGlyph), color: ink, centredIn: glyphRect)
        if showsName {
            let rightToLeft = userInterfaceLayoutDirection == .rightToLeft
            RailRow.draw(RailRow.name(title, selected: false, color: ink), in: RailRow.nameRect(in: face, accessory: nil, rightToLeft: rightToLeft))
        }
        if showsFocusRing {
            QuireFocusRing.draw(around: face, cornerRadius: radius, gap: QuireFocusRing.gap)
        }
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
}
