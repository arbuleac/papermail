import Foundation

/// Reader mode's text (spec §5.59): which text version of a message the reader shows in place of its HTML, and that text
/// set on the reading page. String work only, never an HTML parse, so a message opens in reader mode as fast as with its
/// design, and nothing the sender's HTML names is ever asked for.
///
/// The choice, in order:
/// 1. the sender's own text/plain part, unless it is a placeholder (`isPlaceholder`);
/// 2. the plain text the sanitizer extracted from the HTML at sync time (`StoredBody.plainText`), which Keep mail on this
///    Mac keeps when it evicts a body;
/// 3. the snippet, as the reader shows while a body loads.
///
/// A text/plain message has no HTML to replace: its text is its text part, evicted or not.
public enum ReaderText {
    /// Where the shown text comes from.
    public enum Source: String, Codable, Sendable {
        /// The sender's text/plain part, a text/plain message's only part included.
        case text
        /// The text the sanitizer extracted from the HTML when the body was stored.
        case extracted
        /// Neither has any words: the provider's snippet.
        case snippet
    }

    public struct Choice: Hashable, Sendable {
        public var source: Source
        public var text: String

        public init(source: Source, text: String) {
            self.source = source
            self.text = text
        }
    }

    // MARK: Thresholds

    // Lengths are UTF-8 bytes, which Swift counts without walking the text (characters, in ASCII). Tuned on the
    // fixtures in `ReaderTextTests`: mailers that write a real alternative write one about as long as the HTML's words
    // (within a third either way, the HTML side longer for its link targets and image names), while a placeholder is a
    // line or two however long the design is.

    /// A text part shorter than a quarter of the extracted text is not the message…
    static let shortFraction = 4
    /// …once the extracted text is long enough to say so: a short note's two versions can differ by a greeting.
    static let shortFloor = 400
    /// A text part under this many bytes that says one of `placeholderLines` is the sender saying “look at the HTML”.
    static let phraseCeiling = 600

    /// What a placeholder text part says, lowercased, with curly apostrophes and hyphens as the comparison writes them.
    static let placeholderLines = [
        "view this email in your browser", "view this email in a browser", "view this email in a web browser",
        "view this message in your browser", "view this message in a browser", "open this email in your browser",
        "view it in your browser", "view in browser", "view in your browser", "view this email online", "view email online",
        "view the web version", "view web version", "web version of this email", "view as a web page", "view as webpage",
        "your email client does not support html", "your email client doesn't support html",
        "your email program does not support html", "your mail client does not support html",
        "your email client cannot display html", "does not support html email", "doesn't support html email",
        "this is a multi part message in mime format", "please use an html compatible email viewer",
        "please use an html compatible email client", "please use an html compatible mail viewer",
        "this email requires html", "this message requires html", "this email is in html format",
        "this message is in html format", "to view this email, please", "to view this message, please",
        "if you are having trouble viewing this email", "if you're having trouble viewing this email",
        "having trouble viewing this email", "having trouble reading this email", "if you cannot see this email",
        "if you can't see this email", "if this email does not display correctly", "if this email doesn't display correctly",
        "if this message does not display correctly", "trouble seeing this email", "can't see this email",
        "an html viewer is required", "html email viewer",
        // “e-mail”, as the comparison writes it.
        "view this e mail in your browser", "having trouble viewing this e mail", "your e mail client does not support html",
    ]

    // MARK: Choosing

    /// The text reader mode shows for a message with `body` (nil while it has none), else its `snippet`. `body` may be an
    /// evicted one (`MailStoring.keptBody(for:)`): its source is gone, its plain text and design facts stay.
    public static func choose(_ body: StoredBody?, snippet: String) -> Choice {
        guard let body else { return Choice(source: .snippet, text: snippet) }
        let part = body.body.text ?? ""
        let hasHTML = !(body.body.html ?? "").allSatisfy(\.isWhitespace)
        if !hasHTML, !isBlank(part) {
            // A text/plain message: the part is the whole message.
            return Choice(source: .text, text: part)
        }
        if hasHTML, !isPlaceholder(part, extracted: body.plainText) {
            return Choice(source: .text, text: part)
        }
        if !isBlank(body.plainText) {
            // An evicted text/plain message kept its text as its plain text; nothing came from a design.
            let wasPlain = !hasHTML && body.typesetting == .plain
            return Choice(source: wasPlain ? .text : .extracted, text: body.plainText)
        }
        return Choice(source: .snippet, text: snippet)
    }

    /// A text part stands in for the HTML rather than being the message: blank; much shorter than the text the HTML
    /// holds (under a quarter of it, once that is over `shortFloor`); or short and saying one of `placeholderLines`
    /// (“View this email in your browser”).
    public static func isPlaceholder(_ part: String, extracted: String) -> Bool {
        if isBlank(part) { return true }
        let length = part.utf8.count
        let extractedLength = extracted.utf8.count
        if extractedLength > shortFloor, length * shortFraction < extractedLength { return true }
        guard length < phraseCeiling else { return false }
        let said = comparable(part)
        return placeholderLines.contains { said.contains($0) }
    }

    /// Lowercased with curly apostrophes straight, hyphens as spaces and runs of white space as one space.
    static func comparable(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.lowercased().unicodeScalars {
            let mapped: Unicode.Scalar = scalar == "\u{2019}" || scalar == "\u{2018}" ? "'" : (scalar == "-" ? " " : scalar)
            if mapped.properties.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(mapped)
        }
        return String(out)
    }

    private static func isBlank(_ text: String) -> Bool {
        text.allSatisfy { $0.isWhitespace }
    }

    // MARK: Setting

    /// The inner HTML of the reading page's plain body for `text` (`PlainTextRenderer`'s paragraphs and links), and whether
    /// it holds quoted text. ">" quotes fold as in any text/plain mail. Text without them (an HTML message's extracted
    /// text, Outlook's own text part) folds its quoted history at the line `QuotedHistory.historyStart` finds, the
    /// attribution above the quote as `PlainTextRenderer` sets it, so the reply's own words show and the history sits
    /// behind the elision mark. Text whose every line is history shows whole: a fold with nothing above it would hide the
    /// message.
    public static func render(_ text: String) -> (html: String, hasQuotedContent: Bool) {
        // Looked at before anything is set, so a long text is set once (200 KB is set inside the open budget).
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        let marked = lines.contains { line in line.unicodeScalars.first { $0 != " " } == ">" }
        guard !marked, let start = QuotedHistory.historyStart(in: lines) else { return PlainTextRenderer.render(text) }
        let own = lines[..<start].joined(separator: "\n")
        guard !isBlank(own) else { return PlainTextRenderer.render(text) }
        var history = Array(lines[start...])
        var block = ""
        if QuoteAttribution.isAttributionLine(String(history[0])) {
            block += "<p>" + PlainTextRenderer.renderSingleLine(history[0].trimmingCharacters(in: .whitespaces)) + "</p>"
            history.removeFirst()
        }
        block += "<blockquote>" + PlainTextRenderer.renderNested(history.joined(separator: "\n")) + "</blockquote>"
        let quote = "<div class=\"\(QuoteDetector.quoteClass)\" \(QuoteDetector.collapsedAttribute)=\"true\">" + block + "</div>"
        return (PlainTextRenderer.render(own).html + quote, true)
    }
}
