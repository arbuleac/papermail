import AppKit
import SSCore

/// The pictures in a composer body (spec §5.20, Images in the body): found for sending, taken out for a kept draft's
/// archive and put back when it reopens. The body is the one place a picture lives, so a picture deleted from it (or
/// brought back by Undo) is not sent (or is), with nothing else to keep in step.
@MainActor
enum ComposeInlineImages {
    /// The pictures in `body`, in order, each content id once, those still being prepared included.
    static func pictures(in body: NSAttributedString) -> [ComposeImageAttachment] {
        var seen = Set<String>()
        var pictures: [ComposeImageAttachment] = []
        body.enumerateAttribute(.attachment, in: NSRange(location: 0, length: body.length)) { value, _, _ in
            guard let picture = value as? ComposeImageAttachment, seen.insert(picture.inlineImage.contentID).inserted else { return }
            pictures.append(picture)
        }
        return pictures
    }

    /// The pictures in `body` whose bytes are in: what is sent, and what a kept draft stores.
    static func readyPictures(in body: NSAttributedString) -> [ComposeImageAttachment] {
        pictures(in: body).filter(\.isReady)
    }

    /// Returns once every picture in `body` that was still being prepared is ready, or has failed. Sending waits here,
    /// with the Send button showing it is sending, so a picture pasted just before Send goes with the message.
    static func waitUntilPrepared(_ body: NSAttributedString) async {
        for picture in pictures(in: body) where picture.isPreparing {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                picture.whenPrepared { _ in continuation.resume() }
            }
        }
    }

    /// Waits on the main thread for every picture in `body` still being prepared: closing a composer saves its draft
    /// before the window goes, and a picture left out of that save would be lost.
    static func finishPreparing(in body: NSAttributedString) {
        for picture in pictures(in: body) where picture.isPreparing { picture.finishNow() }
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

    /// A kept draft's archived body (`detached`) as the reader shows it, which is set as text: what was typed, each
    /// picture as the plain-text alternative names it (“[image: sunset.png]”), its name taken from `filenames` (by
    /// content id, from the draft's record). No picture's bytes are read: showing a draft is opening a conversation,
    /// and must stay in that budget. A character whose picture the record does not name is left out, as reopening
    /// the draft leaves it out.
    static func readerText(of body: NSAttributedString, filenames: [String: String]) -> String {
        let result = NSMutableString(string: body.string)
        var replacements: [(range: NSRange, text: String)] = []
        let text = body.string as NSString
        body.enumerateAttribute(ComposerInlineImage.attributeKey, in: NSRange(location: 0, length: body.length)) { value, range, _ in
            guard let id = value as? String else { return }
            for index in range.location..<NSMaxRange(range) where text.character(at: index) == 0xFFFC {
                let name = filenames[id].map(ComposerInlineImage.plainText(named:)) ?? ""
                replacements.append((NSRange(location: index, length: 1), name))
            }
        }
        for replacement in replacements.reversed() { result.replaceCharacters(in: replacement.range, with: replacement.text) }
        return (result as String).replacingOccurrences(of: "\u{FFFC}", with: "")
    }
}
