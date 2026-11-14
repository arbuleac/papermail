import AppKit
import SSDesign

/// Text the reader sets natively that Quire's roles do not name directly.
@MainActor
enum ReaderFonts {
    private struct FaceKey: Hashable {
        let role: QuireFont.Role
        let textSize: QuireFont.TextSize
    }

    /// The italic face of each role and its baseline offset, resolved once: the headline asks on every selection.
    /// Keyed by the role actually set and the Text size, so a switch of either never returns another face.
    private static var placeholderFaces: [FaceKey: (font: NSFont, baselineOffset: CGFloat)] = [:]

    /// A placeholder for missing data (spec §4.1): set in the role it replaces (its sans twin under the SF Pro
    /// font) at `textSize`, `ink3`, italic and never Semibold, so "No subject" never reads as content or as unread.
    static func placeholder(_ text: String, role: QuireFont.Role, textSize: QuireFont.TextSize = .default) -> NSAttributedString {
        let role = QuireFont.resolvedRole(role)
        let face = placeholderFace(FaceKey(role: role, textSize: textSize))
        var attributes = QuireFont.attributes(role, color: .qInk3, textSize: textSize)
        attributes[.font] = face.font
        attributes[.baselineOffset] = face.baselineOffset
        return NSAttributedString(string: text, attributes: attributes)
    }

    private static func placeholderFace(_ key: FaceKey) -> (font: NSFont, baselineOffset: CGFloat) {
        if let cached = placeholderFaces[key] { return cached }
        let role = key.role
        let size = role.size(at: key.textSize)
        let base = NSFont.systemFont(ofSize: size, weight: .regular)
        var descriptor = base.fontDescriptor
        if role.family == .serif { descriptor = descriptor.withDesign(.serif) ?? descriptor }
        descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic))
        let font = NSFont(descriptor: descriptor, size: size) ?? base
        let face = (font, (role.lineHeight(at: key.textSize) - NSLayoutManager().defaultLineHeight(for: font)) / 2)
        placeholderFaces[key] = face
        return face
    }

    /// `string` for a text field, which sets its own line box: a role's exact line height and baseline offset,
    /// meant for string drawing, push the glyphs off the field's line. Callers centre the field on the role's line.
    static func fieldString(_ string: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: string)
        let range = NSRange(location: 0, length: result.length)
        result.removeAttribute(.baselineOffset, range: range)
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.allowsDefaultTighteningForTruncation = false
        style.baseWritingDirection = .natural
        result.addAttribute(.paragraphStyle, value: style, range: range)
        return result
    }

    /// A text field's height for one line of `string`.
    static func fieldHeight(_ field: NSTextField) -> CGFloat {
        ceil(field.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: 10_000, height: 200)).height ?? 16)
    }

    /// One line in `role`, measured the way it draws.
    static func width(_ string: NSAttributedString) -> CGFloat {
        ceil(string.boundingRect(with: NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                 options: QuireFont.drawingOptions).width)
    }
}
