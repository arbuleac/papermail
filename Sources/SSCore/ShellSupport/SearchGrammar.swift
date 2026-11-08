import Foundation

extension SearchQuery {
    /// Parses the search field's text (spec §5.6): words, `"quoted phrases"`, the operators `from:`, `to:`,
    /// `subject:`, `is:unread`, `is:read`, `is:starred`, `has:attachment`, `before:` and `after:` (YYYY-MM-DD or
    /// YYYY/MM/DD, local midnight in `timeZone`), `in:inbox`, `in:sent`, `in:drafts`, `in:trash`, `in:all`, and a
    /// leading minus on any of them. Operator names and their keyword values are case-insensitive, and a value may be
    /// quoted (`from:"Ben Carter"`). Nothing is ever an error: an unknown operator or a value an operator does not
    /// take is searched as plain text. Nil for a blank field.
    public init?(parsing text: String, timeZone: TimeZone = .current) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.init(text: trimmed, terms: SearchGrammar.terms(in: trimmed, timeZone: timeZone))
    }
}

/// The lexer and the rules behind `SearchQuery(parsing:)`. Pure, so every case is unit-tested without a store.
enum SearchGrammar {
    /// Operator names, lowercased. Anything else before a colon is part of a word (`re:hello`, `10:30`, a URL).
    static let operatorNames: Set<String> = ["from", "to", "subject", "is", "has", "in", "before", "after"]

    private static let readStates: [String: SearchTerm.Kind] = ["unread": .unread, "read": .read, "starred": .starred]
    private static let hasValues: [String: SearchTerm.Kind] = ["attachment": .attachment]
    private static let mailboxes: [String: MailboxView] = [
        "inbox": .inbox, "sent": .sent, "drafts": .drafts, "trash": .trash, "all": .all,
    ]

    /// One whitespace-separated piece of the text, a quoted run kept whole.
    struct Token: Equatable {
        var negated: Bool
        /// The operator's name, lowercased, when the token is `name:value` with a known name.
        var name: String?
        /// The operator's value, the word, or the phrase without its quotes.
        var value: String
        var quoted: Bool
        /// A quoted token whose closing quote was typed.
        var closed: Bool
        /// The token as typed, without its minus: what is searched when an operator does not take its value.
        var raw: String
    }

    static func terms(in text: String, timeZone: TimeZone) -> [SearchTerm] {
        let tokens = self.tokens(in: text)
        var terms: [SearchTerm] = []
        for (index, token) in tokens.enumerated() {
            // The last token is still being typed unless its quote is closed: a prefix for a word, and an operator
            // value that is the start of one it takes waits to be finished rather than searching as text.
            let open = index == tokens.count - 1 && !(token.quoted && token.closed)
            if let term = term(for: token, open: open, timeZone: timeZone) { terms.append(term) }
        }
        return terms
    }

    private static func term(for token: Token, open: Bool, timeZone: TimeZone) -> SearchTerm? {
        guard let name = token.name else {
            guard isIndexable(token.value) else { return nil }
            return SearchTerm(token.quoted ? .phrase(token.value) : .text(token.value), negated: token.negated,
                              isPrefix: open && !token.negated)
        }
        // An operator with nothing after it yet (`from:`) adds nothing; it is not a word to look for either.
        guard !token.value.isEmpty else { return nil }
        let keyword = token.value.lowercased()
        let kind: SearchTerm.Kind?
        var candidates: [String] = []
        switch name {
        case "from", "to", "subject":
            // A value with nothing indexable (`from:@`) can match nothing, so it narrows nothing.
            guard isIndexable(token.value) else { return nil }
            let field: SearchTerm.Kind = name == "from" ? .from(token.value) : name == "to" ? .to(token.value) : .subject(token.value)
            return SearchTerm(field, negated: token.negated, isPrefix: open && !token.negated)
        case "is":
            kind = readStates[keyword]
            candidates = Array(readStates.keys)
        case "has":
            kind = hasValues[keyword]
            candidates = Array(hasValues.keys)
        case "in":
            kind = mailboxes[keyword].map(SearchTerm.Kind.mailbox)
            candidates = Array(mailboxes.keys)
        case "before", "after":
            if let day = day(token.value, timeZone: timeZone) {
                kind = name == "before" ? .before(day) : .after(day)
            } else {
                kind = nil
                if open && isDayPrefix(token.value) { return nil }
            }
        default:
            kind = nil
        }
        if let kind { return SearchTerm(kind, negated: token.negated) }
        if open && candidates.contains(where: { $0.hasPrefix(keyword) }) { return nil }
        // A value the operator does not take: the whole token is searched as words, as if no operator were known.
        guard isIndexable(token.raw) else { return nil }
        return SearchTerm(.text(token.raw), negated: token.negated, isPrefix: open && !token.negated)
    }

