import AppKit
import PaperDesign

/// The ghost after the caret (§5.56): “⌘J to write a reply” on an empty reply, “⌘J to write from your notes” once the
/// user pauses at the end of their notes. Ghost text in the field's own writing font and the placeholder's ink (`ink3`),
/// on the caret's baseline, its keycap the quiet one; a button: hover turns it `ink2`, a click writes as ⌘J does. It
/// never wraps and never covers text: where the line has room for the keycap alone it shows only that, and where it has
/// none it is not shown (`WriteInlineLayer` decides, from `width(showingWords:)`).
@MainActor
final class WriteCaretHint: WriteInlineControl {
    static let keycap = "\u{2318}J"

    /// The words after the keycap.
    var words = WriteWords.ghostReply {
        didSet { if oldValue != words { needsDisplay = true; updateAccessibility() } }
    }

    /// The text's own writing style where the ghost sits: its font, line and baseline offset.
    var textAttributes: [NSAttributedString.Key: Any] = [:] {
        didSet { needsDisplay = true }
    }

    /// The keycap alone: the line's room does not hold the words.
    var showsWords = true {
        didSet { if oldValue != showsWords { needsDisplay = true } }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        toolTip = "Help Me Write  \u{2318}J"
        updateAccessibility()
    }

    private func updateAccessibility() {
        setAccessibilityLabel("Write with Help Me Write")
        setAccessibilityHelp("Command J " + words)
    }

    /// The face's width with or without the words.
    func width(showingWords: Bool) -> CGFloat {
        let cap = WriteQuietKeycap.size(Self.keycap).width
        guard showingWords else { return cap }
        return cap + Quire.Layout.WriteCaret.keycapGap + ceil(wordsString(.qInk3).size().width)
    }

    private func wordsString(_ color: NSColor) -> NSAttributedString {
        var attributes = textAttributes
        attributes[.foregroundColor] = color
        attributes[.underlineStyle] = nil
        attributes[.link] = nil
        if let style = (attributes[.paragraphStyle] as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle {
            // One line, never wrapped: the layer gives the ghost only the room its line has.
            style.lineBreakMode = .byClipping
            style.firstLineHeadIndent = 0
            style.headIndent = 0
            style.textLists = []
            attributes[.paragraphStyle] = style
        }
        return NSAttributedString(string: words, attributes: attributes)
    }

    /// The face's baseline, from its top: where the text's line puts it.
    var baselineFromTop: CGFloat { WriteTextGeometry.probeBaseline(textAttributes) }

    override func draw(_ dirtyRect: NSRect) {
        let face = bodyRect
        let ink: NSColor = interactionState == .rest ? .qInk3 : .qInk2
        let font = textAttributes[.font] as? NSFont ?? NSFont.systemFont(ofSize: 14)
        let baseline = face.minY + baselineFromTop
        // The cap sits on the middle of the lowercase letters, as a keycap set in running text does (§5.36).
        let size = WriteQuietKeycap.size(Self.keycap)
        let middle = baseline - font.xHeight / 2
        let cap = NSRect(x: face.minX, y: (middle - size.height / 2).rounded(), width: size.width, height: size.height)
        WriteQuietKeycap.draw(Self.keycap, in: cap, ink: ink, edge: interactionState == .rest ? .qRule : .qRuleStrong, hairline: hairline)
        guard showsWords else { return }
        let x = cap.maxX + Quire.Layout.WriteCaret.keycapGap
        let text = wordsString(ink)
        text.draw(with: NSRect(x: x, y: face.minY, width: max(0, face.maxX - x) + 1, height: face.height),
                  options: [.usesLineFragmentOrigin], context: nil)
    }

    /// Fades in (Quire's motion, at once under Reduce Motion), as the notes ghost does after the user pauses.
    func fadeIn() {
        wantsLayer = true
        guard let layer else { return }
        layer.opacity = 0
        Quire.Motion.animate(layer, keyPath: "opacity", to: Float(1), duration: Quire.Motion.standard, curve: .settle, reduced: .instant)
    }

    /// Shows at once, any fade cut short.
    func showNow() {
        guard let layer else { return }
        Quire.Motion.animate(layer, keyPath: "opacity", to: Float(1), duration: 0, curve: .settle, reduced: .instant)
    }
}
