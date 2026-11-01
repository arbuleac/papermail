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
    /// Every entry in `input`, in order, including ones that fail validation.
    public static func parse(_ input: String) -> [EmailAddress] {
        split(input).compactMap(parseEntry)
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
            case ",", ";", "\n", "\r":
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

    private static func isAllowedLocalScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { return true }
        return "!#$%&'*+/=?^_`{|}~.-".unicodeScalars.contains(scalar)
    }

    private static func isAllowedDomainScalar(_ scalar: Unicode.Scalar) -> Bool {
        if scalar.properties.isAlphabetic || scalar.properties.numericType != nil { return true }
        return scalar == "-"
    }
}
