import Foundation

/// RFC 2047 encoded words for non-ASCII header text (`=?UTF-8?B?...?=`).
///
/// Outgoing mail needs the encoder; the decoder exists so address parsing survives the rare header Gmail
/// hands back undecoded, and so tests can read what the builder wrote.
public enum RFC2047 {
    /// Bytes per encoded word: 39 bytes become a 64-character word, which still fits the 76-column line
    /// RFC 2047 §2 asks for once a header name such as "Subject: " precedes it.
    private static let bytesPerWord = 39

    /// Returns `text` untouched when it is printable ASCII; otherwise one or more encoded words joined by
    /// folding whitespace, so the result can be dropped straight into a header line.
    public static func encodeIfNeeded(_ text: String) -> String {
        guard needsEncoding(text) else { return text }
        return encodedWords(for: text).joined(separator: "\r\n ")
    }

    public static func needsEncoding(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            scalar.value > 126 || (scalar.value < 32 && scalar != "\t")
        }
    }

    /// Splits on character boundaries so no encoded word ever cuts a multi-byte sequence in half.
    static func encodedWords(for text: String) -> [String] {
        var words: [String] = []
        var current = Data()
        for character in text {
            let bytes = Data(String(character).utf8)
            if current.count + bytes.count > bytesPerWord, !current.isEmpty {
                words.append(encodedWord(current))
                current = Data()
            }
            current.append(bytes)
        }
        if !current.isEmpty || words.isEmpty {
            words.append(encodedWord(current))
        }
        return words
    }

    private static func encodedWord(_ bytes: Data) -> String {
        "=?UTF-8?B?" + bytes.base64EncodedString() + "?="
    }

    /// Decodes every encoded word in `text`; whitespace between two adjacent encoded words is dropped as
    /// RFC 2047 §6.2 requires. Unknown charsets fall back to Latin-1 so nothing is silently lost.
    public static func decode(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        guard let regex = try? NSRegularExpression(pattern: #"=\?([^?\s]+)\?([BbQq])\?([^?\s]*)\?="#) else {
            return text
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return text }

        var output = ""
        var cursor = 0
        var previousWordEnd: Int?
        for match in matches {
            let between = nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let isOnlyWhitespace = !between.isEmpty && between.allSatisfy(\.isWhitespace)
            if !(isOnlyWhitespace && previousWordEnd == cursor) {
                output += between
            }
            let charset = nsText.substring(with: match.range(at: 1))
            let encoding = nsText.substring(with: match.range(at: 2)).uppercased()
            let payload = nsText.substring(with: match.range(at: 3))
            output += decodeWord(charset: charset, encoding: encoding, payload: payload)
                ?? nsText.substring(with: match.range)
            cursor = match.range.location + match.range.length
            previousWordEnd = cursor
        }
        output += nsText.substring(from: cursor)
        return output
    }

    private static func decodeWord(charset: String, encoding: String, payload: String) -> String? {
        let bytes: Data?
        switch encoding {
        case "B":
            bytes = Base64URL.decode(payload)
        case "Q":
            bytes = decodeQ(payload)
        default:
            bytes = nil
        }
        guard let bytes else { return nil }
        let name = charset.split(separator: "*").first.map(String.init) ?? charset
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        if cfEncoding != kCFStringEncodingInvalidId {
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            if let decoded = String(data: bytes, encoding: String.Encoding(rawValue: nsEncoding)) {
                return decoded
            }
        }
        return String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1)
    }

    private static func decodeQ(_ payload: String) -> Data? {
        var bytes = Data()
        let input = Array(payload.utf8)
        var index = 0
        while index < input.count {
            let byte = input[index]
            if byte == UInt8(ascii: "_") {
                bytes.append(UInt8(ascii: " "))
                index += 1
            } else if byte == UInt8(ascii: "="), index + 2 < input.count,
                      let value = UInt8(String(decoding: input[(index + 1)...(index + 2)], as: UTF8.self), radix: 16) {
                bytes.append(value)
                index += 3
            } else {
                bytes.append(byte)
                index += 1
            }
        }
        return bytes
    }
}
