import Foundation
import SSCore

/// Walks the MIME tree of a `messages.get?format=full` result and collects the HTML and text
/// alternatives plus every attachment and inline part.
enum GmailBodyParser {
    /// A text part whose bytes Gmail put behind an attachment id instead of inlining them, which it does
    /// for oversized bodies. The provider fetches these before the body counts as complete.
    struct DeferredText: Sendable, Equatable {
        var mimeType: String
        var attachmentID: String
        var contentType: String?
    }

    struct Parsed: Sendable {
        var body: MessageBody
        var deferred: [DeferredText]

        /// Folds fetched bytes into the alternative the deferred part belongs to.
        mutating func resolve(_ part: DeferredText, bytes: Data) {
            let text = GmailBodyParser.decodeText(bytes, contentType: part.contentType)
            GmailBodyParser.append(text, mimeType: part.mimeType, to: &body)
            deferred.removeAll { $0 == part }
        }
    }

    static func body(from message: GmailMessage) -> MessageBody {
        parse(message).body
    }

    static func parse(_ message: GmailMessage) -> Parsed {
        var parsed = Parsed(body: MessageBody(html: nil, text: nil, attachments: []), deferred: [])
        if let payload = message.payload {
            walk(payload, into: &parsed)
        }
        return parsed
    }

    private static func walk(_ part: GmailPart, into parsed: inout Parsed) {
        let mimeType = (part.mimeType ?? "").lowercased()
        if mimeType.hasPrefix("multipart/") {
            for child in part.parts ?? [] {
                walk(child, into: &parsed)
            }
            return
        }

        let filename = part.filename ?? ""
        let disposition = part.header("Content-Disposition")?.lowercased()
        let isTextBody = mimeType == "text/html" || mimeType == "text/plain"
        // A named text part, or one the sender marked as an attachment, is a file the user attached
        // (notes.txt), not a rendering of the message.
        let isNamedOrAttached = !filename.isEmpty || (disposition?.hasPrefix("attachment") ?? false)

        if isTextBody, !isNamedOrAttached {
            if let encoded = part.body?.data, let bytes = Base64URL.decode(encoded) {
                append(decodeText(bytes, contentType: part.header("Content-Type")), mimeType: mimeType, to: &parsed.body)
            } else if let attachmentID = part.body?.attachmentId {
                parsed.deferred.append(DeferredText(mimeType: mimeType, attachmentID: attachmentID, contentType: part.header("Content-Type")))
            }
            return
        }

        // Only parts the API can hand back later are worth listing: an unnamed part without an attachment
        // id can be neither fetched nor shown, so it is dropped rather than offered as a broken download.
        guard isNamedOrAttached || part.body?.attachmentId != nil else { return }
        parsed.body.attachments.append(attachment(from: part, mimeType: mimeType, filename: filename, disposition: disposition))
    }

    /// Several bodies of one kind (forwarded digests, mailer quirks) read best concatenated in order.
    static func append(_ text: String, mimeType: String, to body: inout MessageBody) {
        if mimeType == "text/html" {
            body.html = (body.html ?? "") + text
        } else {
            body.text = body.text.map { $0 + "\n" + text } ?? text
        }
    }

    private static func attachment(from part: GmailPart, mimeType: String, filename: String, disposition: String?) -> AttachmentInfo {
        let contentID = part.header("Content-ID").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        }.flatMap { $0.isEmpty ? nil : $0 }
        // Content-Disposition decides; without one, a Content-ID is the only hint that the part is
        // referenced from the HTML rather than offered for download.
        let isInline: Bool
        if let disposition {
            isInline = disposition.hasPrefix("inline")
        } else {
            isInline = contentID != nil
        }
        let id = part.body?.attachmentId ?? part.partId ?? UUID().uuidString
        return AttachmentInfo(
            id: id,
            filename: filename.isEmpty ? defaultFilename(mimeType: mimeType, contentID: contentID) : filename,
            mimeType: mimeType.isEmpty ? "application/octet-stream" : mimeType,
            sizeBytes: part.body?.size ?? 0,
            contentID: contentID,
            isInline: isInline
        )
    }

    private static func defaultFilename(mimeType: String, contentID: String?) -> String {
        let base = contentID?.split(separator: "@").first.map(String.init) ?? "attachment"
        let ext: String
        switch mimeType {
        case "image/png": ext = "png"
        case "image/jpeg", "image/jpg": ext = "jpg"
        case "image/gif": ext = "gif"
        case "image/webp": ext = "webp"
        case "application/pdf": ext = "pdf"
        case "message/rfc822": ext = "eml"
        case "text/calendar": ext = "ics"
        default: ext = ""
        }
        return ext.isEmpty ? base : base + "." + ext
    }

    /// Gmail transcodes text parts to UTF-8 but leaves the original charset in the header; the header
    /// charset is therefore only a fallback for bytes that are not valid UTF-8.
    static func decodeText(_ bytes: Data, contentType: String?) -> String {
        if let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
        if let charset = charset(from: contentType) {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                if let decoded = String(data: bytes, encoding: String.Encoding(rawValue: nsEncoding)) {
                    return decoded
                }
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func charset(from contentType: String?) -> String? {
        guard let contentType else { return nil }
        for parameter in contentType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[0].lowercased() == "charset" else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }
}
