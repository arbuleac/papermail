import AppKit
import SSCore

/// Draws the vertical bar beside block-quote paragraphs. Quotes are a paragraph attribute rather than
/// characters, so the bar has to be painted by the layout, not typed.
final class ComposeLayoutManager: NSLayoutManager {
    static let barInset: CGFloat = 4
    static let barWidth: CGFloat = 3

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(ComposerBlock.attributeKey, in: characters, options: []) { value, range, _ in
            guard let raw = value as? String, raw == ComposerBlock.quote.rawValue else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            NSColor.tertiaryLabelColor.setFill()
            self.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                let bar = NSRect(
                    x: origin.x + rect.minX + Self.barInset,
                    y: origin.y + rect.minY + 1,
                    width: Self.barWidth,
                    height: max(0, rect.height - 2)
                )
                bar.fill()
            }
        }
    }
}
