import AppKit
import SSDesign

/// A static run of text, wrapped to a width and drawn by string drawing, so it keeps the exact line heights of
/// its attributes and resolves dynamic colours in whatever appearance draws it (a snapshot included).
@MainActor
final class DesignGalleryText: NSView {
    private let string: NSAttributedString

    /// Sizes itself to the text: at most `maxWidth` wide, wrapping as needed.
    init(_ string: NSAttributedString, maxWidth: CGFloat = 10_000) {
        self.string = string
        let bounds = string.boundingRect(with: NSSize(width: maxWidth, height: 10_000), options: QuireFont.drawingOptions)
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(min(maxWidth, bounds.width)), height: ceil(bounds.height)))
    }

    /// A caption in a Quire role (meta `ink3` by default), the way the specimen labels states.
    /// Quire's paragraph styles are single-line and truncate; captions wrap, so the style is swapped for a
    /// wrapping copy with the same line height.
    convenience init(_ text: String, role: QuireFont.Role = .meta, color: NSColor = .qInk3, maxWidth: CGFloat = 10_000,
                     alignment: NSTextAlignment = .natural) {
        let string = NSMutableAttributedString(attributedString: QuireFont.attributedString(text, role: role, color: color))
        let paragraph = (QuireFont.paragraphStyle(role).mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.alignment = alignment
        string.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: string.length))
        self.init(string, maxWidth: maxWidth)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        string.draw(with: bounds, options: QuireFont.drawingOptions, context: nil)
    }
}
