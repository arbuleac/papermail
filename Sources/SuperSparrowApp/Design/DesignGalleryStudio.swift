import AppKit
import SSDesign

/// The specimen's page furniture (`--studio*`, `.sh`, `.card h3` in docs/design/specimen.html). These are not
/// Quire tokens and no screen uses them: they frame the components so a gallery render lines up with section D
/// of the specimen, crop for crop, at the same 1440 pt page width.
@MainActor
enum DesignGalleryStudio {
    static let pageWidth: CGFloat = 1440
    static let contentWidth: CGFloat = 1280
    static let gridGap: CGFloat = 20
    static let columns = 12

    /// The desk the cards sit on. Increased contrast keeps the specimen's values; only the cards change.
    static let background = studio("studio", light: 0xE3DFD7FF, dark: 0x0B0B0AFF)
    static let rule = studio("studioRule", light: 0xCCC6BBFF, dark: 0x2B2926FF)
    static let ink = studio("studioInk", light: 0x2E2B27FF, dark: 0xDAD5CCFF)
    static let ink2 = studio("studioInk2", light: 0x5E5850FF, dark: 0xA09A90FF)

    private static func studio(_ name: String, light: UInt32, dark: UInt32) -> NSColor {
        NSColor.quire(name, QuireColorValues(light: light, dark: dark, lightHC: light, darkHC: dark))
    }

    /// New York at a size and CSS weight. The specimen's headings are not Quire roles, so they are built here
    /// with the same recipe QuireFont uses.
    static func serif(_ size: CGFloat, weight: CGFloat = 600) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: QuireFont.fontWeight(weight))
        let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
        return NSFont(descriptor: descriptor, size: size) ?? base
    }

    static func text(_ string: String, font: NSFont, color: NSColor, lineHeight: CGFloat, tracking: CGFloat = 0,
                     alignment: NSTextAlignment = .natural) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        // Centre the font's line in the line box, as CSS line-height (and QuireFont) do.
        let offset = (lineHeight - NSLayoutManager().defaultLineHeight(for: font)) / 2
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph, .baselineOffset: offset,
        ]
        // An explicit 0 kern would turn off the font's own kerning.
        if tracking != 0 { attributes[.kern] = tracking }
        return NSAttributedString(string: string, attributes: attributes)
    }

    /// The width of `span` grid columns.
    static func width(span: Int) -> CGFloat {
        let column = (contentWidth - CGFloat(columns - 1) * gridGap) / CGFloat(columns)
        return (CGFloat(span) * column + CGFloat(span - 1) * gridGap).rounded(.down)
    }
}
