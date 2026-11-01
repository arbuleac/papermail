import Foundation
import SSCore

/// Parses RFC 5322 address headers as Gmail returns them: `Name <a@b>`, `"Last, First" <a@b>`, bare
/// addresses, comma-separated lists, comments and group syntax.
///
/// Gmail already decodes RFC 2047 names, so decoding here is only a safety net. The parser is forgiving
/// by design: a malformed header should degrade to "some address text" rather than drop a participant.
public enum AddressParser {
    public static func parse(_ header: String) -> [EmailAddress] {
        splitTopLevel(header).compactMap(parseMailbox)
    }

    /// The first mailbox of a header, for single-valued headers such as `From`.
    public static func first(_ header: String) -> EmailAddress? {
        parse(header).first
    }

    // MARK: Splitting

    /// Splits on commas that sit outside quotes, angle brackets and comments.
    private static func splitTopLevel(_ header: String) -> [String] {
        var items: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        var commentDepth = 0
        var escaped = false

        for character in header {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if inQuotes {
                if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inQuotes = false
                }
                current.append(character)
                continue
            }
            if commentDepth > 0 {
                if character == "(" { commentDepth += 1 }
                if character == ")" { commentDepth -= 1 }
                current.append(character)
                continue
            }
            switch character {
            case "\"":
                inQuotes = true
                current.append(character)
            case "(":
                commentDepth = 1
                current.append(character)
            case "<":
                inAngle = true
                current.append(character)
            case ">":
                inAngle = false
                current.append(character)
            case "," where !inAngle:
                items.append(current)
                current = ""
            default:
                current.append(character)
            }
        }
        items.append(current)
        return items.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: One mailbox

    private static func parseMailbox(_ item: String) -> EmailAddress? {
        var name = ""
        var angleAddress = ""
        var sawAngle = false
        var inQuotes = false
        var inAngle = false
        var commentDepth = 0
        var escaped = false

        for character in item {
            if escaped {
                if inAngle { angleAddress.append(character) } else { name.append(character) }
                escaped = false
                continue
            }
            if inQuotes {
                if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inQuotes = false
                } else {
                    name.append(character)
                }
                continue
            }
            if commentDepth > 0 {
                if character == "(" { commentDepth += 1 }
                if character == ")" { commentDepth -= 1 }
                continue
            }
            if inAngle {
                if character == ">" {
                    inAngle = false
                } else {
                    angleAddress.append(character)
                }
                continue
            }
            switch character {
            case "\"":
                inQuotes = true
            case "(":
                commentDepth = 1
            case "<":
                inAngle = true
                sawAngle = true
                angleAddress = ""
            case ":" where !sawAngle:
                // Group syntax ("undisclosed-recipients:;"): the display name before the colon is the
                // group's, not a mailbox's, so it is discarded.
                name = ""
            case ";":
                break
            default:
                name.append(character)
            }
        }

        let trimmedName = cleanName(name)
        if sawAngle {
            let address = stripRoute(angleAddress.trimmingCharacters(in: .whitespacesAndNewlines))
            guard !address.isEmpty else { return nil }
            return EmailAddress(name: trimmedName, address: address)
        }

        // No angle brackets: the text is the address, unless someone wrote "Name user@host" without them.
        let raw = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
        if tokens.count > 1, let last = tokens.last, last.contains("@") {
            let leadingName = cleanName(tokens.dropLast().joined(separator: " "))
            return EmailAddress(name: leadingName, address: stripRoute(last))
        }
        return EmailAddress(name: nil, address: stripRoute(raw))
    }

    /// Source routes (`<@relay:user@host>`) are obsolete; only the final addr-spec is meaningful.
    private static func stripRoute(_ address: String) -> String {
        guard address.hasPrefix("@"), let colon = address.firstIndex(of: ":") else { return address }
        return String(address[address.index(after: colon)...])
    }

    private static func cleanName(_ name: String) -> String? {
        var cleaned = RFC2047.decode(name).trimmingCharacters(in: .whitespacesAndNewlines)
        // A name that was quoted and then had its quotes stripped may still carry inner quotes from
        // lax senders; a surrounding pair is never meaningful.
        if cleaned.count >= 2, cleaned.hasPrefix("'"), cleaned.hasSuffix("'") {
            cleaned = String(cleaned.dropFirst().dropLast())
        }
        return cleaned.isEmpty ? nil : cleaned
    }
}
