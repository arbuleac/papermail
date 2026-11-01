import Foundation

/// Turns what people type or paste into recipient fields into `EmailAddress` values.
///
/// Accepts the shapes real clients produce: `"Doe, John" <john@example.com>`, `John Doe <john@example.com>`,
/// `<john@example.com>`, `john@example.com`, `john@example.com (John Doe)`, and lists of those separated by
/// commas, semicolons or newlines. Commas inside quotes or angle brackets never split an entry.
///
/// Parsing never drops an entry: an unparseable piece comes back with the raw text as its `address` so the
/// composer can show it and refuse to send. Use `isValid(_:)` or `invalidEntries(in:)` to tell them apart.
public enum AddressListParser {
    /// The characters that end an entry when they sit outside quotes and angle brackets.
    public static let separators = CharacterSet(charactersIn: ",;\n\r")

    /// An entry of a list together with the pieces a splitter that ignores quoting (`NSTokenField`'s) cuts
    /// it into; more than one piece means such a splitter breaks the entry.
    public struct Entry: Hashable, Sendable {
        /// The entry as written, trimmed.
        public var text: String
        /// Trimmed, never empty.
        public var pieces: [String]
        public init(text: String, pieces: [String]) {
            self.text = text
            self.pieces = pieces
        }
    }

    /// Every entry in `input`, in order, including ones that fail validation.
    public static func parse(_ input: String) -> [EmailAddress] {
        split(input).compactMap(parseEntry)
    }

    /// The entries of `input` with the pieces a quote-blind splitter makes of each, so a caller handed such
    /// pieces one at a time can tell which belong together.
    public static func entries(in input: String) -> [Entry] {
        split(input).map { entry in
            let pieces = entry.components(separatedBy: separators)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Entry(text: entry, pieces: pieces)
        }
    }

    /// The inverse of `parseEntry`: `name <address>`, with the name quoted whenever it holds anything a
    /// parser could take for structure (a comma, a dot, brackets, quotes…), so the result survives `split`
    /// and parses back to the same value. A missing name, or one that only repeats the address, gives the
    /// bare address.
    public static func format(_ address: EmailAddress) -> String {
        guard let name = address.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty, name != address.address else {
            return address.address
        }
        return (needsQuoting(name) ? quoted(name) : name) + " <" + address.address + ">"
    }

    /// Only the entries whose address passes `isValid(_:)`.
    public static func validAddresses(in input: String) -> [EmailAddress] {
        parse(input).filter { isValid($0.address) }
    }

    /// The entries of a list that would be rejected by a mail server.
    public static func invalidEntries(in addresses: [EmailAddress]) -> [EmailAddress] {
        addresses.filter { !isValid($0.address) }
    }

    /// A deliberately practical check: one `@`, a dotted domain with a two-plus character top level,
    /// no whitespace, no empty or dot-adjacent local-part segments. Unicode letters are allowed (EAI).
    public static func isValid(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 254 else { return false }
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return false }
        let local = String(parts[0])
        let domain = String(parts[1])
        guard !local.isEmpty, local.count <= 64, !local.hasPrefix("."), !local.hasSuffix("."), !local.contains("..") else {
            return false
        }
        guard local.unicodeScalars.allSatisfy(isAllowedLocalScalar) else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63, !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
            guard label.unicodeScalars.allSatisfy(isAllowedDomainScalar) else { return false }
        }
        guard let top = labels.last, top.count >= 2, !top.allSatisfy(\.isNumber) else { return false }
        return true
    }

    /// Splits a list on commas, semicolons and line breaks that sit outside quotes and angle brackets.
    public static func split(_ input: String) -> [String] {
        var entries: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        var escaped = false
        for character in input {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            switch character {
            case "\\" where inQuotes:
                current.append(character)
                escaped = true
            case "\"":
                inQuotes.toggle()
                current.append(character)
            case "<" where !inQuotes:
                inAngle = true
                current.append(character)
            case ">" where !inQuotes:
                inAngle = false
                current.append(character)
            // A CRLF pair is one Character, so the separators are matched scalar by scalar.
            case _ where character.unicodeScalars.allSatisfy(separators.contains):
                if inQuotes || inAngle {
                    current.append(character)
                } else {
                    entries.append(current)
                    current = ""
                }
            default:
                current.append(character)
            }
        }
        entries.append(current)
        return entries
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// One entry. Returns nil only for blank input; anything else yields a value, valid or not.
    public static func parseEntry(_ entry: String) -> EmailAddress? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let open = trimmed.lastIndex(of: "<"), let close = trimmed[open...].firstIndex(of: ">") {
            let address = stripMailto(String(trimmed[trimmed.index(after: open)..<close]))
            let rawName = String(trimmed[..<open])
            return EmailAddress(name: cleanName(rawName), address: address)
        }

        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        if tokens.count == 1 {
            return EmailAddress(name: nil, address: stripMailto(unwrap(tokens[0])))
        }
        // "john@example.com (John Doe)" and "John Doe john@example.com": the address is the token with an @.
        if let index = tokens.lastIndex(where: { $0.contains("@") }) {
            let address = stripMailto(unwrap(tokens[index]))
            var rest = tokens
            rest.remove(at: index)
            return EmailAddress(name: cleanName(rest.joined(separator: " ")), address: address)
        }
        return EmailAddress(name: nil, address: trimmed)
    }

    // MARK: Helpers

    private static func cleanName(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.hasPrefix("(") && name.hasSuffix(")") && name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        if name.hasPrefix("\"") && name.hasSuffix("\"") && name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        } else if name.hasPrefix("'") && name.hasSuffix("'") && name.count >= 2 {
            name = String(name.dropFirst().dropLast())
        }
        name = unescapeQuotedPairs(name).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func unescapeQuotedPairs(_ text: String) -> String {
        var result = ""
        var escaped = false
        for character in text {
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        if escaped { result.append("\\") }
        return result
    }

    private static func unwrap(_ token: String) -> String {
        var value = token
        while let first = value.first, "<(\"'".contains(first) { value.removeFirst() }
        while let last = value.last, ">)\"'".contains(last) { value.removeLast() }
        return value
    }

    private static func stripMailto(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("mailto:") {
            return String(trimmed.dropFirst("mailto:".count))
        }
        return trimmed
    }

    /// RFC 5322 lets a display name go unquoted only when it is made of atoms (letters, digits, a few
    /// specials) and spaces. Anything else needs quoting, as does a name an apostrophe begins or ends,
    /// which `parseEntry` would otherwise strip as a quote.
    private static func needsQuoting(_ name: String) -> Bool {
        if name.hasPrefix("'") || name.hasSuffix("'") { return true }
        return !name.unicodeScalars.allSatisfy { $0 == " " || isAtext($0) }
    }

    private static func quoted(_ name: String) -> String {
        var result = "\""
        for character in name {
            if character == "\\" || character == "\"" { result.append("\\") }
            result.append(character)
        }
        return result + "\""
    }

    private static func isAllowedLocalScalar(_ scalar: Unicode.Scalar) -> Bool {
        isAtext(scalar) || scalar == "."
    }

    /// RFC 5322 `atext`, with Unicode letters and digits allowed (EAI).
    private static func isAtext(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { return true }
        return "!#$%&'*+/=?^_`{|}~-".unicodeScalars.contains(scalar)
    }

    private static func isAllowedDomainScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { return true }
        return scalar == "-"
    }
}
