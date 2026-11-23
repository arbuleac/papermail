import AppKit
import PaperDesign

/// The geometry and the words of a rail row (spec §5.2): what a tile becomes while the rail shows its names. The row is
/// the rail's width less the side inset; its glyph, face or spinner keeps a tile-sized box at the leading end, the name
/// follows it, and a count, an attention mark or a first-sync spinner sits at the trailing end, centred on the row.
/// Shared by the tiles (`AccountStripButton`) and the utilities (`RailUtilityButton`), so every name starts on one line.
@MainActor
enum RailRow {
    /// A row `height` tall with its top at `top`, in a control `width` wide: the width less the side inset.
    static func rect(width: CGFloat, top: CGFloat, height: CGFloat) -> NSRect {
        let inset = Quire.Layout.Rail.rowInset
        return NSRect(x: inset, y: top, width: max(Quire.Layout.Rail.tile, width - 2 * inset), height: height)
    }

    /// The tile-wide box at the row's leading end, the row's height: where the glyph, the face or the pending ring is
    /// centred, as it was in its tile.
    static func glyphBox(in row: NSRect, rightToLeft: Bool) -> NSRect {
        let side = Quire.Layout.Rail.tile
        return NSRect(x: rightToLeft ? row.maxX - side : row.minX, y: row.minY, width: side, height: row.height)
    }

    /// Where a mark `size` large sits at the row's trailing end, centred on the row.
    static func accessoryRect(_ size: NSSize, in row: NSRect, rightToLeft: Bool) -> NSRect {
        let inset = Quire.Layout.Rail.rowTrailing
        return NSRect(x: rightToLeft ? row.minX + inset : row.maxX - inset - size.width, y: (row.midY - size.height / 2).rounded(),
                      width: size.width, height: size.height)
    }

    /// The name's line box: from the glyph box to the trailing inset, or to `accessory` (a count, a mark) less a gap.
    static func nameRect(in row: NSRect, accessory: NSRect?, rightToLeft: Bool) -> NSRect {
        let r = Quire.Layout.Rail.self
        let box = glyphBox(in: row, rightToLeft: rightToLeft)
        let lineHeight = QuireFont.Role.body.lineHeight
        let y = (row.midY - lineHeight / 2).rounded()
        if rightToLeft {
            let end = accessory.map { $0.maxX + r.nameCountGap } ?? row.minX + r.rowTrailing
            return NSRect(x: end, y: y, width: max(0, box.minX - r.nameGap - end), height: lineHeight)
        }
        let start = box.maxX + r.nameGap
        let end = accessory.map { $0.minX - r.nameCountGap } ?? row.maxX - r.rowTrailing
        return NSRect(x: start, y: y, width: max(0, end - start), height: lineHeight)
    }

    /// The name as it is drawn: `body`, a step heavier on the selected row, on one line that truncates at its tail.
    static func name(_ text: String, selected: Bool, color: NSColor) -> NSAttributedString {
        QuireFont.attributedString(text, role: selected ? .bodyMedium : .body, color: color)
    }

    static func draw(_ name: NSAttributedString, in rect: NSRect) {
        guard rect.width > 0 else { return }
        name.draw(with: rect, options: QuireFont.drawingOptions, context: nil)
    }
}
