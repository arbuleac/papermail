import Foundation
import SwiftSoup

/// An event's notes (Google's `description`, Graph's `body`) as plain text with the links kept from them, read once at
/// sync time (docs/ARCHITECTURE.md, "Rendering" › Event notes). Written for this, never bent from the reader's
/// sanitizer: nothing in the notes is ever loaded or shown as HTML, so images, styles, scripts, frames and forms are
/// dropped with their content, and only https and tel links survive (`EventLinkPolicy`); any other scheme stays text.
/// No data detectors: an address, a bare domain or a phone number written in the text is never made a link.
public enum EventNotesReader {
    /// The most of the source parsed: a description longer than this is someone's whole document.
    public static let maxParsed = 256 * 1024

    /// The notes, nil when there are none (nothing but white space, images or markup).
    public static func notes(from source: String?) -> EventNotes? {
        guard var source, !source.isEmpty else { return nil }
        if source.utf8.count > maxParsed { source = String(decoding: source.utf8.prefix(maxParsed), as: UTF8.self) }
        source = source.replacingOccurrences(of: String(Marker.open), with: "")
            .replacingOccurrences(of: String(Marker.close), with: "")
        var builder = NotesBuilder()
        if isHTML(source) {
            guard let document = try? SwiftSoup.parseBodyFragment(source), let body = document.body() else { return nil }
            builder.walk(body)
        } else {
            builder.appendPlain(source)
        }
        return builder.finish()
    }

    /// HTML when it holds a `<` followed by a letter, `/` or `!`; otherwise plain text (Google's descriptions are often
    /// plain, and a plain one that says “a < b” is not HTML).
    static func isHTML(_ text: String) -> Bool {
        var previousWasOpen = false
        for scalar in text.unicodeScalars {
            if previousWasOpen, scalar == "/" || scalar == "!" || (scalar.isASCII && CharacterSet.letters.contains(scalar)) {
                return true
            }
            previousWasOpen = scalar == "<"
        }
        return false
    }

    /// The meeting ID and passcode written in the notes, for a call whose provider states none (Teams and Zoom
    /// scheduled in Outlook write them as lines of text). The one heuristic: English labels only (`Meeting ID`,
    /// `Meeting number`, `Conference ID`; `Passcode`, `Password`, `Access code`) at a line's start, a colon, and a value
    /// of at most 40 letters, digits, spaces and hyphens. Another language's block shows no rows; the notes keep it.
    public static func callCodes(in text: String) -> (meetingID: String?, passcode: String?) {
        var meetingID: String?
        var passcode: String?
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let label = trimmed[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.count <= 40,
                  value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || $0 == " " || $0 == "-" })
            else { continue }
            if ["meeting id", "meeting number", "conference id"].contains(label), meetingID == nil {
                meetingID = value
            } else if ["passcode", "password", "access code"].contains(label), passcode == nil {
                passcode = value
            }
        }
        return (meetingID, passcode)
    }

    /// The first https link of the notes on a known call host (Zoom or Webex scheduled in Outlook): the call to join
    /// when the event names none. Never another host.
    public static func joinAddress(in notes: EventNotes?) -> String? {
        notes?.links.first { link in
            guard let url = EventLinkPolicy.web(link.url) else { return false }
            return CallService(host: url.host) != nil
        }?.url
    }

    /// Link markers inside the text while it is built, so the clean-up of white space and separators never shifts a
    /// link's range: private-use characters a source could not carry (they are taken out of it first).
    fileprivate enum Marker {
        static let open: Character = "\u{E000}"
        static let close: Character = "\u{E001}"
    }
}

/// Builds the notes' text with each link's text between markers, its address kept in order.
private struct NotesBuilder {
    private var out = ""
    private var urls: [String] = []
    /// Newlines asked for before the next text.
    private var pendingNewlines = 0
    private var pendingSpace = false
    private var linkDepth = 0
    private var preDepth = 0

    private static let skipped: Set<String> = [
        "head", "title", "script", "style", "template", "noscript", "svg", "math", "img", "picture", "source", "video",
        "audio", "iframe", "object", "embed", "link", "meta", "form", "button", "input", "select", "textarea",
    ]
    private static let blocks: Set<String> = [
        "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "table", "ul", "ol", "hr",
        "section", "article", "header", "footer", "dl", "dt", "dd", "center", "address",
    ]

