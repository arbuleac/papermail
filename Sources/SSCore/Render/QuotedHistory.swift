import Foundation

/// A message's own words, without the replies it quotes, read from the stored plain text (string work only, no HTML
/// parse). Shared by the calendar's time detector and Help Me Write's context, which both want what the sender wrote
/// rather than the thread they dragged along.
///
/// The stored plain text does not mark quotes: a text/plain body keeps its “>” lines, which are left out, and an HTML
/// body's quote is the text after the line that introduces it (“On 17 Nov 2026, at 15:12, Priya wrote:”, “-----Original
/// Message-----”, Outlook's From:/Sent: header), where reading stops, as it does at a signature's “-- ”. Reader mode
/// folds an HTML message's extracted text at the same line (`historyStart`, spec §5.59).
public enum QuotedHistory {
    /// The words the sender wrote, cut to `limit` UTF-8 bytes without splitting a character.
    public static func ownWords(of plainText: String, limit: Int) -> String {
        var kept: [Substring] = []
        var length = 0
        let lines = plainText.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if isQuoteLine(line) { continue }
            if introducesQuote(lines, at: index, folding: false) { break }
            kept.append(line)
            length += line.utf8.count + 1
            if length >= limit { break }
        }
        return limited(kept.joined(separator: "\n"), to: limit)
    }

    /// The line where the replies a message quotes begin, by the lines that introduce them (an attribution, “-----Original
    /// Message-----”, Outlook's From:/Sent: header); nil when none does. A signature's “-- ” is not one: what follows it is
    /// the sender's own card, which reader mode leaves in sight. Lines starting with “>” are not looked at: a quote marked
    /// that way is `PlainTextRenderer`'s to fold.
    ///
    /// Stricter than where `ownWords` stops reading, because a fold hides what it holds: Outlook's header counts only with
    /// its Subject: line too (a booking's “From: London / To: Edinburgh / Date: 12 December” has none), and Outlook's rule
    /// of underscores only over such a header (a sender's own rule between two parts of a letter is not history).
    public static func historyStart(in lines: [Substring]) -> Int? {
        lines.indices.first { !isQuoteLine(lines[$0]) && introducesQuote(lines, at: $0, folding: true) }
    }

    private static func isQuoteLine(_ line: Substring) -> Bool {
        line.unicodeScalars.first { $0 != " " && $0 != "\t" } == ">"
    }

    /// `folding` is `historyStart`'s stricter reading; without it, `ownWords`'.
    private static func introducesQuote(_ lines: [Substring], at index: Int, folding: Bool) -> Bool {
        // Nearly every line of a long text is none of these, which a look at its ends tells: the separators and the
        // signature start with “-” or “_”, Outlook's header with From:, De: or Von:, and every attribution ends with a
        // colon. Only the few lines left are trimmed, lowercased and matched.
        let scalars = lines[index].unicodeScalars
        guard let first = scalars.first(where: { !isSpace($0) }), let last = scalars.last(where: { !isSpace($0) }) else { return false }
        guard "-_FDV".unicodeScalars.contains(first) || last == ":" || last == "\u{FF1A}" else { return false }
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return false }
        // The signature's “-- ” line: what sits below it is the sender's card, not what they wrote.
        if line == "--" { return !folding }
        let lowered = line.lowercased()
        if lowered.hasPrefix(outlookRule) {
            // Outlook's rule over its header; folded only with that header under it.
            guard folding else { return true }
            guard let next = lines.indices[(index + 1)...].prefix(2).first(where: { !isBlank(lines[$0]) }) else { return false }
            return introducesHeader(lines, at: next, folding: true)
        }
        if separatorLines.contains(where: { lowered.hasPrefix($0) }) { return true }
        if introducesHeader(lines, at: index, folding: folding) { return true }
        return QuoteAttribution.isAttributionLine(String(line))
    }

    /// Outlook's header over the message replied to: From, then Sent (or Date) a line or two below, and, for a fold, its
    /// Subject within the next few lines (after To and Cc).
    private static func introducesHeader(_ lines: [Substring], at index: Int, folding: Bool) -> Bool {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("From:") || line.hasPrefix("De:") || line.hasPrefix("Von:") else { return false }
        func below(_ count: Int) -> [String] {
            lines[(index + 1)..<min(lines.count, index + 1 + count)].map { $0.trimmingCharacters(in: .whitespaces) }
        }
        guard below(3).contains(where: { line in headerFields.contains { line.hasPrefix($0) } }) else { return false }
        return !folding || below(6).contains { line in subjectFields.contains { line.hasPrefix($0) } }
    }

    private static func isBlank(_ line: Substring) -> Bool {
        line.unicodeScalars.allSatisfy(isSpace)
    }

    /// White space as `QuoteAttribution` collapses it, the no-break space included.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || scalar == "\u{A0}"
    }

    private static let separatorLines = ["-----original message-----", "----- original message -----"]
    /// Outlook's rule of 32 underscores, drawn over its header in a reply's text.
    private static let outlookRule = "________________________________"
    private static let headerFields = ["Sent:", "Date:", "Envoyé :", "Gesendet:"]
    private static let subjectFields = ["Subject:", "Objet :", "Objet:", "Betreff:"]

    /// `text` cut to `limit` UTF-8 bytes without splitting a character.
    static func limited(_ text: String, to limit: Int) -> String {
        guard text.utf8.count > limit else { return text }
        var end = text.utf8.index(text.utf8.startIndex, offsetBy: max(0, limit))
        while end > text.utf8.startIndex {
            if let cut = String(text.utf8[..<end]) { return cut }
            end = text.utf8.index(before: end)
        }
        return ""
    }
}
