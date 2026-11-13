import AppKit
import SSCore

/// The pictures in a composer body (spec §5.20, Images in the body): found for sending, taken out for a kept draft's
/// archive and put back when it reopens. The body is the one place a picture lives, so a picture deleted from it (or
/// brought back by Undo) is not sent (or is), with nothing else to keep in step.
@MainActor
enum ComposeInlineImages {
    /// The pictures in `body`, in order, each content id once.
    static func pictures(in body: NSAttributedString) -> [ComposeImageAttachment] {
        var seen = Set<String>()
        var pictures: [ComposeImageAttachment] = []
        body.enumerateAttribute(.attachment, in: NSRange(location: 0, length: body.length)) { value, _, _ in
            guard let picture = value as? ComposeImageAttachment, seen.insert(picture.inlineImage.contentID).inserted else { return }
            pictures.append(picture)
        }
        return pictures
    }

    /// `body` with each picture reduced to its marked attachment character, for the archive a kept draft stores: the
    /// bytes are kept beside it (`ComposeDraftRecord.images`), and only a character and its content id go in.
    static func detached(_ body: NSAttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: body)
        let whole = NSRange(location: 0, length: result.length)
        result.enumerateAttribute(.attachment, in: whole) { value, range, _ in
            if value is ComposeImageAttachment { result.removeAttribute(.attachment, range: range) }
        }
        return result
    }

    /// `body` read back from a kept draft, each marked character given its picture again from `pictures` (by content
    /// id). A character whose picture is missing (its file gone) is removed: it would be an empty box, and sent as
    /// nothing.
    static func attached(_ body: NSAttributedString, pictures: [String: ComposeImageAttachment]) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: body)
        var missing: [NSRange] = []
        let text = result.string as NSString
        result.enumerateAttribute(ComposerInlineImage.attributeKey, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            guard let id = value as? String else { return }
            for index in range.location..<NSMaxRange(range) where text.character(at: index) == 0xFFFC {
                let character = NSRange(location: index, length: 1)
                if let picture = pictures[id] {
                    result.addAttribute(.attachment, value: picture, range: character)
                } else {
                    missing.append(character)
                }
            }
        }
        for range in missing.reversed() { result.deleteCharacters(in: range) }
        return result
    }

    /// The body as the reader shows a kept draft, which is set as text: what was typed, each picture as the plain-text
    /// alternative names it (“[image: sunset.png]”).
    static func readerText(of body: NSAttributedString) -> String {
        let result = NSMutableString(string: body.string)
        var replacements: [(range: NSRange, text: String)] = []
        body.enumerateAttribute(.attachment, in: NSRange(location: 0, length: body.length)) { value, range, _ in
            guard let picture = value as? ComposeImageAttachment else { return }
            replacements.append((range, String(repeating: picture.inlineImage.plainText, count: range.length)))
        }
        for replacement in replacements.reversed() { result.replaceCharacters(in: replacement.range, with: replacement.text) }
        return (result as String).replacingOccurrences(of: "\u{FFFC}", with: "")
    }
}
