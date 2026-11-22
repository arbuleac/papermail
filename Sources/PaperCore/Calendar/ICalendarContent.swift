import Foundation

/// One content line of an iCalendar object (RFC 5545 §3.1): `NAME;PARAM=value:VALUE`, after unfolding.
struct ICalendarProperty: Equatable, Sendable {
    /// Upper-cased.
    var name: String
    /// Parameter names upper-cased; each value with its quotes removed.
    var parameters: [String: [String]]
    /// As written: text values are still escaped (`text`).
    var value: String

    func parameter(_ name: String) -> String? {
        parameters[name]?.first
    }

    /// The value as TEXT (RFC 5545 §3.3.11), its escapes undone.
    var text: String {
        ICalendarContent.unescape(value)
    }
}

/// A component (`BEGIN:VEVENT` … `END:VEVENT`) with its properties and the components nested in it.
struct ICalendarComponent: Equatable, Sendable {
    var name: String
    var properties: [ICalendarProperty] = []
    var components: [ICalendarComponent] = []

    func first(_ name: String) -> ICalendarProperty? {
        properties.first { $0.name == name }
    }

    func all(_ name: String) -> [ICalendarProperty] {
        properties.filter { $0.name == name }
    }

    func children(_ name: String) -> [ICalendarComponent] {
        components.filter { $0.name == name }
    }
}

/// The syntax of iCalendar: unfolding, content lines, parameters and their quoting, text escapes, and the nesting
/// of components. Knows nothing of what the properties mean.
enum ICalendarContent {
    /// An invitation is a few kilobytes, tens with a long description or time zones; anything far larger is not one
    /// worth reading at sync time.
    static let maximumLength = 512 * 1024
    /// Nesting deeper than VCALENDAR › VEVENT › VALARM, or VTIMEZONE › STANDARD, is not an invitation.
    static let maximumDepth = 4

    /// The VCALENDAR in `text`, or nil when it is not well formed: no BEGIN:VCALENDAR first, a component left open,
    /// an END that closes the wrong one, or a line that is not a content line.
    static func calendar(from text: String) -> ICalendarComponent? {
        guard text.utf8.count <= maximumLength else { return nil }
        var stack: [ICalendarComponent] = []
        var root: ICalendarComponent?
        for line in unfold(text) {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            // Nothing may follow the calendar but blank lines.
            guard root == nil, let property = property(from: line) else { return nil }
            switch property.name {
            case "BEGIN":
                let name = property.value.trimmingCharacters(in: .whitespaces).uppercased()
                guard !name.isEmpty, stack.count < maximumDepth else { return nil }
                if stack.isEmpty, name != "VCALENDAR" { return nil }
                stack.append(ICalendarComponent(name: name))
            case "END":
                let name = property.value.trimmingCharacters(in: .whitespaces).uppercased()
                guard let open = stack.popLast(), open.name == name else { return nil }
                if stack.isEmpty {
                    root = open
                } else {
                    stack[stack.count - 1].components.append(open)
                }
            default:
                guard !stack.isEmpty else { return nil }
                stack[stack.count - 1].properties.append(property)
            }
        }
        return stack.isEmpty ? root : nil
    }

    /// Logical lines: a line that starts with a space or a tab continues the one before it, less that one character
    /// (RFC 5545 §3.1). CRLF, LF and a bare CR all end a line, since mail gateways rewrite line ends.
    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        var current: String?
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for raw in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            if let first = raw.first, first == " " || first == "\t", current != nil {
                current?.append(contentsOf: raw.dropFirst())
            } else {
                if let current { lines.append(current) }
                current = String(raw)
            }
        }
        if let current { lines.append(current) }
        return lines
    }

    /// One content line, or nil when it has no name or no colon outside quotes.
    static func property(from line: String) -> ICalendarProperty? {
        let scalars = Array(line.unicodeScalars)
        var index = 0
        var name = ""
        while index < scalars.count, scalars[index] != ";", scalars[index] != ":" {
            name.unicodeScalars.append(scalars[index])
            index += 1
        }
        name = name.trimmingCharacters(in: .whitespaces).uppercased()
        guard !name.isEmpty, index < scalars.count else { return nil }
        var parameters: [String: [String]] = [:]
        while index < scalars.count, scalars[index] == ";" {
            index += 1
            var parameterName = ""
            while index < scalars.count, scalars[index] != "=", scalars[index] != ":", scalars[index] != ";" {
                parameterName.unicodeScalars.append(scalars[index])
                index += 1
            }
            parameterName = parameterName.trimmingCharacters(in: .whitespaces).uppercased()
            var values: [String] = []
            if index < scalars.count, scalars[index] == "=" {
                index += 1
                repeat {
                    if index < scalars.count, scalars[index] == "," { index += 1 }
                    var value = ""
                    if index < scalars.count, scalars[index] == "\"" {
                        index += 1
                        while index < scalars.count, scalars[index] != "\"" {
                            value.unicodeScalars.append(scalars[index])
                            index += 1
                        }
                        // An unterminated quote swallows the colon: not a content line.
                        guard index < scalars.count else { return nil }
                        index += 1
                    } else {
                        while index < scalars.count, scalars[index] != ",", scalars[index] != ";", scalars[index] != ":" {
                            value.unicodeScalars.append(scalars[index])
                            index += 1
                        }
                    }
                    values.append(value)
                } while index < scalars.count && scalars[index] == ","
            }
            if !parameterName.isEmpty {
                parameters[parameterName, default: []] += values
            }
        }
        guard index < scalars.count, scalars[index] == ":" else { return nil }
        var value = ""
        value.unicodeScalars.append(contentsOf: scalars[(index + 1)...])
        return ICalendarProperty(name: name, parameters: parameters, value: value)
    }

    /// Undoes TEXT escapes: `\\`, `\;`, `\,`, and `\n` or `\N` for a line break. A backslash before anything else
    /// stays as written.
    static func unescape(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        var result = ""
        var escaping = false
        for character in value {
            if escaping {
                switch character {
                case "n", "N": result.append("\n")
                case "\\", ";", ",": result.append(character)
                default:
                    result.append("\\")
                    result.append(character)
                }
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                result.append(character)
            }
        }
        if escaping { result.append("\\") }
        return result
    }

    /// The address of a `mailto:` calendar user value, without the scheme and its percent escapes undone; nil unless it
    /// is exactly one plain address. The sender writes the value and an answer is mailed to the organizer's, so a value
    /// that could name a second recipient, or one other than the address shown, gives none: a list (`,` `;`), an
    /// address in brackets or quotes, a comment, mailto headers (`?`), white space or control characters, or another
    /// `@`.
    static func address(fromCalendarUser value: String) -> String? {
        var trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().hasPrefix("mailto:") {
            guard let decoded = String(trimmed.dropFirst("mailto:".count)).removingPercentEncoding else { return nil }
            trimmed = decoded
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              !trimmed.unicodeScalars.contains(where: { notInAddress.contains($0) }) else { return nil }
        return trimmed
    }

    private static let notInAddress = CharacterSet.whitespacesAndNewlines
        .union(.controlCharacters)
        .union(.illegalCharacters)
        .union(CharacterSet(charactersIn: ",;<>\"()[]\\:?"))
}
