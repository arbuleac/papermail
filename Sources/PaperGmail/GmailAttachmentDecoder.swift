import Foundation
import PaperCore

/// Turns a downloaded `users.messages.attachments.get` reply (`{"size": …, "data": "<base64url>"}`) into the file it
/// carries without holding either in memory: the reply is mapped from disk, its `data` string is found by walking the
/// top-level object, and the string is decoded a slice at a time into the destination. `JSONDecoder` would hold the
/// reply, the string and the decoded bytes at once, about three and a half times the file.
enum GmailAttachmentDecoder {
    /// Characters decoded per slice: a multiple of 4, so every slice but the last is whole base64 quanta.
    static let sliceLength = 256 * 1024

    /// Writes the attachment in the reply at `reply` to `destination` (created or replaced). Throws
    /// `ProviderError.decoding` when the reply holds no base64url `data` string; nothing is left at `destination`
    /// then.
    static func decode(reply: URL, to destination: URL) throws {
        let json = try Data(contentsOf: reply, options: .alwaysMapped)
        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSURLErrorKey: destination])
        }
        do {
            let output = try FileHandle(forWritingTo: destination)
            defer { try? output.close() }
            try json.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let bytes = raw.bindMemory(to: UInt8.self)
                guard let value = dataString(in: bytes) else {
                    throw ProviderError.decoding("Attachment payload is not base64url")
                }
                try decodeBase64URL(bytes[value], into: output)
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    // MARK: Base64url

    private static func decodeBase64URL(_ text: Slice<UnsafeBufferPointer<UInt8>>, into output: FileHandle) throws {
        // One reusable slice buffer, filled through a pointer: this loop runs once per byte of the file.
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: sliceLength + 3)
        defer { buffer.deallocate() }
        var count = 0
        for byte in text {
            switch byte {
            case UInt8(ascii: "-"): buffer[count] = UInt8(ascii: "+")
            case UInt8(ascii: "_"): buffer[count] = UInt8(ascii: "/")
            // Base64URL.decode drops whitespace too; a JSON string never holds a raw one, but a line-wrapped payload
            // would still decode.
            case 0x20, 0x09, 0x0A, 0x0D: continue
            default: buffer[count] = byte
            }
            count += 1
            if count == sliceLength {
                try write(UnsafeBufferPointer(rebasing: buffer[0..<count]), to: output)
                count = 0
            }
        }
        // Gmail leaves the padding off; Foundation needs it.
        while count % 4 != 0 {
            buffer[count] = UInt8(ascii: "=")
            count += 1
        }
        if count > 0 { try write(UnsafeBufferPointer(rebasing: buffer[0..<count]), to: output) }
    }

    private static func write(_ slice: UnsafeBufferPointer<UInt8>, to output: FileHandle) throws {
        guard let decoded = Data(base64Encoded: Data(buffer: slice)) else {
            throw ProviderError.decoding("Attachment payload is not base64url")
        }
        try output.write(contentsOf: decoded)
    }

    // MARK: JSON

    /// The bytes of the top-level `"data"` string, between its quotes; nil when there is none or the reply is not a
    /// JSON object. Other members are skipped whatever they hold.
    static func dataString(in bytes: UnsafeBufferPointer<UInt8>) -> Range<Int>? {
        var scanner = Scanner(bytes: bytes)
        guard scanner.consume(UInt8(ascii: "{")) else { return nil }
        while true {
            scanner.skipWhitespace()
            if scanner.consume(UInt8(ascii: "}")) { return nil }
            guard let key = scanner.string(), scanner.consumeAfterWhitespace(UInt8(ascii: ":")) else { return nil }
            scanner.skipWhitespace()
            let isData = bytes[key].elementsEqual("data".utf8)
            if isData {
                // A base64url string holds no escapes; one that does is not what Gmail sends.
                guard let value = scanner.string(), !bytes[value].contains(UInt8(ascii: "\\")) else { return nil }
                return value
            }
            guard scanner.skipValue() else { return nil }
            scanner.skipWhitespace()
            if scanner.consume(UInt8(ascii: ",")) { continue }
            return nil
        }
    }

    /// A cursor over the reply that knows just enough JSON to step over a member it does not want.
    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0

        init(bytes: UnsafeBufferPointer<UInt8>) {
            self.bytes = bytes
            skipWhitespace()
        }

        var current: UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipWhitespace() {
            while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D { index += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard current == byte else { return false }
            index += 1
            return true
        }

        mutating func consumeAfterWhitespace(_ byte: UInt8) -> Bool {
            skipWhitespace()
            return consume(byte)
        }

        /// A string at the cursor: the range of its contents, escapes left as they are.
        mutating func string() -> Range<Int>? {
            guard consume(UInt8(ascii: "\"")) else { return nil }
            let start = index
            while let byte = current {
                if byte == UInt8(ascii: "\\") {
                    index += 2
                    continue
                }
                if byte == UInt8(ascii: "\"") {
                    defer { index += 1 }
                    return start..<index
                }
                index += 1
            }
            return nil
        }

        /// Steps over any value: a string, an object or array (counting depth, strings stepped over whole), or a
        /// number or literal.
        mutating func skipValue() -> Bool {
            guard let byte = current else { return false }
            switch byte {
            case UInt8(ascii: "\""):
                return string() != nil
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                var depth = 0
                while let next = current {
                    switch next {
                    case UInt8(ascii: "\""):
                        guard string() != nil else { return false }
                        continue
                    case UInt8(ascii: "{"), UInt8(ascii: "["):
                        depth += 1
                    case UInt8(ascii: "}"), UInt8(ascii: "]"):
                        depth -= 1
                        if depth == 0 {
                            index += 1
                            return true
                        }
                    default:
                        break
                    }
                    index += 1
                }
                return false
            default:
                let start = index
                while let next = current, next != UInt8(ascii: ","), next != UInt8(ascii: "}"), next != UInt8(ascii: "]"),
                      next != 0x20, next != 0x09, next != 0x0A, next != 0x0D {
                    index += 1
                }
                return index > start
            }
        }
    }
}
