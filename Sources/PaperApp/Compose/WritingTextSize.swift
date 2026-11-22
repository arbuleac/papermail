import AppKit
import PaperDesign

/// Text set in `writing` (a composer's body, the quick reply) moved to a Text size (spec §4.15): every run takes the
/// size with its own face and traits (bold, italic, a fallback font), every paragraph the size's line with its
/// indents, lists and quotes kept, and every baseline the size's offset. Links, underlines, inks and marks stay.
///
/// A switch is not an edit, so the undo stack keeps text at the size it was typed at; the editors run this over
/// every edit too (`NSTextStorageDelegate`), so an undo or a redo puts that text back at the size shown now.
enum WritingTextSize {
    static let role = QuireFont.Role.writing

    /// Moves what `range` covers (all of `storage` when nil), whole paragraphs at a time, to `textSize`. Touches only
    /// runs that are not there already, so an edit that needs nothing changes nothing. True when it changed something.
    @discardableResult
    static func apply(_ textSize: QuireFont.TextSize, to storage: NSTextStorage, in range: NSRange? = nil) -> Bool {
        let whole = NSRange(location: 0, length: storage.length)
        guard whole.length > 0 else { return false }
        // Whole paragraphs: an undo that brings back the start of a paragraph brings back its paragraph style.
        let edited = range.map { NSIntersectionRange($0, whole) } ?? whole
        let scope = (storage.string as NSString).paragraphRange(for: edited.location < whole.length ? edited : NSRange(location: whole.length - 1, length: 0))
        let size = role.size(at: textSize)
        let offset = QuireFont.baselineOffset(role, textSize: textSize)
        var fonts: [(NSRange, NSFont)] = []
        var styles: [(NSRange, NSParagraphStyle)] = []
        var baselines: [NSRange] = []
        storage.enumerateAttribute(.font, in: scope, options: []) { value, run, _ in
            guard let font = value as? NSFont, font.pointSize != size else { return }
            fonts.append((run, resized(font, to: textSize)))
        }
        storage.enumerateAttribute(.paragraphStyle, in: scope, options: []) { value, run, _ in
            guard let style = value as? NSParagraphStyle else { return }
            let moved = relined(style, to: textSize)
            if moved !== style { styles.append((run, moved)) }
        }
        storage.enumerateAttribute(.baselineOffset, in: scope, options: []) { value, run, _ in
            guard let value = value as? NSNumber, abs(CGFloat(truncating: value) - offset) > 0.001 else { return }
            baselines.append(run)
        }
        guard !fonts.isEmpty || !styles.isEmpty || !baselines.isEmpty else { return false }
        storage.beginEditing()
        for (run, font) in fonts { storage.addAttribute(.font, value: font, range: run) }
        for (run, style) in styles { storage.addAttribute(.paragraphStyle, value: style, range: run) }
        for run in baselines { storage.addAttribute(.baselineOffset, value: offset, range: run) }
        storage.endEditing()
        return true
    }

    /// The same face at the writing size. From its descriptor, not `NSFontManager.convert(_:toSize:)`, which sets the
    /// system font's bold back to regular.
    static func resized(_ font: NSFont, to textSize: QuireFont.TextSize) -> NSFont {
        let size = role.size(at: textSize)
        return font.pointSize == size ? font : NSFont(descriptor: font.fontDescriptor, size: size) ?? font
    }

    /// A paragraph style on the writing line at `textSize`; the same object when it is there already, or when it is
    /// set on a line no Text size gives `writing` (none in a composer).
    static func relined(_ style: NSParagraphStyle, to textSize: QuireFont.TextSize) -> NSParagraphStyle {
        let line = role.lineHeight(at: textSize)
        guard style.minimumLineHeight != line || style.maximumLineHeight != line, lines.contains(style.minimumLineHeight),
              let copy = style.mutableCopy() as? NSMutableParagraphStyle else { return style }
        copy.minimumLineHeight = line
        copy.maximumLineHeight = line
        return copy
    }

    private static let lines = Set(QuireFont.TextSize.allCases.map { role.lineHeight(at: $0) })
}
