import Foundation
import SwiftSoup

/// Builds the quoted part of a reply or forward from a stored body, in HTML and in plain text.
///
/// The stored `renderedHTML` is tuned for the conversation view (blocked images, `ss-cid` URLs, folding markers);
/// outgoing mail needs the original remote sources back and `cid:` references the MIME builder can match to
/// the inline attachments the composer re-attaches.
public enum ReplyQuoter {
    public static let quoteClass = "ss-reply-quote"
    public static let attributionClass = "ss-reply-attribution"
    public static let forwardHeaderClass = "ss-forward-header"

    /// "On <date>, <name> wrote:" followed by the original body in a blockquote.
    public static func quotedReplyHTML(original: StoredBody, from: EmailAddress?, date: Date, locale: Locale = .current) -> String {
        let header = HTMLEscaping.escape(attributionLine(from: from, date: date, locale: locale))
        return "<div class=\"\(attributionClass)\">\(header)</div>"
            + "<blockquote class=\"\(quoteClass)\" type=\"cite\" style=\"margin:0 0 0 0.8ex;border-left:1px solid #cccccc;padding-left:1ex\">"
            + outgoingHTML(from: original.renderedHTML)
            + "</blockquote>"
    }

    /// The plain-text alternative of `quotedReplyHTML`: the attribution line and every original line prefixed with "> ".
    public static func quotedReplyText(original: StoredBody, from: EmailAddress?, date: Date, locale: Locale = .current) -> String {
        let lines = originalText(of: original).split(separator: "\n", omittingEmptySubsequences: false)
        let quoted = lines.map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        return attributionLine(from: from, date: date, locale: locale) + "\n" + quoted
    }

    /// Outlook-style forward: a rule, the From/Sent/To/Subject block, then the original body.
    public static func forwardHTML(original: StoredBody, subject: String, from: EmailAddress?, to: [EmailAddress], date: Date, locale: Locale = .current) -> String {
        let fields = forwardFields(subject: subject, from: from, to: to, date: date, locale: locale)
        let rows = fields.map { "<b>\(HTMLEscaping.escape($0.label))</b> \(HTMLEscaping.escape($0.value))" }.joined(separator: "<br>")
        return "<div class=\"\(forwardHeaderClass)\"><hr style=\"border:none;border-top:1px solid #e1e1e1;margin:12px 0\">"
            + "<div>\(rows)</div><br></div>"
            + "<div class=\"ss-forward-body\">" + outgoingHTML(from: original.renderedHTML) + "</div>"
    }

    /// The plain-text alternative of `forwardHTML`.
    public static func forwardText(original: StoredBody, subject: String, from: EmailAddress?, to: [EmailAddress], date: Date, locale: Locale = .current) -> String {
        let fields = forwardFields(subject: subject, from: from, to: to, date: date, locale: locale)
        let header = fields.map { "\($0.label) \($0.value)" }.joined(separator: "\n")
        return "________________________________\n" + header + "\n\n" + originalText(of: original)
    }

    /// Text alternative for composer HTML.
    public static func plainText(forHTML html: String) -> String {
        TextExtractor.plainText(fromHTML: html)
    }

    /// "On Nov 1, 2026 at 4:47 PM, Jane Doe <jane@example.com> wrote:" in the given locale.
    public static func attributionLine(from: EmailAddress?, date: Date, locale: Locale) -> String {
        "On \(format(date, locale: locale, dateStyle: .medium, timeStyle: .short)), \(display(from)) wrote:"
    }

    // MARK: Helpers

    private static func forwardFields(subject: String, from: EmailAddress?, to: [EmailAddress], date: Date, locale: Locale) -> [(label: String, value: String)] {
        [
            ("From:", display(from)),
            ("Sent:", format(date, locale: locale, dateStyle: .full, timeStyle: .short)),
            ("To:", to.map(display).joined(separator: "; ")),
            ("Subject:", subject),
        ]
    }

    private static func display(_ address: EmailAddress?) -> String {
        guard let address else { return "unknown sender" }
        if let name = address.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return "\(name) <\(address.address)>"
        }
        return address.address
    }

    private static func format(_ date: Date, locale: Locale, dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = dateStyle
        formatter.timeStyle = timeStyle
        return formatter.string(from: date)
    }

    private static func originalText(of body: StoredBody) -> String {
        body.plainText.isEmpty ? plainText(forHTML: body.renderedHTML) : body.plainText
    }

    /// Undoes the view-only rewrites of the sanitizer so the quoted markup travels well.
    static func outgoingHTML(from renderedHTML: String) -> String {
        do {
            let document = try SwiftSoup.parseBodyFragment(renderedHTML)
            document.outputSettings().prettyPrint(pretty: false)
            guard let body = document.body() else { return renderedHTML }
            try body.select("style.ss-base").remove()
            try body.select("[\(QuoteDetector.collapsedAttribute)]").removeAttr(QuoteDetector.collapsedAttribute)
            for image in try body.select("img[\(HTMLSanitizer.blockedSourceAttribute)]").array() {
                try image.attr("src", image.attr(HTMLSanitizer.blockedSourceAttribute))
                try image.removeAttr(HTMLSanitizer.blockedSourceAttribute)
            }
            for element in try body.select("[src], [href], [background], [style]").array() {
                for key in ["src", "href", "background", "style"] where element.hasAttr(key) {
                    let value = try element.attr(key)
                    guard value.contains(inlineImagePrefix) else { continue }
                    try element.attr(key, restoreContentIDs(in: value))
                }
            }
            for style in try body.select("style").array() {
                for data in style.dataNodes() where data.getWholeData().contains(inlineImagePrefix) {
                    _ = data.setWholeData(restoreContentIDs(in: data.getWholeData()))
                }
            }
            return try body.html()
        } catch {
            return renderedHTML
        }
    }

    private static let inlineImagePrefix = RenderURLScheme.inlineImage + "://"

    /// `ss-cid://<account>/<message>/<id>` back to `cid:<id>` wherever it appears in `text`.
    static func restoreContentIDs(in text: String) -> String {
        var result = ""
        var remainder = Substring(text)
        while let range = remainder.range(of: inlineImagePrefix) {
            result += remainder[..<range.lowerBound]
            var cursor = range.upperBound
            var separators = 0
            while cursor < remainder.endIndex, separators < 2 {
                if remainder[cursor] == "/" { separators += 1 }
                cursor = remainder.index(after: cursor)
            }
            let idStart = cursor
            while cursor < remainder.endIndex, !isURLDelimiter(remainder[cursor]) { cursor = remainder.index(after: cursor) }
            let encoded = String(remainder[idStart..<cursor])
            result += "cid:" + (encoded.removingPercentEncoding ?? encoded)
            remainder = remainder[cursor...]
        }
        result += remainder
        return result
    }

    private static func isURLDelimiter(_ character: Character) -> Bool {
        character == "\"" || character == "'" || character == ")" || character == "<" || character == ">" || character.isWhitespace
    }
}
