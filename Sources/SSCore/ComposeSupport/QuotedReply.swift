import Foundation
import SwiftSoup

/// Builds the quoted original that follows a reply or forward: an attribution header plus the stored
/// render-ready HTML, in both HTML and plain-text forms.
///
/// The stored HTML was prepared for the conversation view (remote images parked in `data-ss-src`,
/// inline images pointed at `ss-cid://`, `<style>` blocks kept for a sandboxed iframe). Recipients cannot
/// resolve the first two and nothing fences the third, so the quote restores `src` for remote images,
/// turns inline references back into `cid:` URLs and drops the style blocks; the composer re-attaches the
/// parts the `cid:` references name (see `partsToCarry`) so they resolve again.
public enum QuotedReply {
    public struct Rendering: Hashable, Sendable {
        public var html: String
        public var text: String
        /// The attribution ("On …, X wrote:" or the forward header block) on its own, so a composer can
        /// show it above a preview without re-parsing `text`.
        public var header: String
        /// The original's plain text without quote prefixes, for the same preview.
        public var originalText: String
        public init(html: String, text: String, header: String = "", originalText: String = "") {
            self.html = html
            self.text = text
            self.header = header
            self.originalText = originalText
        }
    }

    /// A part of the original that travels with the quote.
    public struct CarriedPart: Hashable, Sendable {
        public var info: AttachmentInfo
        /// Set when the quote references the part as `cid:`; such a part goes out inline, whatever its
        /// original disposition, so the reference resolves again. Without it the part is a plain attachment.
        public var contentID: String?
        public init(info: AttachmentInfo, contentID: String? = nil) {
            self.info = info
            self.contentID = contentID
        }
    }

    public static let quoteClass = "ss-reply-quote"
    public static let headerClass = "ss-reply-header"
    public static let forwardHeaderClass = "ss-forward-header"
    public static let forwardBodyClass = "ss-forward-body"

    public static func reply(original: MessageMetadata, body: StoredBody, locale: Locale = .current, timeZone: TimeZone = .current) -> Rendering {
        let date = headerDate(original.date, locale: locale, timeZone: timeZone)
        let author = displayString(original.from)
        let headerText = "On \(date), \(author) wrote:"
        let html = "<div class=\"\(headerClass)\">" + ComposerHTMLExporter.escape(headerText) + "</div>"
            + "<blockquote class=\"\(quoteClass)\">" + sendableHTML(body.renderedHTML, of: original.id) + "</blockquote>"
        let text = headerText + "\n" + quotePlainText(body.plainText)
        return Rendering(html: html, text: text, header: headerText, originalText: body.plainText)
    }

    public static func forward(original: MessageMetadata, body: StoredBody, locale: Locale = .current, timeZone: TimeZone = .current) -> Rendering {
        var fields: [(label: String, value: String)] = [
            ("From", displayString(original.from)),
            ("Date", headerDate(original.date, locale: locale, timeZone: timeZone)),
            ("Subject", original.subject),
            ("To", original.to.map(displayString).joined(separator: ", ")),
        ]
        if !original.cc.isEmpty {
            fields.append(("Cc", original.cc.map(displayString).joined(separator: ", ")))
        }
        let rule = "---------- Forwarded message ----------"
        var html = "<div class=\"\(forwardHeaderClass)\">" + rule + "<br>"
        html += fields.map { "<b>\($0.label):</b> " + ComposerHTMLExporter.escape($0.value) }.joined(separator: "<br>")
        html += "</div><br><div class=\"\(forwardBodyClass)\">" + sendableHTML(body.renderedHTML, of: original.id) + "</div>"

        let headerText = rule + "\n" + fields.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
        let text = headerText + "\n\n" + body.plainText
        return Rendering(html: html, text: text, header: headerText, originalText: body.plainText)
    }