    // MARK: Lexer

    static func tokens(in text: String) -> [Token] {
        let chars = Array(text)
        var tokens: [Token] = []
        var i = 0
        /// Reads a quoted run starting at the quote at `start`; returns its content, whether it closed, and the end.
        func quoted(from start: Int) -> (value: String, closed: Bool, end: Int) {
            var end = start + 1
            while end < chars.count, chars[end] != "\"" { end += 1 }
            let value = String(chars[(start + 1)..<end])
            return end < chars.count ? (value, true, end + 1) : (value, false, end)
        }
        while i < chars.count {
            if chars[i].isWhitespace {
                i += 1
                continue
            }
            var negated = false
            if chars[i] == "-", i + 1 < chars.count, !chars[i + 1].isWhitespace {
                negated = true
                i += 1
            }
            let start = i
            if chars[i] == "\"" {
                let run = quoted(from: i)
                tokens.append(Token(negated: negated, name: nil, value: run.value, quoted: true, closed: run.closed,
                                    raw: String(chars[start..<run.end])))
                i = run.end
                continue
            }
            var colon = i
            while colon < chars.count, !chars[colon].isWhitespace, chars[colon] != ":", chars[colon] != "\"" { colon += 1 }
            if colon < chars.count, chars[colon] == ":", operatorNames.contains(String(chars[i..<colon]).lowercased()) {
                let name = String(chars[i..<colon]).lowercased()
                let valueStart = colon + 1
                if valueStart < chars.count, chars[valueStart] == "\"" {
                    let run = quoted(from: valueStart)
                    tokens.append(Token(negated: negated, name: name, value: run.value, quoted: true, closed: run.closed,
                                        raw: String(chars[start..<run.end])))
                    i = run.end
                } else {
                    var end = valueStart
                    while end < chars.count, !chars[end].isWhitespace { end += 1 }
                    tokens.append(Token(negated: negated, name: name, value: String(chars[valueStart..<end]), quoted: false,
                                        closed: false, raw: String(chars[start..<end])))
                    i = end
                }
                continue
            }
            while i < chars.count, !chars[i].isWhitespace { i += 1 }
            let word = String(chars[start..<i])
            tokens.append(Token(negated: negated, name: nil, value: word, quoted: false, closed: false, raw: word))
        }
        return tokens
    }

    // MARK: Values

    /// Whether the text holds anything the index keeps: a character unicode61 starts a word at. A term without one
    /// (`@`, `Ⓐ`) would be an FTS5 phrase with no words, which matches no message, so it adds nothing instead.
    static func isIndexable(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: FullTextMatcher.startsToken)
    }

    /// Local midnight starting the day `value` names (YYYY-MM-DD or YYYY/MM/DD, month and day of one or two digits),
    /// in the Gregorian calendar whatever calendar the Mac uses, since the year typed is a Gregorian one. Nil for
    /// anything else, a day that does not exist (2025-02-30) included.
    static func day(_ value: String, timeZone: TimeZone) -> Date? {
        let parts = value.split(omittingEmptySubsequences: false) { $0 == "-" || $0 == "/" }
        guard parts.count == 3, parts[0].count == 4, (1...2).contains(parts[1].count), (1...2).contains(parts[2].count),
              parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return calendar.startOfDay(for: date)
    }

    /// Whether `value` is how a day in that form starts (`2024`, `2024-0`, `2024/11/`), one that more digits can still
    /// make real, so a last `before:` or `after:` still being typed waits instead of searching for the digits. A value
    /// no digit can save (`2025-13`, `2025-02-30`, `0000-1`) is not: it is searched as words, as it is once finished.
    static func isDayPrefix(_ value: String) -> Bool {
        let parts = value.split(omittingEmptySubsequences: false) { $0 == "-" || $0 == "/" }
        guard parts.count <= 3, parts.allSatisfy({ $0.allSatisfy(\.isASCIIDigit) }), parts[0].count <= 4 else { return false }
        // A separator ends the part before it, so a year followed by one is whole, and so is a month.
        if parts[0] == "0000" || parts.count > 1 && parts[0].count != 4 { return false }
        if parts.count > 1 && parts[1].count > 2 { return false }
        if parts.count > 2 || (parts.count > 1 && parts[1].count == 2) {
            guard let month = Int(parts[1]), (1...12).contains(month) else { return false }
        }
        guard parts.count > 2 else { return true }
        if parts[2].count > 2 { return false }
        // A day of two digits is finished; one of one digit (or none yet) always has a real day ahead in a real month.
        return parts[2].count < 2 || day(value, timeZone: TimeZone(identifier: "UTC")!) != nil
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
