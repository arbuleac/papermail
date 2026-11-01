import AppKit
import SSCore

/// Translates what the editor holds into what `ComposerHTMLExporter` reads: typed list markers are removed
/// and every paragraph carries a `ComposerBlock` derived from its paragraph style, so a stale attribute
/// left behind by editing can never turn a plain paragraph into a list item.
@MainActor
enum ComposeBodyNormalizer {
    static func normalize(_ source: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: source)
        guard result.length > 0 else { return result }
        var paragraphs: [NSRange] = []
        (result.string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: result.length), options: [.byParagraphs, .substringNotRequired]) { _, _, enclosing, _ in
            paragraphs.append(enclosing)
        }
        for var range in paragraphs.reversed() where range.length > 0 {
            let attributes = result.attributes(at: range.location, effectiveRange: nil)
            let style = attributes[.paragraphStyle] as? NSParagraphStyle
            var block = ComposerBlock.from(attributes: attributes)
            if let list = style?.textLists.last {
                block = list.markerFormat.rawValue.contains("decimal") ? .numberedItem : .bulletItem
                var content = range
                if ComposeTextView.isNewline((result.string as NSString).character(at: NSMaxRange(range) - 1)) {
                    content.length -= 1
                }
                if let marker = ComposeTextView.markerRange(in: result.string as NSString, paragraph: content) {
                    result.deleteCharacters(in: marker)
                    range.length -= marker.length
                }
            } else if block.isListItem {
                block = .paragraph
            }
            if range.length > 0 {
                result.addAttribute(ComposerBlock.attributeKey, value: block.rawValue, range: range)
            }
        }
        return result
    }
}
