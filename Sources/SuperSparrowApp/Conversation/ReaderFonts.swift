import AppKit
import SSDesign

/// Text the reader sets natively that Quire's roles do not name directly.
@MainActor
enum ReaderFonts {
    private static var placeholderFonts: [QuireFont.Role: NSFont] = [:]

    /// A placeholder for missing data (spec §4.1): set in the role it replaces, `ink3`, italic and never
    /// Semibold, so "No subject" never reads as content or as unread.
    static func placeholder(_ text: String, role: QuireFont.Role) -> NSAttributedString {
        let font = placeholderFont(role)
        var attributes = QuireFont.attributes(role, color: .qInk3)
        attributes[.font] = font
        let lineHeight = role.lineHeight
        attributes[.baselineOffset] = (lineHeight - NSLayoutManager().defaultLineHeight(for: font)) / 2
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func placeholderFont(_ role: QuireFont.Role) -> NSFont {
        if let cached = placeholderFonts[role] { return cached }
        let base = NSFont.systemFont(ofSize: role.size, weight: .regular)
        var descriptor = base.fontDescriptor
        if role.family == .serif { descriptor = descriptor.withDesign(.serif) ?? descriptor }
        descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic))
        let font = NSFont(descriptor: descriptor, size: role.size) ?? base
        placeholderFonts[role] = font
        return font
    }

    /// One line in `role`, measured the way it draws.
    static func width(_ string: NSAttributedString) -> CGFloat {
        ceil(string.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                 options: QuireFont.drawingOptions).width)
    }
}
