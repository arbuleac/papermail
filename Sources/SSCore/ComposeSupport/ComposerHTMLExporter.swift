import CoreText
import Foundation

/// Converts the composer's attributed string into the simple HTML `OutgoingMessage.html` promises
/// (`div`, `p`, `b`, `i`, `u`, `a`, `ul`/`ol`/`li`, `blockquote`) plus a plain-text alternative.
///
/// Inline styling is read from the standard text-system attributes (font traits, underline, link) through
/// CoreText so this stays AppKit-free; paragraph structure is read from `ComposerBlock.attributeKey`,
/// which the composer stamps on every paragraph before exporting. Anything else (colors, sizes, fonts)
/// is intentionally dropped: the composer promises plain mail, and recipients' clients render it their way.
public struct ComposerHTMLExporter: Sendable {
    public struct Output: Hashable, Sendable {
        public var html: String
        public var text: String
        public init(html: String, text: String) {
            self.html = html
            self.text = text
        }
    }

    public init() {}

    /// Exports `body`; a quoted original (see `QuotedReply`) is appended verbatim after the typed content.
    public func export(_ body: NSAttributedString, appending quoted: QuotedReply.Rendering? = nil) -> Output {
        let paragraphs = self.paragraphs(of: body)
        var html = "<div>"
        var lines: [String] = []

        var index = 0
        while index < paragraphs.count {
            let kind = paragraphs[index].kind
            switch kind {
            case .paragraph:
                html += "<p>" + paragraphs[index].htmlOrBreak + "</p>"
                lines.append(paragraphs[index].text)
                index += 1
            case .bulletItem, .numberedItem:
                let tag = kind == .bulletItem ? "ul" : "ol"
                html += "<\(tag)>"
                var number = 1
                while index < paragraphs.count, paragraphs[index].kind == kind {
                    html += "<li>" + paragraphs[index].html + "</li>"
                    lines.append((kind == .bulletItem ? "- " : "\(number). ") + paragraphs[index].text)
                    number += 1
                    index += 1
                }
                html += "</\(tag)>"
            case .quote:
                html += "<blockquote>"
                while index < paragraphs.count, paragraphs[index].kind == .quote {
                    html += "<p>" + paragraphs[index].htmlOrBreak + "</p>"
                    lines.append("> " + paragraphs[index].text)
                    index += 1
                }
                html += "</blockquote>"
            }
        }
        // An empty body still needs one paragraph so the quote below it does not sit against the top.
        if paragraphs.isEmpty { html += "<p><br></p>" }
        html += "</div>"

        var text = lines.joined(separator: "\n")
        if let quoted {
            html += "\n" + quoted.html
            text += "\n\n" + quoted.text
        }
        return Output(html: html, text: text)
    }

    // MARK: Paragraphs

    private struct Paragraph {
        var kind: ComposerBlock
        var html: String
        var text: String
        var htmlOrBreak: String { html.isEmpty ? "<br>" : html }
    }

