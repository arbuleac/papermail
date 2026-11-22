import Foundation

/// The in-memory store's stand-in for `message_fts`: the same four columns, filled the same way as the v13 view
/// (`MailSchema.v13`: v12's columns, the snippet standing in for a body not stored yet), split into words where
/// unicode61 splits them (`startsToken`, `continuesToken`), so both stores answer a search alike. Case and accents
/// fold with Foundation, which agrees with unicode61's `remove_diacritics 2` for Latin letters; it also folds some
/// that unicode61 keeps (Greek and Cyrillic accents, ǡ), so only there can the in-memory store find a word without
/// its accent that the SQLite store does not.
enum FullTextMatcher {
    /// One message's indexed columns, as tokens.
    struct Columns {
        var subject: [String]
        var sender: [String]
        var recipients: [String]
        var body: [String]

        init(message: MessageMetadata, body: String?) {
            func people(_ addresses: [EmailAddress]) -> String {
                addresses.map { ($0.name ?? "") + " " + $0.address }.joined(separator: " ")
            }
            subject = FullTextMatcher.tokens(message.subject)
            sender = FullTextMatcher.tokens(message.from.map { people([$0]) } ?? "")
            recipients = FullTextMatcher.tokens(people(message.to + message.cc + message.bcc))
            // A message without a body is searched by its snippet, as the SQLite index does (v13).
            self.body = FullTextMatcher.tokens(body ?? message.snippet)
        }
    }

    /// The words unicode61 reads in `text`, folded. It splits by Unicode scalar, not by Character: a Character can join
    /// a letter with a mark that unicode61 treats as a separator.
    static func tokens(_ text: String) -> [String] {
        var tokens: [String] = []
        var token = String.UnicodeScalarView()
        func finish() {
            guard !token.isEmpty else { return }
            let folded = String(token).lowercased().folding(options: .diacriticInsensitive, locale: nil)
            if !folded.isEmpty { tokens.append(folded) }
            token = String.UnicodeScalarView()
        }
        for scalar in text.unicodeScalars {
            if token.isEmpty ? startsToken(scalar) : continuesToken(scalar) {
                token.append(scalar)
            } else {
                finish()
            }
        }
        finish()
        return tokens
    }

    /// Whether unicode61 reads `scalar` as a word character: its default categories, L*, N* and Co (so Ⓐ and 🅻, which
    /// Swift calls letters, are symbols, and a private-use character such as the Apple logo is a letter). SQLite's
    /// category tables are Unicode 6.1's and it treats a code point they do not list as a word character, so a code
    /// point 6.1 had not assigned (an emoji like 🥳, a newer script) is one whatever its category is now.
    static func startsToken(_ scalar: Unicode.Scalar) -> Bool {
        let properties = scalar.properties
        guard let age = properties.age, age <= (major: 6, minor: 1) else { return true }
        switch properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber, .privateUse, .unassigned:
            return true
        default:
            return false
        }
    }

    /// Whether unicode61 keeps `scalar` in a word already started: a word character, or one of the combining accents
    /// between U+0300 and U+0331 that SQLite lists (`sqlite3Fts5UnicodeIsdiacritic`'s two masks, joined here), which
    /// the folding then drops. Any other mark ends the word.
    static func continuesToken(_ scalar: Unicode.Scalar) -> Bool {
        if startsToken(scalar) { return true }
        let offset = Int(scalar.value) - 0x300
        guard (0..<50).contains(offset) else { return false }
        let accents: UInt64 = 0x0003_61F8_0802_9FDF
        return accents & (1 << UInt64(offset)) != 0
    }

    /// The words an index term looks for, and the column it looks in (nil: every column). Nil for an operator, and
    /// for a term with nothing indexable, which the SQLite store leaves out of its MATCH too.
    static func query(for term: SearchTerm) -> (words: [String], column: KeyPath<Columns, [String]>?)? {
        let column: KeyPath<Columns, [String]>?
        let value: String
        switch term.kind {
        case .text(let text), .phrase(let text): (column, value) = (nil, text)
        case .from(let text): (column, value) = (\Columns.sender, text)
        case .to(let text): (column, value) = (\Columns.recipients, text)
        case .subject(let text): (column, value) = (\Columns.subject, text)
        case .unread, .read, .starred, .attachment, .before, .after, .mailbox: return nil
        }
        let words = tokens(value)
        return words.isEmpty ? nil : (words, column)
    }

    /// Whether the message's columns hold the term's words side by side, in order, in one column (an FTS5 phrase),
    /// the last word as a prefix when the term is still being typed.
    static func matches(_ term: SearchTerm, in columns: Columns) -> Bool {
        guard let query = query(for: term) else { return false }
        let searched = query.column.map { [columns[keyPath: $0]] }
            ?? [columns.subject, columns.sender, columns.recipients, columns.body]
        return searched.contains { contains(query.words, in: $0, prefix: term.isPrefix) }
    }

    private static func contains(_ words: [String], in tokens: [String], prefix: Bool) -> Bool {
        guard tokens.count >= words.count else { return false }
        let last = words.count - 1
        for start in 0...(tokens.count - words.count) {
            var all = true
            for (offset, word) in words.enumerated() {
                let token = tokens[start + offset]
                let hit = prefix && offset == last ? token.hasPrefix(word) : token == word
                if !hit {
                    all = false
                    break
                }
            }
            if all { return true }
        }
        return false
    }
}
