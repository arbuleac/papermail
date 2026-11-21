import AppKit
import SSDesign

/// The selection pill (§5.56): once a selection that can be rewritten has settled, a small raised capsule hangs under its
/// last line, `pencil.line`, “Rewrite” and the quiet ⌘J. It floats, as a popover does (`raised`, a `rule` hairline,
/// `e2`), and may lie over the line below for as long as the selection stays; a click rewrites the selection as ⌘J does.
@MainActor
final class WriteSelectionPill: WriteInlineControl {
    static let keycap = "\u{2318}J"

    private let surface = QuireSheetView(frame: .zero)
    private let content = PillContent(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        surface.fillColor = .qRaised
        surface.elevation = Quire.Elevation.e2
        surface.showsEdge = true
        addSubview(surface)
        surface.contentView.addSubview(content)
        content.pill = self
        toolTip = "Rewrite the Selection  \u{2318}J"
        setAccessibilityLabel("Rewrite selection with Help Me Write")
    }

    /// The capsule's size: the glyph, “Rewrite” and the keycap between its padding.
    override var intrinsicContentSize: NSSize {
        let c = Quire.Layout.WriteCaret.self
        let glyph = WriteGlyph.size(Quire.Icon.helpMeWrite, size: c.pillGlyph)
        let label = ceil(Self.label(.qInk).size().width)
        let cap = WriteQuietKeycap.size(Self.keycap).width
        return NSSize(width: ceil(c.pillPadX + glyph.width + c.pillGlyphGap + label + c.keycapGap + cap + c.pillPadX), height: c.pillHeight)
    }

    fileprivate static func label(_ color: NSColor) -> NSAttributedString {
        QuireFont.attributedString(WriteWords.rewrite, role: .label, color: color)
    }

    override func layout() {
        super.layout()
        let face = bodyRect
        surface.cornerRadius = face.height / 2
        surface.frame = face
        content.frame = surface.contentView.bounds
        content.needsDisplay = true
    }

    override func stateDidChange() {
        super.stateDidChange()
        content.needsDisplay = true
    }

    override func hoverDidChange() {
        content.needsDisplay = true
    }

    /// Clicks anywhere on the capsule are the pill's, never the surface's under it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        return hitRect.contains(convert(point, from: superview)) ? self : nil
    }

    /// The capsule's face, glyph, words and keycap, drawn over the raised surface.
    fileprivate final class PillContent: NSView {
        weak var pill: WriteSelectionPill?

        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            guard let pill else { return }
            let c = Quire.Layout.WriteCaret.self
            let face = bounds
            switch pill.interactionState {
            case .hover: QuireDraw.fill(face, radius: face.height / 2, .qHover)
            case .pressed: QuireDraw.fill(face, radius: face.height / 2, .qPressed)
            default: break
            }
            var x = face.minX + c.pillPadX
            let glyph = WriteGlyph.size(Quire.Icon.helpMeWrite, size: c.pillGlyph)
            WriteGlyph.draw(Quire.Icon.helpMeWrite, size: c.pillGlyph, color: .qInk2,
                            centredIn: NSRect(x: x, y: face.minY, width: glyph.width, height: face.height))
            x += glyph.width + c.pillGlyphGap
            let label = WriteSelectionPill.label(.qInk)
            let lineHeight = QuireFont.Role.label.lineHeight
            let width = ceil(label.size().width)
            label.draw(with: NSRect(x: x, y: ((face.height - lineHeight) / 2).rounded(), width: width + 1, height: lineHeight),
                       options: QuireFont.drawingOptions, context: nil)
            x += width + c.keycapGap
            let size = WriteQuietKeycap.size(WriteSelectionPill.keycap)
            WriteQuietKeycap.draw(WriteSelectionPill.keycap, in: NSRect(x: x, y: ((face.height - size.height) / 2).rounded(),
                                                                       width: size.width, height: size.height),
                                  ink: .qInk3, hairline: QuireHairline.width(for: self))
        }
    }
}
