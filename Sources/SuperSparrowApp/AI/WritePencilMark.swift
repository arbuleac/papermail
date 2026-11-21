import AppKit
import SSDesign

/// The pencil at the caret while a reply streams in (§5.56): in place of the insertion point, just after the last letter
/// written (before the first word, after the text it will replace, itself in pencil), `pencil.line` in `accent`, bobbing
/// gently as a pen does between words (still under Reduce Motion), then the quiet esc keycap. A click stops the write,
/// as esc does. Where its line has no room for both, the glyph shows alone.
@MainActor
final class WritePencilMark: WriteInlineControl {
    static let keycap = "esc"

    private let glyph = GlyphView(frame: .zero)

    /// The text's own writing style where the pencil sits: its baseline and letters set the marks' middle.
    var textAttributes: [NSAttributedString.Key: Any] = [:] {
        didSet { needsLayout = true; needsDisplay = true }
    }

    /// The glyph alone: the line has no room for the keycap.
    var showsKeycap = true {
        didSet { if oldValue != showsKeycap { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(glyph)
        toolTip = "Stop  esc"
        setAccessibilityLabel("Stop writing")
    }

    static var glyphSize: NSSize { WriteGlyph.size(Quire.Icon.helpMeWrite, size: Quire.Layout.WriteCaret.pencilGlyph) }

    func width(showingKeycap: Bool) -> CGFloat {
        let glyph = Self.glyphSize.width
        guard showingKeycap else { return ceil(glyph) }
        return ceil(glyph + Quire.Layout.WriteCaret.keycapGap + WriteQuietKeycap.size(Self.keycap).width)
    }

    /// Where the marks' middle sits, from the face's top: the middle of the lowercase letters on the text's baseline.
    private var middleFromTop: CGFloat {
        let font = textAttributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
        return WriteTextGeometry.probeBaseline(textAttributes) - font.xHeight / 2
    }

    override func layout() {
        super.layout()
        let face = bodyRect
        let size = Self.glyphSize
        glyph.frame = NSRect(x: face.minX, y: (face.minY + middleFromTop - size.height / 2).rounded(), width: ceil(size.width),
                             height: ceil(size.height))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard showsKeycap else { return }
        let face = bodyRect
        let size = WriteQuietKeycap.size(Self.keycap)
        let x = face.minX + ceil(Self.glyphSize.width) + Quire.Layout.WriteCaret.keycapGap
        let rect = NSRect(x: x, y: (face.minY + middleFromTop - size.height / 2).rounded(), width: size.width, height: size.height)
        let ink: NSColor = interactionState == .rest ? .qInk3 : .qInk2
        WriteQuietKeycap.draw(Self.keycap, in: rect, ink: ink, edge: interactionState == .rest ? .qRule : .qRuleStrong, hairline: hairline)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateBob()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateBob()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateBob()
    }

    /// The glyph rises and falls `pencilBob` pt each way, once every `pencilBobPeriod`, while it shows; never under
    /// Reduce Motion. An ambient loop, like the spinner's turn: a key press does not finish it.
    func updateBob() {
        glyph.wantsLayer = true
        guard let layer = glyph.layer else { return }
        let bobs = window != nil && !isHiddenOrHasHiddenAncestor && !QuireEnvironment.reduceMotion
        guard bobs else {
            layer.removeAnimation(forKey: "write.bob")
            return
        }
        guard layer.animation(forKey: "write.bob") == nil else { return }
        let bob = CABasicAnimation(keyPath: "transform.translation.y")
        let amplitude = Quire.Layout.WriteCaret.pencilBob
        bob.fromValue = -amplitude
        bob.toValue = amplitude
        bob.duration = Quire.Motion.writePencilBob / 2
        bob.autoreverses = true
        bob.repeatCount = .infinity
        bob.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(bob, forKey: "write.bob")
    }

    /// Whether the glyph bobs now (tests).
    var isBobbing: Bool { glyph.layer?.animation(forKey: "write.bob") != nil }

    /// The pencil glyph in `accent`, in a layer of its own so it can bob without the keycap.
    private final class GlyphView: NSView {
        override var isFlipped: Bool { true }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func draw(_ dirtyRect: NSRect) {
            WriteGlyph.draw(Quire.Icon.helpMeWrite, size: Quire.Layout.WriteCaret.pencilGlyph, color: .qAccent, centredIn: bounds)
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }
}
