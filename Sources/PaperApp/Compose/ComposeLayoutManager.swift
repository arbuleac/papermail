import AppKit
import PaperCore
import PaperDesign

/// Draws the bar beside block-quote paragraphs. Quotes are a paragraph attribute rather than characters, so
/// the bar has to be painted by the layout, not typed. It is the shared quote style (`layout.textStyle`): a
/// 2 pt `rule` bar on the text's leading edge, the text 12 pt in, as the reader draws a sent reply's quote.
///
/// It also gives a line holding a picture its height (spec §5.20, Images in the body): the writing style's exact
/// 21 pt lines cap every line, and a taller picture would be drawn over the lines above it.
final class ComposeLayoutManager: NSLayoutManager {
    private let pictureLines = PictureLineHeights()

    override init() {
        super.init()
        delegate = pictureLines
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ComposeLayoutManager is built in code")
    }

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

/// Grows a line that holds a picture to the picture's height, its baseline under the picture and the text's descent
/// below it, so the picture sits on the line as a tall letter would; lines without one keep the writing style's
/// height. The picture's height is its cell's, as drawn at this line's width.
private final class PictureLineHeights: NSObject, NSLayoutManagerDelegate {
    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
                       lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>,
                       in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard let storage = layoutManager.textStorage else { return false }
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        var tallest: CGFloat = 0
        storage.enumerateAttribute(.attachment, in: characters, options: []) { value, range, _ in
            guard let picture = value as? ComposeImageAttachment, let cell = picture.attachmentCell else { return }
            for index in range.location..<NSMaxRange(range) {
                let frame = cell.cellFrame(for: textContainer, proposedLineFragment: lineFragmentRect.pointee, glyphPosition: .zero,
                                           characterIndex: index)
                let raised = (storage.attribute(.baselineOffset, at: index, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
                tallest = max(tallest, frame.height + CGFloat(max(0, raised)))
            }
        }
        let descent = lineFragmentRect.pointee.height - baselineOffset.pointee
        guard tallest > baselineOffset.pointee else { return false }
        lineFragmentRect.pointee.size.height = tallest + descent
        lineFragmentUsedRect.pointee.size.height = max(lineFragmentUsedRect.pointee.height, tallest + descent)
        baselineOffset.pointee = tallest
        return true
    }
}
