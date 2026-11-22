import AppKit
import PaperDesign

/// A mark Help me write draws in the reply's text that acts on a click (§5.56): the ghost after the caret, the selection
/// pill, the pencil while a reply streams, the afterline's actions, the prompt line's chips. It draws itself from its
/// hover and press state; a click runs `onPress`. Most of them are pointer affordances only, since every one has its key
/// (⌘J, esc, ⇧⌘J, ⌘Z) named on it: they never take the keyboard (`takesKeyboard` off), so Tab in the text stays the text's.
@MainActor
class WriteInlineControl: QuireControl {
    var onPress: (() -> Void)?

    /// Whether Tab reaches it (the prompt line's chips); the marks in the text never do.
    var takesKeyboard = false {
        didSet { refusesFirstResponder = !takesKeyboard }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        refusesFirstResponder = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("built in code")
    }

    override var mouseDownCanMoveWindow: Bool { false }

    /// A click in the text acts at once, the window key or not, as the text's own click places the caret.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func activate() {
        onPress?()
    }

    override func hoverDidChange() {
        needsDisplay = true
    }

    /// The hairline the marks' edges take: one device pixel, 1 pt in Increase Contrast.
    var hairline: CGFloat { QuireHairline.width(for: self) }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Draws a template symbol tinted, on whole points: the symbol's own pixels take the colour (dynamic colours resolve as
/// it draws, under the view's appearance).
@MainActor
enum WriteGlyph {
    static func draw(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, centredIn rect: NSRect) {
        guard let image = QuireSymbol.image(name, size: .custom(size, weight: weight)) else { return }
        let s = image.size
        let target = NSRect(x: (rect.midX - s.width / 2).rounded(), y: (rect.midY - s.height / 2).rounded(), width: s.width, height: s.height)
        draw(image, color: color, in: target)
    }

    static func draw(_ image: NSImage, color: NSColor, in rect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.beginTransparencyLayer(in: rect.insetBy(dx: -1, dy: -1), auxiliaryInfo: nil)
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        color.setFill()
        rect.fill(using: .sourceAtop)
        context.endTransparencyLayer()
        context.restoreGState()
    }

    static func size(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSSize {
        QuireSymbol.image(name, size: .custom(size, weight: weight))?.size ?? NSSize(width: size, height: size)
    }
}
