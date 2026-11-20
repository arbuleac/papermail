import AppKit
import SSDesign

/// Quire's drop treatment (spec §5.20 Dragging files over, §5.18): over a target that will attach what is dragged over it,
/// a `composer.dropOutline` pt dashed `focus` outline (`composer.dropDash`), and the words that say what the drop does in
/// `label` `accent`, centred. The composer's body keeps its text under it; the quick reply's field is covered in `sheet`,
/// its face, words and buttons hidden, since the outline takes its edge. Transparent to clicks and drags.
@MainActor
final class AttachmentDropOverlay: NSView {
    /// “Drop to attach”, “Drop to reply with attachment”.
    var label: String { didSet { needsDisplay = true } }
    /// How far the outline sits inside the overlay's bounds: the composer's `dropInset`, the quick reply's 0.
    var inset: CGFloat { didSet { needsDisplay = true } }
    /// The outline's corner radius.
    var radius: CGFloat { didSet { needsDisplay = true } }
    /// The surface drawn under the outline, which hides what the target shows at rest; nil keeps it showing.
    var fill: NSColor? { didSet { needsDisplay = true } }

    init(label: String, inset: CGFloat, radius: CGFloat, fill: NSColor? = nil) {
        self.label = label
        self.inset = inset
        self.radius = radius
        self.fill = fill
        super.init(frame: .zero)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("AttachmentDropOverlay is built in code")
    }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let c = Quire.Layout.Composer.self
        let width = c.dropOutline
        if let fill { QuireDraw.fill(bounds.insetBy(dx: inset, dy: inset), radius: radius, fill) }
        let outline = bounds.insetBy(dx: inset + width / 2, dy: inset + width / 2)
        let path = QuireDraw.roundedRect(outline, radius: radius - width / 2)
        path.lineWidth = width
        path.setLineDash(c.dropDash, count: c.dropDash.count, phase: 0)
        NSColor.qFocus.setStroke()
        path.stroke()
        let role = QuireFont.Role.label
        let words = QuireFont.attributedString(label, role: role, color: .qAccent)
        let size = words.size()
        let room = max(0, outline.width - 2 * Quire.Space.s5)
        let wordsWidth = min(ceil(size.width) + 1, room)
        words.draw(with: NSRect(x: (bounds.midX - wordsWidth / 2).rounded(), y: (bounds.midY - role.lineHeight / 2).rounded(),
                                width: wordsWidth, height: role.lineHeight), options: QuireFont.drawingOptions, context: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
