import AppKit
import PaperDesign

/// Quire's drop treatment (spec §5.20 Dragging files over, §5.18): over a target that will attach what is dragged over it,
/// a `composer.dropOutline` pt dashed `focus` outline (`composer.dropDash`), and the words that say what the drop does in
/// `label` `accent`. Under them a surface hides or veils what the target shows at rest: the quick reply's field is covered
/// in `sheet`, its face, words and buttons hidden, since the outline takes its edge; the composer's body is veiled in
/// `sheet` at `composer.dropVeil`, the words on solid `sheet`, so its text never runs through them.
///
/// The words keep clear of what the drag shows under the pointer (`obstruction`): centred while that is elsewhere, else
/// beside it, or above or below it in a tall target, and in shorter words (`compactLabel`) when the full ones fit nowhere
/// clear. Transparent to clicks and drags.
@MainActor
final class AttachmentDropOverlay: NSView {
    /// “Drop to attach”, “Drop to reply with attachment”.
    var label: String { didSet { needsDisplay = true } }
    /// The words for when `label` fits nowhere clear of the drag: “Drop to attach”.
    var compactLabel: String? { didSet { needsDisplay = true } }
    /// How far the outline sits inside the overlay's bounds: the composer's `dropInset`, the quick reply's 0.
    var inset: CGFloat { didSet { needsDisplay = true } }
    /// The outline's corner radius.
    var radius: CGFloat { didSet { needsDisplay = true } }
    /// The surface drawn under the outline, which hides what the target shows at rest; nil keeps it showing.
    var fill: NSColor? { didSet { needsDisplay = true } }
    /// How much of `fill` covers: 1 hides what is under it, less veils it (the words then sit on solid `fill`).
    var fillAlpha: CGFloat { didSet { needsDisplay = true } }
    /// What the drag shows under the pointer, in this view's coordinates; nil while nothing is dragged over.
    var obstruction: NSRect? { didSet { if oldValue != obstruction { needsDisplay = true } } }

    init(label: String, compactLabel: String? = nil, inset: CGFloat, radius: CGFloat, fill: NSColor? = nil, fillAlpha: CGFloat = 1) {
        self.label = label
        self.compactLabel = compactLabel
        self.inset = inset
        self.radius = radius
        self.fill = fill
        self.fillAlpha = fillAlpha
        super.init(frame: .zero)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AttachmentDropOverlay is built in code")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows the treatment for `drag`, its words clear of what it shows under the pointer; nil hides it.
    func show(for drag: NSDraggingInfo?) {
        guard let drag else {
            isHidden = true
            obstruction = nil
            return
        }
        obstruction = obstruction(of: drag)
        isHidden = false
    }

    /// What `drag` shows under the pointer, in this view's coordinates: a reader chip's card where the drag holds it, or
    /// for a drag from another app (whose picture the app cannot see) the pointer and the badge beside it.
    func obstruction(of drag: NSDraggingInfo) -> NSRect {
        let pointer = convert(drag.draggingLocation, from: nil)
        // y down in both: the reader's page and this view are flipped.
        if let card = (drag.draggingSource as? AttachmentDragController)?.current?.card, !card.isEmpty {
            return card.offsetBy(dx: pointer.x, dy: pointer.y)
        }
        let side = Quire.Space.s9
        return NSRect(x: pointer.x - side / 2, y: pointer.y - side / 2, width: side, height: side)
    }

    /// The area inside the dashed line.
    private var outline: NSRect {
        let width = Quire.Layout.Composer.dropOutline
        return bounds.insetBy(dx: inset + width / 2, dy: inset + width / 2)
    }

    /// The words drawn now and where (the app's tests read it).
    var placedLabel: Placement {
        let role = QuireFont.Role.label
        let texts = [label] + (compactLabel.map { [$0] } ?? [])
        let measured = texts.map { ($0, ceil(QuireFont.attributedString($0, role: role, color: .qAccent).size().width) + 1) }
        return Self.place(measured, in: outline, lineHeight: role.lineHeight, avoiding: obstruction)
    }

    struct Placement: Equatable {
        let text: String
        let frame: NSRect
    }

    /// Where the words go in `outline` (flipped): centred unless `obstruction` covers that; else beside it, the roomier side
    /// first, or above or below it first in a target at least four lines tall; each try in the full words, then the shorter
    /// ones. With no clear place, the shortest words centred.
    static func place(_ texts: [(String, CGFloat)], in outline: NSRect, lineHeight: CGFloat, avoiding obstruction: NSRect?) -> Placement {
        let room = outline.insetBy(dx: Quire.Space.s5, dy: Quire.Space.s1)
        let gap = Quire.Space.s4
        func centred(_ width: CGFloat) -> NSRect {
            NSRect(x: (outline.midX - width / 2).rounded(), y: (outline.midY - lineHeight / 2).rounded(), width: width, height: lineHeight)
        }
        for (text, natural) in texts {
            let width = min(natural, room.width)
            let middle = centred(width)
            guard let obstruction, middle.intersects(obstruction) else { return Placement(text: text, frame: middle) }
            let left = NSRect(x: (obstruction.minX - gap - width).rounded(), y: middle.minY, width: width, height: lineHeight)
            let right = NSRect(x: (obstruction.maxX + gap).rounded(), y: middle.minY, width: width, height: lineHeight)
            let above = NSRect(x: middle.minX, y: (obstruction.minY - gap - lineHeight).rounded(), width: width, height: lineHeight)
            let below = NSRect(x: middle.minX, y: (obstruction.maxY + gap).rounded(), width: width, height: lineHeight)
            let sideways = obstruction.midX >= outline.midX ? [left, right] : [right, left]
            let upright = obstruction.midY >= outline.midY ? [above, below] : [below, above]
            let tries = outline.height >= 4 * lineHeight ? upright + sideways : sideways + upright
            if let clear = tries.first(where: { room.contains($0) && !$0.intersects(obstruction) }) {
                return Placement(text: text, frame: clear)
            }
        }
        let (text, natural) = texts.last ?? ("", 0)
        return Placement(text: text, frame: centred(min(natural, room.width)))
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = Quire.Layout.Composer.self
        let width = c.dropOutline
        // An outline on the bounds' edge (inset 0) rounds the surface with it; one inside them leaves the bounds square.
        if let fill { QuireDraw.fill(bounds, radius: inset > 0 ? 0 : radius, fill.withAlphaComponent(fillAlpha)) }
        let path = QuireDraw.roundedRect(outline, radius: radius - width / 2)
        path.lineWidth = width
        path.setLineDash(c.dropDash, count: c.dropDash.count, phase: 0)
        NSColor.qFocus.setStroke()
        path.stroke()
        let placed = placedLabel
        if let fill, fillAlpha < 1 {
            // Over a veil the words stand on the solid surface, so nothing under them shows through.
            let backing = placed.frame.insetBy(dx: -Quire.Space.s3, dy: -Quire.Space.s1)
            QuireDraw.fill(backing, radius: backing.height / 2, fill)
        }
        let words = QuireFont.attributedString(placed.text, role: .label, color: .qAccent)
        words.draw(with: placed.frame, options: QuireFont.drawingOptions, context: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
