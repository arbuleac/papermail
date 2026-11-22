import Foundation

/// Turns a text/plain body into the render-ready HTML shape the sanitizer produces for HTML bodies: escaped,
/// URLs and addresses clickable, ">"-quoted blocks folded like HTML quotes.
///
/// Lines separated by blank lines become `<p>` paragraphs, so the reading page's 12 pt paragraph gap spaces
/// them (spec §5.14) instead of an empty 24 pt line; lines inside a paragraph keep their breaks as `<br>`.
/// Runs of blank lines are one paragraph break. No newline is written between elements: the plain body is set
/// `white-space: pre-wrap`, where one would show as an extra line. The only markup is the renderer's own
/// (`p`, `br`, `blockquote`, the quote wrapper and linkified anchors); every character of the text is escaped.
///
/// Bodies stored before paragraphs were introduced keep their `<br><br>` shape, since opening a message never
/// re-renders it; they read as before until they are fetched again.
public enum PlainTextRenderer {
    /// Inner HTML for the body (the sanitizer adds the `ss-body` wrapper) and whether a quote block was found.
    public static func render(_ text: String) -> (html: String, hasQuotedContent: Bool) {
        var hasQuote = false
        let html = renderBlock(lines(of: text)[...], depth: 0, hasQuote: &hasQuote)
        return (html, hasQuote)
    }

    /// Inner HTML for text that already sits inside a fold (reader mode's quoted history, spec §5.59): paragraphs, links and
    /// ">" blocks as `render` sets them, but no block of its own folds, so the history folds once, as a whole.
    public static func renderNested(_ text: String) -> String {
        var hasQuote = false
        return renderBlock(lines(of: text)[...], depth: 1, hasQuote: &hasQuote)
    }

    /// One line as a paragraph's line is set: leading indentation kept, every character escaped, links made.
    public static func renderSingleLine(_ line: String) -> String {
        renderLine(line)
    }

    private static func lines(of text: String) -> [String] {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
    }

    /// Escapes `text` and wraps http(s) URLs and email addresses in anchors.
    public static func linkify(_ text: String) -> String {
        // A link needs “://” and an address “@”: text with neither colon nor at sign (most lines of a letter) is escaped
        // whole, without walking it scalar by scalar.
        let hasColon = text.utf8.contains(UInt8(ascii: ":"))
        let hasAt = text.utf8.contains(UInt8(ascii: "@"))
        guard hasColon || hasAt else { return HTMLEscaping.escape(text) }
        let scalars = Array(text.unicodeScalars)
        var html = ""
        var textStart = 0
        var index = 0
        while index < scalars.count {
            // A link can start only at an “h”, and an address only in text that has an “@”.
            let scalar = scalars[index]
            if hasColon, scalar == "h" || scalar == "H", let end = urlEnd(in: scalars, at: index) {
                html += escaped(scalars[textStart..<index])
                let url = escaped(scalars[index..<end])
                html += "<a href=\"\(url)\">\(url)</a>"
                index = end
                textStart = end
                continue
            }
            if hasAt, let end = emailEnd(in: scalars, at: index) {
                html += escaped(scalars[textStart..<index])
                let address = escaped(scalars[index..<end])
                html += "<a href=\"mailto:\(address)\">\(address)</a>"
                index = end
                textStart = end
                continue
            }
            index += 1
        }
        html += escaped(scalars[textStart...])
        return html
    }

    // MARK: Blocks

    /// Quote levels nest by recursion; past this the remaining ">" markers are shown as text. A line of
    /// 20,000 ">" would otherwise overflow the 512 KB stack of the concurrency pool thread sanitizing it.
    static let maxQuoteDepth = 32

    private static func renderBlock(_ lines: ArraySlice<String>, depth: Int, hasQuote: inout Bool) -> String {
        guard depth < maxQuoteDepth else { return renderParagraphs(Array(lines)) }
        let topLevel = depth == 0
        var html = ""
        var normal: [String] = []
        var index = lines.startIndex
        while index < lines.endIndex {
            guard isQuoteLine(lines[index]) else {
                normal.append(lines[index])
                index += 1
                continue
            }
            var quoted: [String] = []
            var cursor = index
            while cursor < lines.endIndex {
                let line = lines[cursor]
                if isQuoteLine(line) {
                    quoted.append(stripQuoteLevel(line))
                    cursor += 1
                    continue
                }
                // Blank lines belong to the quote only when more quoted lines follow them.
                guard isBlank(line) else { break }
                var lookahead = cursor
                while lookahead < lines.endIndex, isBlank(lines[lookahead]) { lookahead += 1 }
                guard lookahead < lines.endIndex, isQuoteLine(lines[lookahead]) else { break }
                quoted.append(contentsOf: Array(repeating: "", count: lookahead - cursor))
                cursor = lookahead
            }
            let attribution = takeAttribution(from: &normal)
            html += renderParagraphs(normal)
            normal.removeAll()
            hasQuote = true
            var block = attribution.map { "<p>" + renderLine($0) + "</p>" } ?? ""
            block += "<blockquote>" + renderBlock(quoted[...], depth: depth + 1, hasQuote: &hasQuote) + "</blockquote>"
            html += topLevel ? "<div class=\"ss-quote\" data-ss-collapsed=\"true\">" + block + "</div>" : block
            index = cursor
        }
        html += renderParagraphs(normal)
        return html
    }

    /// Pulls the "On <date>, <name> wrote:" line (and the blank lines after it) off the end of `normal`.
    private static func takeAttribution(from normal: inout [String]) -> String? {
        var cut = normal.count
        while cut > 0, isBlank(normal[cut - 1]) { cut -= 1 }
        guard cut > 0, QuoteAttribution.isAttributionLine(normal[cut - 1]) else { return nil }
        let attribution = normal[cut - 1]
        normal.removeSubrange((cut - 1)...)
        return attribution
    }

