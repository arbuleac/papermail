import Foundation
import SwiftSoup

/// Reads the composer's own HTML subset (what `ComposerHTMLExporter` writes) back into paragraphs of styled runs, so
/// text kept as that HTML, such as an account's signature, can be put back into the editor. Pure and AppKit-free:
/// the app turns runs into attributed text in its own writing style.
///
/// It keeps only what the composer can express inline: bold (`b`, `strong`), italic (`i`, `em`), underline (`u`)
/// and links (`a` whose `href` the exporter would also write: http, https, mailto, ftp). Every other element is
/// read for its text alone, and scripts, styles and comments are dropped, so whatever HTML is handed in, what
/// comes out is plain composer text. Lists and quotes come back as plain paragraphs. A `<br>` inside a paragraph
/// is a line separator (U+2028), which the exporter writes back as `<br>`; a paragraph holding nothing but one
/// `<br>` is an empty paragraph, the exporter's form for a blank line.
public struct ComposerHTMLImporter: Sendable {
    public struct Run: Hashable, Sendable {
        public var text: String
        public var bold: Bool
        public var italic: Bool
        public var underline: Bool
        /// The link target, already checked against the exporter's schemes.
        public var link: String?

        public init(text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false, link: String? = nil) {
            self.text = text
            self.bold = bold
            self.italic = italic
            self.underline = underline
            self.link = link
        }

        fileprivate func sameStyle(as other: Run) -> Bool {
            bold == other.bold && italic == other.italic && underline == other.underline && link == other.link
        }
    }

    /// One paragraph: its runs in order, adjacent runs of the same style merged. An empty paragraph is a blank line.
    public typealias Paragraph = [Run]

    public static let lineSeparator = "\u{2028}"

    public init() {}

    /// The paragraphs of `html`; none for empty or unreadable input.
    public func paragraphs(from html: String) -> [Paragraph] {
        guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let document = try? SwiftSoup.parseBodyFragment(html), let body = document.body() else { return [] }
        var builder = Builder()
        builder.walk(body, style: Run(text: ""))
        builder.closeParagraph(keepEmpty: false)
        return builder.paragraphs
    }

    // MARK: Walking

    private struct Builder {
        var paragraphs: [Paragraph] = []
        var current: [Run] = []

        /// Elements that hold paragraphs of their own; their edges end the paragraph being built.
        private static let containers: Set<String> = [
            "body", "div", "blockquote", "ul", "ol", "section", "article", "header", "footer", "table", "tbody", "thead",
            "tr", "td", "th",
        ]
        /// Elements that are one paragraph each, even when empty (`<p><br></p>` is a blank line).
        private static let paragraphs: Set<String> = ["p", "li", "h1", "h2", "h3", "h4", "h5", "h6", "pre"]
        /// Elements whose content is never text the user wrote.
        private static let skipped: Set<String> = ["script", "style", "head", "title", "template", "noscript", "iframe", "object"]

        mutating func walk(_ element: Element, style: Run) {
            for node in element.getChildNodes() {
                if let text = node as? TextNode {
                    // The exporter writes line breaks as `<br>`, so a raw one is markup layout, read as a space.
                    append(text.getWholeText().replacingOccurrences(of: "\r\n", with: " ")
                        .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " "), style: style)
                } else if let child = node as? Element {
                    visit(child, style: style)
                }
            }
        }

        private mutating func visit(_ element: Element, style: Run) {
            let tag = element.tagName().lowercased()
            if Self.skipped.contains(tag) { return }
            var inner = style
            switch tag {
            case "br":
                append(ComposerHTMLImporter.lineSeparator, style: style)
                return
            case "b", "strong":
                inner.bold = true
            case "i", "em":
                inner.italic = true
            case "u":
                inner.underline = true
            case "a":
                let href = (try? element.attr("href")) ?? ""
                inner.link = ComposerHTMLExporter.isAllowedLink(href) ? href : nil
            default:
                break
            }
            if Self.paragraphs.contains(tag) {
                closeParagraph(keepEmpty: false)
                walk(element, style: inner)
                closeParagraph(keepEmpty: true)
            } else if Self.containers.contains(tag) {
                closeParagraph(keepEmpty: false)
                walk(element, style: inner)
                closeParagraph(keepEmpty: false)
            } else {
                walk(element, style: inner)
            }
        }

        private mutating func append(_ text: String, style: Run) {
            guard !text.isEmpty else { return }
            var run = style
            run.text = text
            if let last = current.last, last.sameStyle(as: run) {
                current[current.count - 1].text += text
            } else {
                current.append(run)
            }
        }

        /// Ends the paragraph being built. One that holds nothing but a single line break is the exporter's empty
        /// paragraph. `keepEmpty` is set at the end of a paragraph element, which stays a paragraph (a blank line)
        /// even when it held nothing; anywhere else, text that is only spaces is the layout between elements of
        /// hand-written HTML, not a paragraph.
        mutating func closeParagraph(keepEmpty: Bool) {
            defer { current = [] }
            let text = current.map(\.text).joined()
            if text == ComposerHTMLImporter.lineSeparator {
                paragraphs.append([])
            } else if keepEmpty {
                paragraphs.append(current)
            } else if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                paragraphs.append(current)
            }
        }
    }
}