    /// "Nov 1, 2026 at 10:04" in the user's locale: readable, and recognizable to other clients' quote detectors.
    public static func headerDate(_ date: Date, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func displayString(_ address: EmailAddress?) -> String {
        guard let address else { return "" }
        if let name = address.name, !name.isEmpty, name != address.address {
            return "\(name) <\(address.address)>"
        }
        return address.address
    }

    /// Every line prefixed with "> ", the convention plain-text readers fold.
    public static func quotePlainText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ">" }
        return trimmed.components(separatedBy: "\n").map { line in
            line.isEmpty ? ">" : "> " + line
        }.joined(separator: "\n")
    }

    /// Undoes the view-time image rewrites so the quote survives the trip to a recipient, and removes the
    /// `<style>` blocks the sanitizer keeps for the viewer: there a sandboxed iframe confines them, but in
    /// the outgoing message they would restyle, or hide, what the user typed above the quote, and could
    /// hide the attribution so the quoted words read as the replier's own. Inline styles stay; they only
    /// reach the elements that carry them.
    ///
    /// `message` is the quoted message; with it known, an inline reference is resolved by stripping the
    /// exact `ss-cid://` prefix, which keeps Content-IDs that contain a slash intact.
    public static func sendableHTML(_ renderedHTML: String, of message: MessageID? = nil) -> String {
        guard renderedHTML.contains("data-ss-src") || renderedHTML.contains("ss-cid://")
            || renderedHTML.range(of: "<style", options: .caseInsensitive) != nil else { return renderedHTML }
        do {
            let document = try SwiftSoup.parseBodyFragment(renderedHTML)
            document.outputSettings().prettyPrint(pretty: false)
            try document.select("style").remove()
            for image in try document.select("img[data-ss-src]") {
                let remote = try image.attr("data-ss-src")
                try image.attr("src", remote)
                try image.removeAttr("data-ss-src")
            }
            // The sanitizer points every cid: reference at ss-cid://, not only <img src>: backgrounds, links
            // and CSS url() too. Each goes back to cid:, or recipients get dead URLs naming internal ids.
            for element in try document.select("[src*=ss-cid:], [href*=ss-cid:], [background*=ss-cid:], [style*=ss-cid:]") {
                for key in ["src", "href", "background", "style"] where element.hasAttr(key) {
                    let value = try element.attr(key)
                    guard value.contains(inlinePrefix) else { continue }
                    try element.attr(key, restoringContentIDs(in: value, of: message))
                }
            }
            return try document.body()?.html() ?? renderedHTML
        } catch {
            return renderedHTML
        }
    }

    private static let inlinePrefix = RenderURLScheme.inlineImage + "://"

    /// Every `ss-cid://…` URL inside `value` (an attribute, or CSS with several `url()`s) turned back into
    /// `cid:<id>`. A URL ends at a quote, a closing parenthesis or whitespace, which a percent-encoded id
    /// never contains.
    static func restoringContentIDs(in value: String, of message: MessageID?) -> String {
        var result = ""
        var remainder = Substring(value)
        while let range = remainder.range(of: inlinePrefix) {
            result += remainder[..<range.lowerBound]
            var end = range.lowerBound
            while end < remainder.endIndex, !isURLDelimiter(remainder[end]) { end = remainder.index(after: end) }
            let url = String(remainder[range.lowerBound..<end])
            if let contentID = inlineContentID(from: url, of: message) {
                result += "cid:" + contentID
            }
            remainder = remainder[end...]
        }
        result += remainder
        return result
    }

    private static func isURLDelimiter(_ character: Character) -> Bool {
        character == "\"" || character == "'" || character == ")" || character == "<" || character == ">" || character.isWhitespace
    }

    /// The Content-ID an `ss-cid://` URL carries. `RenderURLScheme.inlineImageURL` percent-encodes it (a
    /// space, `%`, `#`, `?` or braces are legal in a msg-id but not in a URL path), so it is decoded again.
    static func inlineContentID(from source: String, of message: MessageID?) -> String? {
        let prefix = message.map { RenderURLScheme.inlineImageURL(for: $0, contentID: "").absoluteString }
        let encoded: Substring
        if let prefix, source.hasPrefix(prefix) {
            encoded = source.dropFirst(prefix.count)
        } else {
            encoded = source.split(separator: "/").last ?? ""
        }
        guard !encoded.isEmpty, let decoded = String(encoded).removingPercentEncoding, !decoded.isEmpty else { return nil }
        return decoded
    }

    // MARK: Parts of the original

    /// Which of the original's parts travel with the quote. Every part `quotedHTML` references as `cid:`
    /// goes along inline, whatever disposition the sender gave it (Outlook marks referenced images as
    /// attachments), so the reference resolves again; a forward also carries every other part as a regular
    /// attachment, "inline" ones nothing refers to included, while a reply carries nothing else.
    public static func partsToCarry(from parts: [AttachmentInfo], quotedHTML: String, isForward: Bool) -> [CarriedPart] {
        parts.compactMap { part in
            if let contentID = part.contentID, references(contentID: contentID, in: quotedHTML) {
                return CarriedPart(info: part, contentID: contentID)
            }
            return isForward ? CarriedPart(info: part) : nil
        }
    }

    /// True when `html` holds a `cid:` reference to exactly this id, not merely to one it is a prefix of.
    static func references(contentID: String, in html: String) -> Bool {
        // Attribute values come back from the serializer entity-escaped, so an id holding `&` or `"` is
        // looked for in that form too.
        let ids = Set([contentID, ComposerHTMLExporter.escape(contentID)])
        for id in ids {
            let needle = "cid:" + id
            var searchRange = html.startIndex..<html.endIndex
            while let found = html.range(of: needle, range: searchRange) {
                let rest = html[found.upperBound...]
                if rest.isEmpty || endsReference(rest[rest.startIndex]) { return true }
                // Inside a style attribute the serializer writes `url("cid:x")` as `url(&quot;cid:x&quot;)`.
                if rest.hasPrefix("&quot;") || rest.hasPrefix("&#39;") { return true }
                searchRange = found.upperBound..<html.endIndex
            }
        }
        return false
    }

    private static func endsReference(_ character: Character) -> Bool {
        character == "\"" || character == "'" || character == ")" || character.isWhitespace
    }
}
