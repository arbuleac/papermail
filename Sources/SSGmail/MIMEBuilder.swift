import Foundation
import SSCore

/// Serializes an `OutgoingMessage` as an RFC 5322 message for `messages.send`.
///
/// Layout: `multipart/mixed` holding a `multipart/alternative` (text/plain, then the HTML, which becomes
/// `multipart/related` when inline images are present, then an iCalendar part when the message answers an
/// invitation) followed by the regular attachments. Every body and attachment is base64 so the output is 7-bit clean
/// regardless of content. Lines end in CRLF.
public struct MIMEBuilder: Sendable {
    /// An iMIP calendar alternative (RFC 6047): `text/calendar` with the iTIP method as a parameter.
    public struct CalendarPart: Sendable, Equatable {
        public var method: String
        public var text: String

        public init(method: String, text: String) {
            self.method = method
            self.text = text
        }
    }

    public var message: OutgoingMessage
    public var calendar: CalendarPart?
    /// Gmail fills `From` from the account when omitted, so it is optional here.
    public var from: EmailAddress?
    public var messageID: String
    public var date: Date
    public var timeZone: TimeZone

    public init(
        message: OutgoingMessage,
        from: EmailAddress? = nil,
        messageID: String? = nil,
        date: Date = Date(),
        timeZone: TimeZone = .current,
        calendar: CalendarPart? = nil
    ) {
        self.message = message
        self.calendar = calendar
        self.from = from
        self.messageID = messageID ?? Self.makeMessageID(domain: Self.domain(of: from?.address))
        self.date = date
        self.timeZone = timeZone
    }

    /// A globally unique `<local@domain>` id; the domain is the sender's so it looks native to the mailbox.
    public static func makeMessageID(domain: String) -> String {
        "<" + UUID().uuidString.lowercased() + "@" + domain + ">"
    }

    public func build() -> Data {
        var output = ""
        for (name, value) in headers() {
            output += name + ": " + value + "\r\n"
        }
        let mixedBoundary = Self.makeBoundary("mixed")
        output += "MIME-Version: 1.0\r\n"
        output += "Content-Type: multipart/mixed; boundary=\"\(mixedBoundary)\"\r\n"
        output += "\r\n"
        output += "--\(mixedBoundary)\r\n"
        output += alternativePart()
        for attachment in message.attachments where attachment.contentID == nil {
            output += "--\(mixedBoundary)\r\n"
            output += attachmentPart(attachment, inline: false)
        }
        output += "--\(mixedBoundary)--\r\n"
        return Data(output.utf8)
    }

    // MARK: Headers

    private func headers() -> [(String, String)] {
        var headers: [(String, String)] = []
        if let from {
            headers.append(("From", Self.formatAddress(from)))
        }
        if !message.to.isEmpty { headers.append(("To", Self.formatAddressList(message.to))) }
        if !message.cc.isEmpty { headers.append(("Cc", Self.formatAddressList(message.cc))) }
        if !message.bcc.isEmpty { headers.append(("Bcc", Self.formatAddressList(message.bcc))) }
        headers.append(("Subject", RFC2047.encodeIfNeeded(Self.sanitizeHeaderText(message.subject))))
        headers.append(("Date", Self.formatDate(date, timeZone: timeZone)))
        headers.append(("Message-ID", Self.bracketed(messageID)))
        let parent = message.inReplyToInternetMessageID.map(Self.bracketed)
        if let parent {
            headers.append(("In-Reply-To", parent))
        }
        var references = message.references.map(Self.bracketed)
        // RFC 5322 §3.6.4: the parent's id closes the References chain; composers do not always add it.
        if let parent, !references.contains(parent) {
            references.append(parent)
        }
        if !references.isEmpty {
            headers.append(("References", Self.fold(references)))
        }
        return headers
    }

    static func formatAddressList(_ addresses: [EmailAddress]) -> String {
        addresses.map(formatAddress).joined(separator: ",\r\n ")
    }

    static func formatAddress(_ address: EmailAddress) -> String {
        // The spec lands between the angle brackets as it is, so it needs the same line-break guard as the
        // name; a parsed From/Reply-To is user-controlled input once the user replies to it.
        let spec = sanitizeHeaderText(address.address).trimmingCharacters(in: .whitespaces)
        guard let rawName = address.name?.trimmingCharacters(in: .whitespacesAndNewlines), !rawName.isEmpty else {
            return spec
        }
        let name = sanitizeHeaderText(rawName)
        if RFC2047.needsEncoding(name) {
            return RFC2047.encodeIfNeeded(name) + " <" + spec + ">"
        }
        if name.unicodeScalars.allSatisfy(isAtextOrSpace) {
            return name + " <" + spec + ">"
        }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"" + escaped + "\" <" + spec + ">"
    }

