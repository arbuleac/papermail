import Foundation
import PaperCore

/// The iCalendar an event message carries in its MIME (`/messages/{id}/$value`), for when its event cannot be read.
/// Expanding the event reads the user's calendar, which Exchange refuses a token holding the mail scopes alone
/// (`Calendars.ReadWrite` is asked for only when the user answers), while the MIME Exchange writes for a meeting request
/// or a cancellation carries the text/calendar alternative an IMAP client reads, behind the mail scope every account has.
///
/// Only what finding that part needs is read: header fields, folded or not; multipart boundaries, nested as deep as a
/// mailer nests them; base64, quoted-printable and the identity encodings; and the part's charset. A forwarded message
/// (message/rfc822) is not opened: an invitation inside it is another message's. Bytes are read as bytes, so neither a
/// CRLF nor a byte of an 8-bit part is taken for anything else.
enum GraphMIMECalendar {
    /// Deeper nesting than any mailer writes is not followed.
    static let maximumDepth = 8

    /// The text/calendar alternative, else the first calendar file (application/ics, a `.ics` name), as Gmail's MIME
    /// walk reads them; nil without either.
    static func calendar(in mime: Data) -> String? {
        let lines = lines(of: [UInt8](mime))
        var file: String?
        return find(in: lines[...], depth: 0, file: &file) ?? file
    }

    private typealias Line = ArraySlice<UInt8>

    /// The lines without their CRLF or LF.
    private static func lines(of bytes: [UInt8]) -> [Line] {
        var lines: [Line] = []
        var start = 0
        for index in bytes.indices where bytes[index] == 0x0A {
            lines.append(withoutCR(bytes[start..<index]))
            start = index + 1
        }
        if start < bytes.count { lines.append(withoutCR(bytes[start...])) }
        return lines
    }

    private static func withoutCR(_ line: Line) -> Line {
        line.last == 0x0D ? line.dropLast() : line
    }

    private static func find(in entity: ArraySlice<Line>, depth: Int, file: inout String?) -> String? {
        let (fields, bodyStart) = header(of: entity)
        let body = entity[bodyStart...]
        let type = HeaderValue(fields["content-type"] ?? "text/plain")
        if type.value.hasPrefix("multipart/") {
            guard depth < maximumDepth, let boundary = type.parameters["boundary"], !boundary.isEmpty else { return nil }
            for part in parts(of: body, boundary: Array(boundary.utf8)) {
                if let found = find(in: part, depth: depth + 1, file: &file) { return found }
            }
            return nil
        }
        let disposition = fields["content-disposition"].map(HeaderValue.init)
        let filename = disposition?.parameters["filename"] ?? type.parameters["name"] ?? ""
        let isCalendarType = type.value == "text/calendar" || type.value == "application/ics"
        guard isCalendarType || filename.lowercased().hasSuffix(".ics"),
              let text = decode(body, encoding: fields["content-transfer-encoding"], charset: type.parameters["charset"]) else { return nil }
        // A named or attached calendar is a file the sender attached; it is the invitation only when there is no
        // alternative, which may come after it.
        if type.value == "text/calendar", filename.isEmpty, disposition?.value != "attachment" { return text }
        if file == nil { file = text }
        return nil
    }

    /// The entity's header fields, names lower-cased, the first of a repeated one kept, and where its body starts.
    private static func header(of entity: ArraySlice<Line>) -> (fields: [String: String], bodyStart: Int) {
        var fields: [String: String] = [:]
        var name: String?
        var value = ""
        func keep() {
            if let name, fields[name] == nil { fields[name] = value }
        }
        var index = entity.startIndex
        while index < entity.endIndex {
            let line = entity[index]
            index += 1
            if line.isEmpty { break }
            let text = String(decoding: line, as: UTF8.self)
            if line.first == 0x20 || line.first == 0x09 {
                // A folded field goes on.
                value += " " + text.trimmingCharacters(in: .whitespaces)
                continue
            }
            keep()
            if let colon = text.firstIndex(of: ":") {
                name = text[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                value = text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            } else {
                name = nil
            }
        }
        keep()
        return (fields, index)
    }

    /// The body parts between the boundary's delimiter lines (RFC 2046 §5.1.1); the preamble and epilogue are not parts.
    private static func parts(of body: ArraySlice<Line>, boundary: [UInt8]) -> [ArraySlice<Line>] {
        let delimiter: [UInt8] = [0x2D, 0x2D] + boundary
        var parts: [ArraySlice<Line>] = []
        var start: Int?
        for index in body.indices {
            let line = body[index]
            guard line.starts(with: delimiter) else { continue }
            var rest = line.dropFirst(delimiter.count)
            let closes = rest.starts(with: [0x2D, 0x2D])
            if closes { rest = rest.dropFirst(2) }
            // Only transport padding may follow; a line that goes on is one that merely begins like the delimiter.
            guard rest.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) else { continue }
            if let start { parts.append(body[start..<index]) }
            if closes { return parts }
            start = index + 1
        }
        // A message cut short keeps the part it ends in.
        if let start, start < body.endIndex { parts.append(body[start...]) }
        return parts
    }