    mutating func walk(_ element: Element) {
        let tag = element.tagName().lowercased()
        if Self.skipped.contains(tag) { return }
        if tag == "br" {
            newline(1)
            return
        }
        let isBlock = Self.blocks.contains(tag)
        if isBlock { newline(tag == "p" || tag == "hr" ? 2 : 1) }
        if tag == "li" {
            flush()
            out += "• "
        }
        if tag == "td" || tag == "th", let parent = element.parent(), parent.children().first() !== element {
            out += "\t"
            pendingSpace = false
        }
        if tag == "pre" { preDepth += 1 }
        if tag == "a", linkDepth == 0, let href = try? element.attr("href"), let url = EventLinkPolicy.checked(href) {
            let text = (try? element.text()) ?? ""
            linkDepth += 1
            flush()
            out.append(EventNotesReader.Marker.open)
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out += href.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                walkChildren(element)
            }
            out.append(EventNotesReader.Marker.close)
            urls.append(url.absoluteString)
            linkDepth -= 1
        } else {
            walkChildren(element)
        }
        if tag == "pre" { preDepth -= 1 }
        if isBlock { newline(tag == "p" || tag == "hr" ? 2 : 1) }
    }

    private mutating func walkChildren(_ element: Element) {
        for node in element.getChildNodes() {
            if let text = node as? TextNode {
                appendHTMLText(text.getWholeText())
            } else if let child = node as? Element {
                walk(child)
            }
        }
    }

    /// Text from HTML: white space collapses as a browser draws it (kept inside `pre`).
    private mutating func appendHTMLText(_ text: String) {
        if preDepth > 0 {
            flush()
            appendLinked(text.replacingOccurrences(of: "\r\n", with: "\n"))
            return
        }
        var collapsed = ""
        var lastWasSpace = false
        for character in text {
            if character.isWhitespace {
                if !lastWasSpace { collapsed.append(" ") }
                lastWasSpace = true
            } else {
                collapsed.append(character)
                lastWasSpace = false
            }
        }
        guard !collapsed.isEmpty else { return }
        if collapsed.hasPrefix(" ") {
            pendingSpace = true
            collapsed.removeFirst()
        }
        let trailing = collapsed.hasSuffix(" ")
        if trailing { collapsed.removeLast() }
        if !collapsed.isEmpty {
            flush()
            appendLinked(collapsed)
        }
        if trailing { pendingSpace = true }
    }

    /// Plain text: its lines kept, runs of spaces folded by `finish`.
    mutating func appendPlain(_ text: String) {
        appendLinked(text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
    }

    /// `text`, with its bare https addresses marked as links, unless it is already inside one.
    private mutating func appendLinked(_ text: String) {
        guard linkDepth == 0 else {
            out += text
            return
        }
        var cursor = text.startIndex
        for range in PlainTextRenderer.linkRanges(in: text) {
            let address = String(text[range])
            guard let url = EventLinkPolicy.checked(address) else { continue }
            out += text[cursor..<range.lowerBound]
            out.append(EventNotesReader.Marker.open)
            out += address
            out.append(EventNotesReader.Marker.close)
            urls.append(url.absoluteString)
            cursor = range.upperBound
        }
        out += text[cursor...]
    }

    private mutating func newline(_ count: Int) {
        pendingNewlines = max(pendingNewlines, count)
        pendingSpace = false
    }

    private mutating func flush() {
        if pendingNewlines > 0 {
            if !out.isEmpty { out += String(repeating: "\n", count: pendingNewlines) }
            pendingNewlines = 0
            pendingSpace = false
        } else if pendingSpace {
            if let last = out.last, !last.isWhitespace { out += " " }
            pendingSpace = false
        }
    }

    /// The text cleaned (runs of spaces folded, separator lines blank, at most one blank line in a row, trimmed), cut to
    /// `EventNotes.maxLength`, and its markers turned into ranges.
    mutating func finish() -> EventNotes? {
        var lines: [String] = []
        for raw in out.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = ""
            var lastWasSpace = false
            for character in raw {
                if character == " " {
                    if !lastWasSpace { line.append(" ") }
                    lastWasSpace = true
                } else {
                    line.append(character)
                    lastWasSpace = false
                }
            }
            line = line.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
            if Self.isSeparator(line) { line = "" }
            if line.isEmpty, lines.last?.isEmpty ?? true { continue }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        var text = lines.joined(separator: "\n")
        guard !Self.visible(text).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        var isCut = false
        if Self.visible(text).utf16.count > EventNotes.maxLength {
            text = Self.cut(text, to: EventNotes.maxLength - 1)
            isCut = true
        }
        // Markers to ranges, in UTF-16 units of the text without them.
        var plain = ""
        var links: [EventNotes.Link] = []
        var openAt: Int?
        var urlIndex = 0
        var length = 0
        for character in text {
            if character == EventNotesReader.Marker.open {
                openAt = length
            } else if character == EventNotesReader.Marker.close {
                if let start = openAt, length > start, urlIndex < urls.count, links.count < EventNotes.maxLinks {
                    links.append(EventNotes.Link(location: start, length: length - start, url: urls[urlIndex]))
                }
                urlIndex += 1
                openAt = nil
            } else {
                plain.append(character)
                length += String(character).utf16.count
            }
        }
        // A link the cut ran through is dropped: its text stays, never half a link.
        if isCut { plain += "…" }
        return EventNotes(text: plain, links: links, isCut: isCut)
    }

    /// A line of ten or more `_`, `-`, `─` or `=` alone: Teams' and Zoom's rules between the notes and the call.
    private static func isSeparator(_ line: String) -> Bool {
        line.count >= 10 && line.allSatisfy { "_-─=".contains($0) }
    }

    private static func visible(_ text: String) -> String {
        text.filter { $0 != EventNotesReader.Marker.open && $0 != EventNotesReader.Marker.close }
    }

    /// The text up to `limit` visible UTF-16 units, cut at the last line or word break before it; a link open at the cut
    /// loses its markers (so it is dropped), and nothing after it is kept.
    private static func cut(_ text: String, to limit: Int) -> String {
        var count = 0
        var end = text.startIndex
        var lastBreak: String.Index?
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let isMarker = character == EventNotesReader.Marker.open || character == EventNotesReader.Marker.close
            let units = isMarker ? 0 : String(character).utf16.count
            if count + units > limit { break }
            count += units
            if character == "\n" || character == " " { lastBreak = index }
            index = text.index(after: index)
            end = index
        }
        var kept = String(text[..<(lastBreak ?? end)])
        // An open marker without its close: the link ran across the cut.
        if let open = kept.lastIndex(of: EventNotesReader.Marker.open),
           kept[open...].firstIndex(of: EventNotesReader.Marker.close) == nil {
            kept.remove(at: open)
        }
        while let last = kept.last, last == " " || last == "\n" { kept.removeLast() }
        return kept
    }
}
