import Foundation

/// A `mailto:` link (RFC 6068) read into what a new composer opens with: recipients, subject and body.
///
/// Only those five fields are read. Every other header a link can carry (`In-Reply-To`, `attach`, anything
/// unknown) is ignored, so a page cannot thread, attach or set headers on mail the user writes. Parsing never
/// fails on content: a malformed percent escape is kept as written, and a field whose bytes are not UTF-8 is
/// kept undecoded, so what the link said stays visible for the user to fix before sending.
public struct MailtoLink: Hashable, Sendable {
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    /// One line: a line break in a link's subject becomes a space.
    public var subject: String
    /// Plain text, line breaks as `\n` whether the link wrote `%0D%0A`, `%0A` or `%0D`.
    public var body: String

    public init(to: [EmailAddress] = [], cc: [EmailAddress] = [], bcc: [EmailAddress] = [], subject: String = "", body: String = "") {
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
    }

    /// Nil when `url` is not a mailto link.
    public init?(url: URL) {
        self.init(string: url.absoluteString)
    }

    /// Nil when `string` does not start with the `mailto:` scheme (in any case).
    public init?(string: String) {
        let scheme = "mailto:"
        guard string.count >= scheme.count, string.prefix(scheme.count).lowercased() == scheme else { return nil }
        var rest = string.dropFirst(scheme.count)
        // RFC 6068 has `#` percent-encoded inside a link; a bare one starts a fragment, which is not part of the message.
        if let hash = rest.firstIndex(of: "#") { rest = rest[..<hash] }
        let query = rest.firstIndex(of: "?")
        let path = query.map { rest[..<$0] } ?? rest
        var link = MailtoLink()
        link.to = Self.addresses(in: Self.decode(path))
        var subject: String?
        var body: String?
        if let query {
            for field in rest[rest.index(after: query)...].split(separator: "&", omittingEmptySubsequences: true) {
                guard let equals = field.firstIndex(of: "=") else { continue }
                let value = Self.decode(field[field.index(after: equals)...])
                switch Self.decode(field[..<equals]).lowercased() {
                case "to": link.to += Self.addresses(in: value)
                case "cc": link.cc += Self.addresses(in: value)
                case "bcc": link.bcc += Self.addresses(in: value)
                // The first one counts: the RFC gives a repeated subject or body no meaning, and joining them
                // would make up text the link never held.
                case "subject": subject = subject ?? value
                case "body": body = body ?? value
                default: continue
                }
            }
        }
        link.to = Self.unique(link.to)
        link.cc = Self.unique(link.cc)
        link.bcc = Self.unique(link.bcc)
        link.subject = Self.normalizedLineBreaks(subject ?? "").replacingOccurrences(of: "\n", with: " ")
        link.body = Self.normalizedLineBreaks(body ?? "")
        self = link
    }

    // MARK: Parts

    /// Percent-decodes as UTF-8. A `+` stays a plus (RFC 6068 is not form encoding). A `%` not followed by two
    /// hex digits is kept as written; a field whose decoded bytes are not UTF-8 comes back exactly as written.
    static func decode(_ raw: Substring) -> String {
        let source = Array(raw.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(source.count)
        var index = 0
        while index < source.count {
            if source[index] == UInt8(ascii: "%"), index + 2 < source.count,
               let high = hexValue(source[index + 1]), let low = hexValue(source[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        return String(bytes: bytes, encoding: .utf8) ?? String(raw)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// The addresses of a decoded `to` part or header, read by the composer's parser as in the recipient fields:
    /// links carry what people type (`Name <addr>`, several addresses joined by `,` or `;`) and what authoring
    /// tools get wrong (a doubled `mailto:`, a whole address in quotes), which that parser cleans up. The one
    /// shape it would misread is an RFC 6068 quoted local part (`"not@me"@example.org`), whose quotes it takes
    /// for a display name's, so only that shape is kept as written.
    static func addresses(in decoded: String) -> [EmailAddress] {
        AddressListParser.split(decoded).compactMap { entry in
            quotedLocalPartAddress(entry).map { EmailAddress(address: $0) } ?? AddressListParser.parseEntry(entry)
        }
    }

    /// `"local"@domain`, its quotes closing right before the `@` and nothing but a domain after it, with a
    /// doubled `mailto:` dropped as the composer's parser drops it; nil for every other entry.
    private static func quotedLocalPartAddress(_ entry: String) -> String? {
        var address = Substring(entry)
        let scheme = "mailto:"
        if address.prefix(scheme.count).lowercased() == scheme { address = address.dropFirst(scheme.count) }
        guard address.first == "\"" else { return nil }
        var escaped = false
        var index = address.index(after: address.startIndex)
        while index < address.endIndex {
            let character = address[index]
            if escaped {
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                let rest = address[address.index(after: index)...]
                guard rest.first == "@" else { return nil }
                let domain = rest.dropFirst()
                guard !domain.isEmpty, !domain.contains(where: { $0.isWhitespace || "<>\"@".contains($0) }) else { return nil }
                return String(address)
            }
            index = address.index(after: index)
        }
        return nil
    }

    /// The path and repeated headers combine; an address named twice in one field is kept once.
    private static func unique(_ addresses: [EmailAddress]) -> [EmailAddress] {
        var seen = Set<String>()
        return addresses.filter { seen.insert($0.address.lowercased()).inserted }
    }

    private static func normalizedLineBreaks(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