    private static func decode(_ lines: ArraySlice<Line>, encoding: String?, charset: String?) -> String? {
        // Base64 grows a part by a third: a calendar larger than the reader reads is left before it is decoded.
        guard lines.reduce(0, { $0 + $1.count + 2 }) <= 2 * CalendarInvitationReader.maximumLength else { return nil }
        var bytes: [UInt8]
        switch encoding?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64"?:
            guard let data = Data(base64Encoded: Data(lines.joined()), options: .ignoreUnknownCharacters) else { return nil }
            bytes = [UInt8](data)
        case "quoted-printable"?:
            bytes = quotedPrintable(lines)
        default:
            // 7bit, 8bit, binary or none: the lines as they came, with the CRLF iCalendar ends its lines with.
            bytes = Array(lines.joined(separator: [0x0D, 0x0A]))
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes.removeFirst(3) }
        guard !bytes.isEmpty, bytes.count <= CalendarInvitationReader.maximumLength else { return nil }
        return text(Data(bytes), charset: charset)
    }

    /// RFC 2045 §6.7: `=XX` is a byte, a line ending in `=` goes on, trailing whitespace is padding.
    private static func quotedPrintable(_ lines: ArraySlice<Line>) -> [UInt8] {
        var bytes: [UInt8] = []
        for (offset, original) in lines.enumerated() {
            var line = original
            while let last = line.last, last == 0x20 || last == 0x09 { line = line.dropLast() }
            let goesOn = line.last == 0x3D
            if goesOn { line = line.dropLast() }
            var index = line.startIndex
            while index < line.endIndex {
                if line[index] == 0x3D, index + 2 < line.endIndex, let high = hex(line[index + 1]), let low = hex(line[index + 2]) {
                    bytes.append(high << 4 | low)
                    index += 3
                } else {
                    bytes.append(line[index])
                    index += 1
                }
            }
            if !goesOn, offset < lines.count - 1 { bytes += [0x0D, 0x0A] }
        }
        return bytes
    }

    private static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x37
        case 0x61...0x66: return byte - 0x57
        default: return nil
        }
    }

    /// UTF-8 first, as Exchange writes it, then the part's charset, then UTF-8 with replacements.
    private static func text(_ data: Data, charset: String?) -> String {
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let charset {
            let encoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if encoding != kCFStringEncodingInvalidId,
               let decoded = String(data: data, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(encoding))) {
                return decoded
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// A field's value and its parameters (`text/calendar; charset="utf-8"; method=REQUEST`), both lower-cased but for
    /// the parameters' values; an RFC 2231 `name*=utf-8''invite.ics` is read as its plain name.
    private struct HeaderValue {
        var value: String
        var parameters: [String: String] = [:]

        init(_ field: String) {
            var pieces: [String] = []
            var current = ""
            var quoted = false
            for character in field {
                if character == "\"" { quoted.toggle() }
                if character == ";", !quoted {
                    pieces.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            }
            pieces.append(current)
            value = pieces[0].trimmingCharacters(in: .whitespaces).lowercased()
            for piece in pieces.dropFirst() {
                guard let equals = piece.firstIndex(of: "=") else { continue }
                var name = piece[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
                var raw = piece[piece.index(after: equals)...].trimmingCharacters(in: .whitespaces)
                if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") { raw = String(raw.dropFirst().dropLast()) }
                if name.hasSuffix("*") {
                    name.removeLast()
                    let parts = raw.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if parts.count == 3 { raw = String(parts[2]).removingPercentEncoding ?? String(parts[2]) }
                }
                if parameters[name] == nil { parameters[name] = raw }
            }
        }
    }
}
