import Foundation

/// Turns a text/plain body into the render-ready HTML shape the sanitizer produces for HTML bodies: escaped,
/// line breaks preserved, URLs and addresses clickable, ">"-quoted blocks folded like HTML quotes.
public enum PlainTextRenderer {
    /// Inner HTML for the body (the sanitizer adds the `ss-body` wrapper) and whether a quote block was found.
    public static func render(_ text: String) -> (html: String, hasQuotedContent: Bool) {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        var hasQuote = false
        let html = renderBlock(lines[...], topLevel: true, hasQuote: &hasQuote)
        return (html, hasQuote)
    }

    /// Escapes `text` and wraps http(s) URLs and email addresses in anchors.
    public static func linkify(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var html = ""
        var textStart = 0
        var index = 0
        while index < scalars.count {
            if let end = urlEnd(in: scalars, at: index) {
                html += escaped(scalars[textStart..<index])
                let url = escaped(scalars[index..<end])
                html += "<a href=\"\(url)\">\(url)</a>"
                index = end
                textStart = end
                continue
            }
            if let end = emailEnd(in: scalars, at: index) {
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

    private static func renderBlock(_ lines: ArraySlice<String>, topLevel: Bool, hasQuote: inout Bool) -> String {
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
            html += renderLines(normal)
            normal.removeAll()
            hasQuote = true
            var block = attribution.map { renderLine($0) + "<br>" } ?? ""
            block += "<blockquote>" + renderBlock(quoted[...], topLevel: false, hasQuote: &hasQuote) + "</blockquote>"
            html += topLevel ? "<div class=\"ss-quote\" data-ss-collapsed=\"true\">" + block + "</div>" : block
            index = cursor
        }
        html += renderLines(normal)
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

    private static func renderLines(_ lines: [String]) -> String {
        lines.map(renderLine).joined(separator: "<br>")
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
        while end < scalars.count, !isURLTerminator(scalars[end]) { end += 1 }
        while end > schemeEnd {
            let last = scalars[end - 1]
            if last == ")" {
                // "(see https://en.wikipedia.org/wiki/Foo_(bar))": a balanced parenthesis belongs to the URL.
                let opens = scalars[index..<end].filter { $0 == "(" }.count
                let closes = scalars[index..<end].filter { $0 == ")" }.count
                if closes <= opens { break }
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