    private func paragraphs(of body: NSAttributedString) -> [Paragraph] {
        let string = body.string as NSString
        guard string.length > 0 else { return [] }
        var result: [Paragraph] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: [.byParagraphs, .substringNotRequired]) { _, range, enclosing, _ in
            // The newline carries a paragraph's attributes when it is otherwise empty.
            let probe = enclosing.length > 0 ? enclosing.location : range.location
            let attributes = probe < string.length ? body.attributes(at: probe, effectiveRange: nil) : [:]
            let runs = self.runs(in: body, range: range)
            result.append(Paragraph(kind: ComposerBlock.from(attributes: attributes), html: self.html(for: runs), text: self.text(for: runs)))
        }
        // Foundation does not enumerate the empty paragraph after a trailing newline, yet the editor shows
        // that blank line, and the user typed it on purpose (usually to keep a quote at arm's length).
        let last = string.character(at: string.length - 1)
        if last == 0x0A || last == 0x0D || last == 0x2029 {
            let attributes = body.attributes(at: string.length - 1, effectiveRange: nil)
            result.append(Paragraph(kind: ComposerBlock.from(attributes: attributes), html: "", text: ""))
        }
        return result
    }

    // MARK: Inline runs

    private struct InlineStyle: Equatable {
        var bold = false
        var italic = false
        var underline = false
        var link: String?
    }

    private static let fontKey = NSAttributedString.Key("NSFont")
    private static let underlineKey = NSAttributedString.Key("NSUnderline")
    private static let linkKey = NSAttributedString.Key("NSLink")
    private static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto", "ftp"]

    private func runs(in body: NSAttributedString, range: NSRange) -> [(style: InlineStyle, text: String)] {
        var runs: [(style: InlineStyle, text: String)] = []
        guard range.length > 0 else { return runs }
        let string = body.string as NSString
        body.enumerateAttributes(in: range, options: []) { attributes, runRange, _ in
            let style = self.style(from: attributes)
            let text = string.substring(with: runRange).replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !text.isEmpty else { return }
            if let last = runs.last, last.style == style {
                runs[runs.count - 1].text += text
            } else {
                runs.append((style, text))
            }
        }
        return runs
    }

    private func style(from attributes: [NSAttributedString.Key: Any]) -> InlineStyle {
        var style = InlineStyle()
        if let font = attributes[Self.fontKey] as? NSObject, CFGetTypeID(font) == CTFontGetTypeID() {
            // NSFont is toll-free bridged to CTFont, which lets a Foundation-only module read its traits.
            let traits = CTFontGetSymbolicTraits(unsafeBitCast(font, to: CTFont.self))
            style.bold = traits.contains(.boldTrait)
            style.italic = traits.contains(.italicTrait)
        }
        if let underline = attributes[Self.underlineKey] as? Int, underline != 0 {
            style.underline = true
        }
        style.link = linkTarget(attributes[Self.linkKey])
        return style
    }

    /// Only links a recipient's client can safely open; anything else is exported as plain text.
    private func linkTarget(_ value: Any?) -> String? {
        let candidate: String?
        if let url = value as? URL {
            candidate = url.absoluteString
        } else if let string = value as? String {
            candidate = string
        } else {
            candidate = nil
        }
        guard let candidate, let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              Self.allowedLinkSchemes.contains(scheme) else { return nil }
        return candidate
    }

    private func html(for runs: [(style: InlineStyle, text: String)]) -> String {
        var html = ""
        var index = 0
        while index < runs.count {
            let link = runs[index].style.link
            var inner = ""
            while index < runs.count, runs[index].style.link == link {
                inner += markup(runs[index])
                index += 1
            }
            if let link {
                html += "<a href=\"" + Self.escape(link) + "\">" + inner + "</a>"
            } else {
                html += inner
            }
        }
        return html
    }

    private func markup(_ run: (style: InlineStyle, text: String)) -> String {
        var html = Self.escape(run.text)
            .replacingOccurrences(of: "\u{2028}", with: "<br>")
            .replacingOccurrences(of: "\n", with: "<br>")
        if run.style.underline { html = "<u>" + html + "</u>" }
        if run.style.italic { html = "<i>" + html + "</i>" }
        if run.style.bold { html = "<b>" + html + "</b>" }
        return html
    }

    private func text(for runs: [(style: InlineStyle, text: String)]) -> String {
        var text = ""
        var index = 0
        while index < runs.count {
            let link = runs[index].style.link
            var inner = ""
            while index < runs.count, runs[index].style.link == link {
                inner += runs[index].text
                index += 1
            }
            if let link, inner.trimmingCharacters(in: .whitespaces) != link {
                text += inner + " <" + link + ">"
            } else {
                text += inner
            }
        }
        return text.replacingOccurrences(of: "\u{2028}", with: "\n")
    }

    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}