    /// A run of non-blank lines is one paragraph, its lines joined by `<br>`; blank lines only end paragraphs,
    /// so leading, trailing and repeated blank lines leave no empty `<p>`.
    private static func renderParagraphs(_ lines: [String]) -> String {
        var html = ""
        var paragraph: [String] = []
        func close() {
            guard !paragraph.isEmpty else { return }
            html += "<p>" + paragraph.map(renderLine).joined(separator: "<br>") + "</p>"
            paragraph.removeAll()
        }
        for line in lines {
            if isBlank(line) { close() } else { paragraph.append(line) }
        }
        close()
        return html
    }

    private static func renderLine(_ line: String) -> String {
        var scalars = line.unicodeScalars[...]
        var leading = ""
        // Leading indentation would collapse in HTML; non-breaking spaces keep ASCII layouts readable.
        while let first = scalars.first, first == " " || first == "\t" {
            leading += first == "\t" ? "&nbsp;&nbsp;&nbsp;&nbsp;" : "&nbsp;"
            scalars = scalars.dropFirst()
        }
        return leading + linkify(String(scalars))
    }

    private static func isQuoteLine(_ line: String) -> Bool {
        line.unicodeScalars.first { $0 != " " } == ">"
    }

    private static func isBlank(_ line: String) -> Bool {
        line.unicodeScalars.allSatisfy { $0 == " " || $0 == "\t" }
    }

    private static func stripQuoteLevel(_ line: String) -> String {
        var scalars = line.unicodeScalars.drop { $0 == " " }
        scalars = scalars.dropFirst()
        if scalars.first == " " { scalars = scalars.dropFirst() }
        return String(scalars)
    }

    // MARK: Links

    private static func escaped(_ scalars: ArraySlice<Unicode.Scalar>) -> String {
        HTMLEscaping.escape(String(String.UnicodeScalarView(scalars)))
    }

    private static func urlEnd(in scalars: [Unicode.Scalar], at index: Int) -> Int? {
        if index > 0, isAlphanumeric(scalars[index - 1]) { return nil }
        guard let schemeEnd = schemeEnd(in: scalars, at: index) else { return nil }
        var end = schemeEnd
        var opens = 0
        var closes = 0
        while end < scalars.count, !isURLTerminator(scalars[end]) {
            if scalars[end] == "(" { opens += 1 } else if scalars[end] == ")" { closes += 1 }
            end += 1
        }
        // Counted once and kept up to date while trimming: recounting per trimmed ")" was quadratic.
        while end > schemeEnd {
            let last = scalars[end - 1]
            if last == ")" {
                // "(see https://en.wikipedia.org/wiki/Foo_(bar))": a balanced parenthesis belongs to the URL.
                if closes <= opens { break }
                closes -= 1
                end -= 1
                continue
            }
            guard trailingPunctuation.contains(last) else { break }
            end -= 1
        }
        return end > schemeEnd ? end : nil
    }

    /// Index just past "http://" or "https://" when one starts at `index`.
    private static func schemeEnd(in scalars: [Unicode.Scalar], at index: Int) -> Int? {
        var cursor = index
        for expected in "http".unicodeScalars {
            guard cursor < scalars.count, lowercased(scalars[cursor]) == expected else { return nil }
            cursor += 1
        }
        if cursor < scalars.count, lowercased(scalars[cursor]) == "s" { cursor += 1 }
        for expected in "://".unicodeScalars {
            guard cursor < scalars.count, scalars[cursor] == expected else { return nil }
            cursor += 1
        }
        return cursor
    }

    private static func emailEnd(in scalars: [Unicode.Scalar], at index: Int) -> Int? {
        guard isLocalPartScalar(scalars[index]), index == 0 || !isLocalPartScalar(scalars[index - 1]) else { return nil }
        var at = index
        while at < scalars.count, isLocalPartScalar(scalars[at]) { at += 1 }
        guard at < scalars.count, scalars[at] == "@" else { return nil }
        let domainStart = at + 1
        var end = domainStart
        while end < scalars.count, isDomainScalar(scalars[end]) { end += 1 }
        while end > domainStart, scalars[end - 1] == "." || scalars[end - 1] == "-" { end -= 1 }
        let domain = scalars[domainStart..<end]
        guard domain.first != ".", let lastDot = domain.lastIndex(of: "."), lastDot > domainStart else { return nil }
        let tld = domain[(lastDot + 1)...]
        guard tld.count >= 2, tld.allSatisfy(URLPolicy.isASCIILetter) else { return nil }
        return end
    }

    private static let trailingPunctuation: Set<Unicode.Scalar> = [".", ",", ";", ":", "!", "?", "]", "}", "'", "\""]

    private static func isURLTerminator(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.value < 0x21 { return true }
        switch scalar {
        case "<", ">", "\"", "'", "`", "{", "}", "|", "\\", "^": return true
        default: return scalar.properties.isWhitespace
        }
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        URLPolicy.isASCIILetter(scalar) || URLPolicy.isASCIIDigit(scalar)
    }

    private static func isLocalPartScalar(_ scalar: Unicode.Scalar) -> Bool {
        isAlphanumeric(scalar) || scalar == "." || scalar == "_" || scalar == "%" || scalar == "+" || scalar == "-"
    }

    private static func isDomainScalar(_ scalar: Unicode.Scalar) -> Bool {
        isAlphanumeric(scalar) || scalar == "." || scalar == "-"
    }

    private static func lowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard scalar.value >= 0x41, scalar.value <= 0x5A, let lower = Unicode.Scalar(scalar.value + 0x20) else { return scalar }
        return lower
    }
}
