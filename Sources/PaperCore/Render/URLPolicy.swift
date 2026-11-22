import Foundation

/// Decides what a URL found in message markup may do. Every attribute and CSS reference the renderer could load
/// or link passes through here, so the allowed-scheme list lives in exactly one place.
enum URLPolicy {
    enum Classification: Equatable {
        /// http or https, with the whitespace tricks browsers tolerate already stripped.
        case remote(String)
        /// mailto: or tel:, safe to keep as a link target.
        case contact(String)
        /// A cid: reference. The payload is the content id without angle brackets, validated to be a single
        /// path segment so it can never escape the message's attachment directory.
        case inlineImage(contentID: String)
        /// A data: URI carrying an image/* payload within the size limit.
        case inlineData(String)
        /// A same-document fragment ("#section"), kept so in-message anchors still work after ids are prefixed.
        case fragment(String)
        /// Everything else: javascript:, vbscript:, data:text/html, blob:, file:, relative and protocol-relative.
        case rejected
    }

    /// Browsers decode multi-megabyte data: URIs happily, but a stored body that large defeats the point of
    /// render-ready HTML, so inline images beyond this are dropped.
    static let maxDataURILength = 2 * 1024 * 1024

    static func classify(_ raw: String) -> Classification {
        let value = normalized(raw)
        guard let scheme = scheme(of: value) else {
            return value.hasPrefix("#") ? .fragment(value) : .rejected
        }
        switch scheme {
        case "http", "https":
            return .remote(value)
        case "mailto", "tel":
            return .contact(value)
        case "cid":
            guard let id = contentID(fromCIDValue: value) else { return .rejected }
            return .inlineImage(contentID: id)
        case "data":
            guard isImageDataURI(value), value.utf8.count <= maxDataURILength else { return .rejected }
            return .inlineData(value)
        default:
            return .rejected
        }
    }

    /// Mirrors the URL parser's tolerance: leading and trailing controls or spaces are ignored and ASCII tab,
    /// CR and LF are removed anywhere, so "java\nscript:" has to be recognised as javascript:.
    static func normalized(_ raw: String) -> String {
        // Nearly every URL is already clean: printable ASCII at both ends and none of the three stripped
        // controls inside means the slow path below would hand back the same string.
        let bytes = raw.utf8
        if let first = bytes.first, let last = bytes.last, first > 0x20, first < 0x7F, last > 0x20, last < 0x7F,
           !bytes.contains(where: { $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
            return raw
        }
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars where scalar != "\t" && scalar != "\n" && scalar != "\r" {
            scalars.append(scalar)
        }
        return String(scalars).trimmingCharacters(in: controlsAndWhitespace)
    }

    /// Lowercased scheme when the value starts with one, nil for scheme-less (relative) references.
    static func scheme(of value: String) -> String? {
        var scheme = String.UnicodeScalarView()
        for (index, scalar) in value.unicodeScalars.enumerated() {
            if scalar == ":" {
                return index == 0 ? nil : String(scheme)
            }
            let letter = isASCIILetter(scalar)
            if index == 0 {
                guard letter else { return nil }
            } else {
                guard letter || isASCIIDigit(scalar) || scalar == "+" || scalar == "-" || scalar == "." else { return nil }
            }
            scheme.append(lowercasedASCII(scalar))
        }
        return nil
    }

    private static let controlsAndWhitespace = CharacterSet.controlCharacters.union(.whitespacesAndNewlines)

    private static func contentID(fromCIDValue value: String) -> String? {
        var id = String(value.dropFirst("cid:".count))
        // Some mailers URL-encode the content id in the HTML while the MIME header carries it raw; decode once
        // so the lookup key matches what AttachmentInfo.contentID holds.
        id = id.removingPercentEncoding ?? id
        id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("<") { id.removeFirst() }
        if id.hasSuffix(">") { id.removeLast() }
        id = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, id != ".", !id.contains(".."), !id.contains("/"), !id.contains("\\") else { return nil }
        guard id.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return id
    }

    private static func isImageDataURI(_ value: String) -> Bool {
        // Only the head of the URI matters and the payload may be megabytes, so avoid lowercasing all of it.
        let head = String(value.unicodeScalars.prefix(64)).lowercased()
        guard head.hasPrefix("data:") else { return false }
        let mime = head.dropFirst("data:".count).prefix { $0 != ";" && $0 != "," }
        return mime.trimmingCharacters(in: .whitespaces).hasPrefix("image/")
    }

    static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value >= 0x41 && scalar.value <= 0x5A) || (scalar.value >= 0x61 && scalar.value <= 0x7A)
    }

    static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x30 && scalar.value <= 0x39
    }

    private static func lowercasedASCII(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        guard scalar.value >= 0x41, scalar.value <= 0x5A, let lower = Unicode.Scalar(scalar.value + 0x20) else { return scalar }
        return lower
    }
}
