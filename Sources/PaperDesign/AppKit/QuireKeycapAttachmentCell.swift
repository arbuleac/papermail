import AppKit

/// A keycap inside running text (empty-state hints: “J K to move · ↩ to open”). An attachment cell rather
/// than an image so the cap is drawn at draw time, under the current appearance, and wraps with the words.
final class QuireKeycapAttachmentCell: NSTextAttachmentCell {
    let legend: String
    let style: QuireKeycap.Style
    /// Space either side, so adjacent caps and words do not touch.
    let margin: CGFloat
    /// Where the cap's bottom sits relative to the baseline: centres it on the text's x-height band.
    let baselineDrop: CGFloat

    init(legend: String, style: QuireKeycap.Style = .standard, margin: CGFloat, font: NSFont) {
        self.legend = legend
        self.style = style
        self.margin = margin
        let height = style.height
        // Centre the cap on the middle of the lowercase letters, as CSS `vertical-align: middle` does.
        self.baselineDrop = (height - font.xHeight) / 2
        super.init(textCell: "")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("built in code") }

    override func cellSize() -> NSSize {
        let size = QuireKeycap.size(for: legend, style: style)
        return NSSize(width: size.width + 2 * margin, height: size.height)
    }

    override func cellBaselineOffset() -> NSPoint {
        NSPoint(x: 0, y: -baselineDrop)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        let size = QuireKeycap.size(for: legend, style: style)
        let rect = NSRect(x: cellFrame.minX + margin, y: cellFrame.minY + (cellFrame.height - size.height) / 2,
                          width: size.width, height: size.height)
        QuireKeycap.draw(legend, style: style, in: rect)
    }

    override func wantsToTrackMouse() -> Bool { false }
}
