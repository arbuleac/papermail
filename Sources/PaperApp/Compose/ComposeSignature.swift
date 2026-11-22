import AppKit
import PaperCore

/// The account signature in the composer (spec §5.20, §5.40): kept by the store as the composer's own HTML subset,
/// set in the editor's writing style, and inserted as ordinary body text, one empty line below the typing point and
/// above the folded original. Nothing else is added (no “-- ” line). The inserted text carries `attributeKey`, a
/// private attribute that only lets the composer find it again when From changes; the user selects, edits and
/// deletes it like any other text, and text typed into it never takes the attribute.
@MainActor
enum ComposeSignature {
    /// Marks the characters the composer inserted as the signature. The value is always `true`.
    static let attributeKey = NSAttributedString.Key("ss.composer.signature")

    /// What sets the signature apart from the typing point: the line break that ends the typing line and one empty line.
    static let separator = "\n\n"

    // MARK: HTML

    /// The signature as body text in the writing style, marked; nil when `html` holds no text.
    static func body(html: String?) -> NSAttributedString? {
        let text = editable(html: html)
        guard hasText(text) else { return nil }
        let marked = NSMutableAttributedString(attributedString: text)
        marked.addAttribute(attributeKey, value: true, range: NSRange(location: 0, length: marked.length))
        return marked
    }

    /// The signature in the writing style without the mark, for the Settings field; empty for none.
    static func editable(html: String?) -> NSAttributedString {
        guard let html else { return NSAttributedString() }
        let paragraphs = ComposerHTMLImporter().paragraphs(from: html)
        let result = NSMutableAttributedString()
        for (index, runs) in paragraphs.enumerated() {
            if index > 0 { result.append(ComposeTextView.plainBody("\n")) }
            for run in runs { result.append(attributed(run)) }
        }
        return result
    }

    /// What the editor holds as the HTML subset the composer sends (`ComposeBodyNormalizer`, then
    /// `ComposerHTMLExporter`, which drops every style the composer cannot send and every link it would not); nil when
    /// it holds nothing but white space.
    static func html(from text: NSAttributedString) -> String? {
        guard hasText(text) else { return nil }
        return ComposerHTMLExporter().export(ComposeBodyNormalizer.normalize(text)).html
    }

    /// The signature as the composer would send it on its own (HTML and its plain-text alternative), for a quick reply
    /// sent from the bar; nil when there is none.
    static func export(html: String?) -> ComposerHTMLExporter.Output? {
        guard let text = body(html: html) else { return nil }
        return ComposerHTMLExporter().export(ComposeBodyNormalizer.normalize(text))
    }

    private static func attributed(_ run: ComposerHTMLImporter.Run) -> NSAttributedString {
        var attributes = ComposeTextView.defaultTypingAttributes
        var font = ComposeTextView.bodyFont
        let manager = NSFontManager.shared
        if run.bold { font = manager.convert(font, toHaveTrait: .boldFontMask) }
        if run.italic { font = manager.convert(font, toHaveTrait: .italicFontMask) }
        attributes[.font] = font
        if run.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if let link = run.link { attributes[.link] = link }
        return NSAttributedString(string: run.text, attributes: attributes)
    }

    private static func hasText(_ text: NSAttributedString) -> Bool {
        !text.string.replacingOccurrences(of: ComposerHTMLImporter.lineSeparator, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // MARK: Finding it

    /// From the first marked character to the last, so text typed inside the signature (which takes no mark) is part
    /// of it; nil once the user has deleted all of it.
    static func range(in text: NSAttributedString) -> NSRange? {
        var first: Int?
        var last = 0
        text.enumerateAttribute(attributeKey, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard value != nil else { return }
            if first == nil { first = range.location }
            last = NSMaxRange(range)
        }
        return first.map { NSRange(location: $0, length: last - $0) }
    }

    /// Where the separator before `signature` starts: back over at most the two line breaks the composer put there.
    static func separatorStart(before signature: NSRange, in text: NSString) -> Int {
        var start = signature.location
        while start > 0, signature.location - start < (separator as NSString).length,
              ComposeTextView.isNewline(text.character(at: start - 1)) {
            start -= 1
        }
        return start
    }

    /// What the user wrote: the body without the signature's marked characters and the separator before it, for
    /// telling a body worth keeping from one that holds only what the composer put there. Text typed inside the
    /// signature takes no mark, so it stays: it is the user's, even though a From change would replace it.
    static func typedText(of body: NSAttributedString) -> String {
        let text = body.string as NSString
        guard let signature = range(in: body) else { return body.string }
        var typed = text.substring(to: separatorStart(before: signature, in: text))
        let rest = NSRange(location: signature.location, length: text.length - signature.location)
        body.enumerateAttribute(attributeKey, in: rest) { value, range, _ in
            if value == nil { typed += text.substring(with: range) }
        }
        return typed
    }

    // MARK: Building a body

    /// A new body: what was typed (a mail link's body, the quick reply's text), then, when there is a signature, one
    /// empty line and the signature. `caret` is the end of the typed text, where the user goes on writing.
    static func startingBody(typed: NSAttributedString?, signature: NSAttributedString?) -> (body: NSAttributedString, caret: Int) {
        let body = NSMutableAttributedString(attributedString: typed ?? NSAttributedString())
        let caret = body.length
        if let signature {
            body.append(ComposeTextView.plainBody(separator))
            body.append(signature)
        }
        return (body, caret)
    }

    /// `typed` added to a body the user already wrote (a kept reply taking the quick reply's text): after what it holds
    /// and one empty line, above its signature when it has one. `caret` is the end of the added text.
    static func adding(_ typed: NSAttributedString, to body: NSAttributedString) -> (body: NSAttributedString, caret: Int) {
        let result = NSMutableAttributedString(attributedString: body)
        let text = body.string as NSString
        let position = range(in: body).map { separatorStart(before: $0, in: text) } ?? text.length
        let insertion = NSMutableAttributedString()
        if position > 0 { insertion.append(ComposeTextView.plainBody(separator)) }
        insertion.append(typed)
        result.insert(insertion, at: position)
        return (result, position + insertion.length)
    }
}
