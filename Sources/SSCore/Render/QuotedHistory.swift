import Foundation

/// A message's own words, without the replies it quotes, read from the stored plain text (string work only, no HTML
/// parse). Shared by the calendar's time detector and Help Me Write's context, which both want what the sender wrote
/// rather than the thread they dragged along.
///
/// The stored plain text does not mark quotes: a text/plain body keeps its “>” lines, which are left out, and an HTML
/// body's quote is the text after the line that introduces it (“On 17 Nov 2026, at 15:12, Priya wrote:”, “-----Original
/// Message-----”, Outlook's From:/Sent: header), where reading stops, as it does at a signature's “-- ”.
public enum QuotedHistory {
    /// The words the sender wrote, cut to `limit` UTF-8 bytes without splitting a character.
    public static func ownWords(of plainText: String, limit: Int) -> String {
        var kept: [Substring] = []
        var length = 0
        let lines = plainText.split(separator: "\n", omittingEmptySubsequences: false)
        for (index, line) in lines.enumerated() {
            if isQuoteLine(line) { continue }
            if introducesQuote(lines, at: index) { break }
            kept.append(line)
            length += line.utf8.count + 1
            if length >= limit { break }
        }
        return limited(kept.joined(separator: "\n"), to: limit)
    }

    private static func isQuoteLine(_ line: Substring) -> Bool {
        line.unicodeScalars.first { $0 != " " && $0 != "\t" } == ">"
    }

    private static func introducesQuote(_ lines: [Substring], at index: Int) -> Bool {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return false }
        // The signature's “-- ” line: what sits below it is the sender's card, not what they wrote.
        if line == "--" { return true }
        if separatorLines.contains(where: { line.lowercased().hasPrefix($0) }) { return true }
        if line.hasPrefix("From:") || line.hasPrefix("De:") || line.hasPrefix("Von:") {
            // Outlook's header over the message replied to: From, then Sent (or Date) a line or two below.
            let below = lines[(index + 1)..<min(lines.count, index + 4)].map { $0.trimmingCharacters(in: .whitespaces) }
            if below.contains(where: { line in headerFields.contains { line.hasPrefix($0) } }) { return true }
        }
        return QuoteAttribution.isAttributionLine(String(line))
    }

    private static let separatorLines = ["-----original message-----", "----- original message -----", "________________________________"]
    private static let headerFields = ["Sent:", "Date:", "Envoyé :", "Gesendet:"]

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
