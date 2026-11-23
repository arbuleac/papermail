import Foundation

/// How a new message's answer carries its subject: a first line `Subject: …`, an empty line, then the message
/// (`write-new-1` asks for exactly that). One line of protocol rather than a second request or a JSON answer: a second
/// request would send twice for one ⌘J, and JSON does not stream through every provider.
///
/// `split` reads the whole answer so far, every time more of it arrives, instead of keeping a state between deltas:
/// providers deliver the text as deltas cut anywhere, as the whole text at once, or as the whole text after deltas, and
/// reading the whole again is right for all three. Only the model's answer is read, so mail cannot forge the line.
public enum WriteSubjectLine {
    public struct Split: Sendable, Hashable {
        /// The first line's words after the marker, trimmed but not yet `cleaned`; nil when the answer has no subject
        /// line, or while its first line has not ended.
        public var subject: String?
        /// The message, to show: the answer without its subject line and the blank space after it. Empty while the
        /// first line is held back.
        public var body: String

        public init(subject: String? = nil, body: String) {
            self.subject = subject
            self.body = body
        }
    }

    /// What the instructions ask the line to start with, whatever language the message is in. A translated marker
    /// (“Betreff:”) is not looked for: guessing at markers would take a message's own first line for a subject.
    static let marker = "subject:"

    /// The longest subject set; a longer one is cut at a word.
    public static let maxLength = 150

    /// Splits `raw`, the answer so far (`final`: all of it).
    ///
    /// The marker counts only at the very start, blank space aside, in any letter case. While the text could still
    /// become a subject line (it is a start of the marker, or the line has not ended) nothing is shown: the body is
    /// empty. Text that cannot be one is all body, at once and unchanged. At the end, a start of the marker that never
    /// finished is body after all, and a subject line with nothing under it is a subject with an empty body, which the
    /// writer reports as nothing written.
    public static func split(_ raw: String, final: Bool) -> Split {
        let scalars = raw.unicodeScalars
        let held = Split(subject: nil, body: final ? raw : "")
        guard var index = scalars.firstIndex(where: { !isBlank($0) }) else { return held }
        for expected in marker.unicodeScalars {
            guard index < scalars.endIndex else { return held }
            guard lowercased(scalars[index]) == expected else { return Split(subject: nil, body: raw) }
            index = scalars.index(after: index)
        }
        let afterMarker = scalars[index...]
        guard let lineEnd = afterMarker.firstIndex(where: isLineBreak) else {
            return final ? Split(subject: trimmed(afterMarker), body: "") : Split(subject: nil, body: "")
        }
        // The empty line under the subject, and any other blank space before the message, is not part of either.
        let below = scalars[lineEnd...]
        let bodyStart = below.firstIndex(where: { !isBlank($0) }) ?? below.endIndex
        return Split(subject: trimmed(afterMarker[..<lineEnd]), body: String(scalars[bodyStart...]))
    }

    /// The subject fit to put in the Subject field, or nil when nothing should be set. It is a model's output on its
    /// way into a header, so: invisible characters go, every control and line-break character becomes a space (the send
    /// path strips only CR and LF), runs of blank space collapse, quotes around the whole and a leading “Re:” or “Fwd:”
    /// go (a new message answers and forwards nothing), and what is left is cut at a word by `maxLength`. A subject
    /// that repeats fence syntax or this request's fence code is dropped whole: the model was echoing its input.
    public static func cleaned(_ subject: String, fence: String) -> String? {
        var text = oneLine(AIRedactor.removingInvisibleCharacters(subject))
        while true {
            let unwrapped = withoutPrefix(withoutQuotes(text))
            if unwrapped == text { break }
            text = unwrapped
        }
        guard !text.isEmpty, !text.contains("<<<") else { return nil }
        if !fence.isEmpty, text.range(of: fence, options: .caseInsensitive) != nil { return nil }
        text = cut(text, to: maxLength)
        return text.isEmpty ? nil : text
    }

    // MARK: Reading

    /// White space of any kind, line breaks included, and the characters that render as nothing.
    private static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || AIRedactor.isInvisible(scalar)
    }

    /// What ends the first line: a line feed or a carriage return, which is how a model breaks a line. The rarer line
    /// separators stay inside the subject, where `cleaned` turns them into spaces.
    private static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" || scalar == "\r"
    }

    private static func lowercased(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard (0x41...0x5A).contains(scalar.value), let lower = Unicode.Scalar(scalar.value + 0x20) else { return scalar }
        return lower
    }

    private static func trimmed(_ scalars: Substring.UnicodeScalarView) -> String {
        String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Cleaning

    /// `text` on one line: control characters and every kind of white space and line break become single spaces, and
    /// the ends are trimmed.
    static func oneLine(_ text: String) -> String {
        var line = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace || scalar.properties.generalCategory == .control {
                pendingSpace = !line.isEmpty
            } else {
                if pendingSpace { line.append(" ") }
                pendingSpace = false
                line.append(scalar)
            }
        }
        return String(line)
    }

    private static let quotePairs: [(open: Character, close: Character)] = [
        ("\"", "\""), ("'", "'"), ("\u{201C}", "\u{201D}"), ("\u{2018}", "\u{2019}"), ("\u{201E}", "\u{201C}"),
        ("\u{201E}", "\u{201D}"), ("\u{00AB}", "\u{00BB}"), ("\u{00BB}", "\u{00AB}"), ("\u{300C}", "\u{300D}"), ("`", "`"),
    ]

    /// Without the quotes a model put around the whole subject. Quotes that open and close parts of it stay:
    /// “"Atlas" and "Borealis"” is not one quoted subject.
    private static func withoutQuotes(_ text: String) -> String {
        guard text.count >= 2, let first = text.first, let last = text.last,
              quotePairs.contains(where: { $0.open == first && $0.close == last }) else { return text }
        let inner = text.dropFirst().dropLast()
        guard !inner.contains(where: { $0 == first || $0 == last }) else { return text }
        return inner.trimmingCharacters(in: .whitespaces)
    }

    private static let prefixes = ["re:", "fwd:", "fw:"]

    private static func withoutPrefix(_ text: String) -> String {
        guard let prefix = prefixes.first(where: { text.prefix($0.count).lowercased() == $0 }) else { return text }
        return text.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }

    /// `text` in at most `limit` characters, ending at a word where one ends in the second half.
    private static func cut(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        var head = String(text.prefix(limit))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) > limit / 2 {
            head = String(head[..<space])
        }
        return head.trimmingCharacters(in: .whitespaces)
    }
}
