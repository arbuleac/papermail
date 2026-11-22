import Foundation

/// Reply and forward subject lines that never stack ("Re: Re: Re:") and normalize localized prefixes
/// ("AW:", "RE:", "Fw:") to the two forms every client understands.
///
/// Both operations are idempotent: `reply(reply(s)) == reply(s)`.
public enum SubjectPrefixer {
    public static let replyPrefix = "Re: "
    public static let forwardPrefix = "Fwd: "

    /// Prefixes clients use for replies, lowercased. "Re[2]:" style counters are handled separately.
    static let replyTokens: Set<String> = ["re", "aw", "antw", "sv", "ynt", "odp", "res", "atb", "rif"]
    /// Prefixes clients use for forwards, lowercased.
    static let forwardTokens: Set<String> = ["fwd", "fw", "wg", "tr", "doorst", "enc", "vb"]

    public static func reply(_ subject: String) -> String {
        let rest = strip(subject, tokens: replyTokens)
        return rest.isEmpty ? replyPrefix.trimmingCharacters(in: .whitespaces) : replyPrefix + rest
    }

    public static func forward(_ subject: String) -> String {
        let rest = strip(subject, tokens: forwardTokens)
        return rest.isEmpty ? forwardPrefix.trimmingCharacters(in: .whitespaces) : forwardPrefix + rest
    }

    /// The subject without any leading reply or forward prefixes, for conversation grouping and display.
    public static func stripped(_ subject: String) -> String {
        strip(subject, tokens: replyTokens.union(forwardTokens))
    }

    public static func hasReplyPrefix(_ subject: String) -> Bool {
        leadingPrefix(in: subject.trimmingCharacters(in: .whitespacesAndNewlines), tokens: replyTokens) != nil
    }

    public static func hasForwardPrefix(_ subject: String) -> Bool {
        leadingPrefix(in: subject.trimmingCharacters(in: .whitespacesAndNewlines), tokens: forwardTokens) != nil
    }

    // MARK: Implementation

    private static func strip(_ subject: String, tokens: Set<String>) -> String {
        var rest = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        while let end = leadingPrefix(in: rest, tokens: tokens) {
            rest = String(rest[end...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return rest
    }

    /// The index just past a leading `Token:`, `Token :`, `Token[3]:` or `Token(3):` when the subject has one.
    private static func leadingPrefix(in subject: String, tokens: Set<String>) -> String.Index? {
        var index = subject.startIndex
        var word = ""
        while index < subject.endIndex, subject[index].isLetter {
            word.append(subject[index])
            index = subject.index(after: index)
        }
        guard !word.isEmpty, tokens.contains(word.lowercased()) else { return nil }

        // Optional counter such as "[2]" or "(3)" that some clients append to Re.
        if index < subject.endIndex, subject[index] == "[" || subject[index] == "(" {
            let closing: Character = subject[index] == "[" ? "]" : ")"
            var probe = subject.index(after: index)
            var digits = ""
            while probe < subject.endIndex, subject[probe].isNumber {
                digits.append(subject[probe])
                probe = subject.index(after: probe)
            }
            guard !digits.isEmpty, probe < subject.endIndex, subject[probe] == closing else { return nil }
            index = subject.index(after: probe)
        }

        while index < subject.endIndex, subject[index] == " " {
            index = subject.index(after: index)
        }
        guard index < subject.endIndex, subject[index] == ":" else { return nil }
        return subject.index(after: index)
    }
}