    private static func isAtextOrSpace(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " { return true }
        guard scalar.isASCII else { return false }
        if CharacterSet.alphanumerics.contains(scalar) { return true }
        return "!#$%&'*+-/=?^_`{|}~".unicodeScalars.contains(scalar)
    }

    /// Header values must be a single logical line; CR and LF would otherwise inject headers.
    static func sanitizeHeaderText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
    }

    static func bracketed(_ id: String) -> String {
        let trimmed = sanitizeHeaderText(id).trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("<"), trimmed.hasSuffix(">") { return trimmed }
        return "<" + trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "<>")) + ">"
    }

    static func fold(_ tokens: [String]) -> String {
        var lines: [String] = []
        var current = ""
        for token in tokens {
            if current.isEmpty {
                current = token
            } else if current.count + 1 + token.count > 76 {
                lines.append(current)
                current = token
            } else {
                current += " " + token
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.joined(separator: "\r\n ")
    }

    static func formatDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    static func domain(of address: String?) -> String {
        guard let address, let at = address.lastIndex(of: "@") else { return "supersparrow.local" }
        let domain = address[address.index(after: at)...].trimmingCharacters(in: .whitespaces)
        return domain.isEmpty ? "supersparrow.local" : domain
    }

    // MARK: Parts

    private func alternativePart() -> String {
        let boundary = Self.makeBoundary("alt")
        var output = "Content-Type: multipart/alternative; boundary=\"\(boundary)\"\r\n\r\n"
        output += "--\(boundary)\r\n"
        output += Self.textPart(message.text, type: "text/plain")
        output += "--\(boundary)\r\n"
        let inline = message.attachments.filter { $0.contentID != nil }
        if inline.isEmpty {
            output += Self.textPart(message.html, type: "text/html")
        } else {
            output += relatedPart(inline: inline)
        }
        if let calendar {
            // Last, as the richest alternative: a calendar-aware client acts on it, any other shows the text.
            let method = Self.sanitizeHeaderText(calendar.method).filter { $0.isLetter }.uppercased()
            output += "--\(boundary)\r\n"
            output += Self.textPart(calendar.text, type: "text/calendar", parameters: "; method=\(method)")
        }
        output += "--\(boundary)--\r\n"
        return output
    }

    private func relatedPart(inline: [OutgoingAttachment]) -> String {
        let boundary = Self.makeBoundary("rel")
        var output = "Content-Type: multipart/related; boundary=\"\(boundary)\"; type=\"text/html\"\r\n\r\n"
        output += "--\(boundary)\r\n"
        output += Self.textPart(message.html, type: "text/html")
        for attachment in inline {
            output += "--\(boundary)\r\n"
            output += attachmentPart(attachment, inline: true)
        }
        output += "--\(boundary)--\r\n"
        return output
    }

    private static func textPart(_ text: String, type: String, parameters: String = "") -> String {
        var output = "Content-Type: \(type); charset=\"UTF-8\"\(parameters)\r\n"
        output += "Content-Transfer-Encoding: base64\r\n\r\n"
        output += base64Lines(Data(text.utf8))
        return output
    }

    private func attachmentPart(_ attachment: OutgoingAttachment, inline: Bool) -> String {
        let type = attachment.mimeType.isEmpty ? "application/octet-stream" : Self.sanitizeHeaderText(attachment.mimeType)
        let nameParameter = Self.filenameParameter("name", attachment.filename)
        let filenameParameter = Self.filenameParameter("filename", attachment.filename)
        var output = "Content-Type: \(type); \(nameParameter)\r\n"
        output += "Content-Transfer-Encoding: base64\r\n"
        if inline, let contentID = attachment.contentID {
            output += "Content-ID: \(Self.bracketed(contentID))\r\n"
        }
        output += "Content-Disposition: \(inline ? "inline" : "attachment"); \(filenameParameter)\r\n\r\n"
        output += Self.base64Lines(attachment.data)
        return output
    }

    /// RFC 2231 keeps non-ASCII filenames intact, where RFC 2047 inside a parameter would be invalid.
    private static func filenameParameter(_ name: String, _ filename: String) -> String {
        let clean = sanitizeHeaderText(filename.isEmpty ? "attachment" : filename)
        if RFC2047.needsEncoding(clean) {
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: ".-_")
            let encoded = clean.addingPercentEncoding(withAllowedCharacters: allowed) ?? "attachment"
            return "\(name)*=UTF-8''\(encoded)"
        }
        let escaped = clean.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\(name)=\"\(escaped)\""
    }

    private static func base64Lines(_ data: Data) -> String {
        let encoded = data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        return encoded.isEmpty ? "\r\n" : encoded + "\r\n"
    }

    private static func makeBoundary(_ label: String) -> String {
        "=_ss_" + label + "_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
    }
}
