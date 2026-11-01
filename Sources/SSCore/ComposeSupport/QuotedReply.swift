import Foundation
import SwiftSoup

/// Builds the quoted original that follows a reply or forward: an attribution header plus the stored
/// render-ready HTML, in both HTML and plain-text forms.
///
/// The stored HTML was prepared for the conversation view (remote images parked in `data-ss-src`,
/// inline images pointed at `ss-cid://`). Recipients cannot resolve either, so the quote restores
/// `src` for remote images and turns inline references back into `cid:` URLs; the composer re-attaches
/// the matching inline parts so those references resolve again.
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

    public static let quoteClass = "ss-reply-quote"
    public static let headerClass = "ss-reply-header"
    public static let forwardHeaderClass = "ss-forward-header"
    public static let forwardBodyClass = "ss-forward-body"

    public static func reply(original: MessageMetadata, body: StoredBody, locale: Locale = .current, timeZone: TimeZone = .current) -> Rendering {
        let date = headerDate(original.date, locale: locale, timeZone: timeZone)
        let author = displayString(original.from)
        let headerText = "On \(date), \(author) wrote:"
        let html = "<div class=\"\(headerClass)\">" + ComposerHTMLExporter.escape(headerText) + "</div>"
            + "<blockquote class=\"\(quoteClass)\">" + sendableHTML(body.renderedHTML) + "</blockquote>"
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
        html += "</div><br><div class=\"\(forwardBodyClass)\">" + sendableHTML(body.renderedHTML) + "</div>"

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

    /// Undoes the view-time image rewrites so the quote survives the trip to a recipient.
    public static func sendableHTML(_ renderedHTML: String) -> String {
        guard renderedHTML.contains("data-ss-src") || renderedHTML.contains("ss-cid://") else { return renderedHTML }
        do {
            let document = try SwiftSoup.parseBodyFragment(renderedHTML)
            document.outputSettings().prettyPrint(pretty: false)
            for image in try document.select("img[data-ss-src]") {
                let remote = try image.attr("data-ss-src")
                try image.attr("src", remote)
                try image.removeAttr("data-ss-src")
            }
            for image in try document.select("img[src^=ss-cid://]") {
                let source = try image.attr("src")
                if let contentID = source.split(separator: "/").last.map(String.init), !contentID.isEmpty {
                    try image.attr("src", "cid:" + contentID)
                }
            }
            return try document.body()?.html() ?? renderedHTML
        } catch {
            return renderedHTML
        }
    }
}
