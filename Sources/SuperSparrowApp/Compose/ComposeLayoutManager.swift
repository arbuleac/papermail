import AppKit
import SSCore
import SSDesign

/// Draws the bar beside block-quote paragraphs. Quotes are a paragraph attribute rather than characters, so
/// the bar has to be painted by the layout, not typed. It is the shared quote style (`layout.textStyle`): a
/// 2 pt `rule` bar on the text's leading edge, the text 12 pt in, as the reader draws a sent reply's quote.
final class ComposeLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, storage.length > 0 else { return }
        let padding = textContainers.first?.lineFragmentPadding ?? 0
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(ComposerBlock.attributeKey, in: characters, options: []) { value, range, _ in
            guard let raw = value as? String, raw == ComposerBlock.quote.rawValue else { return }
            let glyphs = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            NSColor.qRule.setFill()
            self.enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, _, _ in
                NSRect(x: origin.x + rect.minX + padding, y: origin.y + rect.minY,
                       width: Quire.Layout.TextStyle.quoteBar, height: rect.height).fill()
            }
        }
    }
}
