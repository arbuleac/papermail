import Foundation

/// Rewrites CSS so it can only paint. Comments go, remote fetches become `none`, cid references become `ss-cid`
/// URLs, `#id` selectors follow the `ss-` prefix applied to id attributes, and the legacy script-ish vectors
/// (expression(), behavior, -moz-binding, @import, position: fixed) disappear.
///
/// The scanner works on UTF-8 bytes rather than a CSS grammar: a newsletter carries tens of kilobytes of style
/// and sanitizing runs for every message at sync time, so this has to stay a single linear pass. CSS that needs
/// no change comes back byte for byte, which lets the sanitizer leave the DOM alone for the common case.
struct CSSFilter: Sendable {
    enum Mode: Sendable {
        /// The contents of a `style="…"` attribute: declarations only.
        case attribute
        /// The contents of a `<style>` element: rules, at-rules and nested blocks.
        case sheet
    }

    struct Result: Sendable {
        var css: String
        var blockedRemoteImages: Int
        /// False when nothing was dropped or rewritten; `css` is then the input itself.
        var changed: Bool
    }

    let allowRemoteImages: Bool
    let messageID: MessageID

    func filter(_ css: String, mode: Mode) -> Result {
        let result = filter(bytes: Array(css.utf8), mode: mode)
        guard let rewritten = result.css else {
            return Result(css: css, blockedRemoteImages: result.blockedRemoteImages, changed: false)
        }
        return Result(css: String(decoding: rewritten, as: UTF8.self), blockedRemoteImages: result.blockedRemoteImages, changed: true)
    }

    /// The DOM hands out attribute values as bytes; going through String for every style attribute would cost
    /// two allocations per element. `css` is nil when nothing needed changing.
    func filter(bytes: [UInt8], mode: Mode) -> (css: [UInt8]?, blockedRemoteImages: Int) {
        var scanner = Scanner(filter: self, mode: mode, bytes: bytes)
        scanner.run()
        return (scanner.altered ? scanner.output : nil, scanner.blocked)
    }

    fileprivate enum URLRewrite {
        /// The original `url(...)` token is fine as written.
        case keep
        case replace([UInt8])
    }

    fileprivate func rewrite(url inner: [UInt8]) -> (rewrite: URLRewrite, blocked: Bool) {
        let value = String(decoding: inner, as: UTF8.self)
        switch URLPolicy.classify(value) {
        case .inlineImage(let contentID):
            let url = RenderURLScheme.inlineImageURL(for: messageID, contentID: contentID).absoluteString
            return (.replace(Scanner.urlToken(url)), false)
        case .inlineData(let data):
            return (data == value ? .keep : .replace(Scanner.urlToken(data)), false)
        case .remote(let url):
            guard allowRemoteImages else { return (.replace(Scanner.none), true) }
            return (url == value ? .keep : .replace(Scanner.urlToken(url)), false)
        case .contact, .fragment, .rejected:
            return (.replace(Scanner.none), false)
        }
    }
}

private struct Scanner {
    let filter: CSSFilter
    let mode: CSSFilter.Mode
    let bytes: [UInt8]
    var output: [UInt8] = []
    var blocked = 0
    /// Set the moment anything is dropped or rewritten. Formatting differences alone never set it.
    var altered = false

    private var segment: [UInt8] = []
    /// Depth inside a block whose prelude was dropped (everything in it is discarded).
    private var skipDepth = 0
    /// Blocks opened in the output, so stray braces never unbalance what we emit.
    private var openBlocks = 0

    private enum Terminator { case semicolon, open, close, end }

    init(filter: CSSFilter, mode: CSSFilter.Mode, bytes: [UInt8]) {
        self.filter = filter
        self.mode = mode
        self.bytes = bytes
    }

    mutating func run() {
        output.reserveCapacity(bytes.count)
        var index = 0
        var parens = 0
        let count = bytes.count
        while index < count {
            let byte = bytes[index]
            if byte == ASCII.slash, index + 1 < count, bytes[index + 1] == ASCII.star {
                index = skipComment(from: index + 2)
                altered = true
                // A comment is a token boundary ("a/**/b" is two idents), so leave a space in its place.
                segment.append(ASCII.space)
                continue
            }
            if byte == ASCII.quote || byte == ASCII.apostrophe {
                index = copyString(from: index)
                continue
            }
            if byte == ASCII.openParen {
                parens += 1
            } else if byte == ASCII.closeParen {
                parens = max(0, parens - 1)
            } else if parens == 0 {
                if byte == ASCII.semicolon { flush(.semicolon); index += 1; continue }
                if byte == ASCII.openBrace { flush(.open); index += 1; continue }
                if byte == ASCII.closeBrace { flush(.close); index += 1; continue }
            }
            segment.append(byte)
            index += 1
        }
        flush(.end)
        if openBlocks > 0 { altered = true }
        while openBlocks > 0 { output.append(ASCII.closeBrace); openBlocks -= 1 }
    }

    private func skipComment(from start: Int) -> Int {
        var index = start
        while index + 1 < bytes.count {
            if bytes[index] == ASCII.star, bytes[index + 1] == ASCII.slash { return index + 2 }
            index += 1
        }
        return bytes.count
    }

    private mutating func copyString(from start: Int) -> Int {
        let quote = bytes[start]
        segment.append(quote)
        var index = start + 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == ASCII.backslash, index + 1 < bytes.count {
                segment.append(byte)
                segment.append(bytes[index + 1])
                index += 2
                continue
            }
            segment.append(byte)
            index += 1
            if byte == quote { return index }
            // An unescaped newline ends a bad string; the parser would drop the declaration, we just stop copying.
            if byte == ASCII.newline { return index }
        }
        return index
    }

    private mutating func flush(_ terminator: Terminator) {
        defer { segment.removeAll(keepingCapacity: true) }
        let trimmed = Scanner.trim(segment[...])
        switch terminator {
        case .open:
            if skipDepth > 0 { skipDepth += 1; return }
            // Braces have no meaning in a style attribute; whatever surrounds them is garbage.
            if mode == .attribute { altered = true; return }
            if Scanner.isDroppedPrelude(trimmed) { skipDepth = 1; altered = true; return }
            output.append(contentsOf: Scanner.rewriteIDSelectors(Array(trimmed), altered: &altered))
            output.append(ASCII.openBrace)
            openBlocks += 1
        case .close:
            if skipDepth > 0 { skipDepth -= 1; return }
            emitDeclaration(trimmed)
            if mode == .sheet, openBlocks > 0 {
                output.append(ASCII.closeBrace)
                openBlocks -= 1
            } else {
                altered = true
            }
        case .semicolon, .end:
            if skipDepth > 0 { return }
            emitDeclaration(trimmed)
        }
    }

    private mutating func emitDeclaration(_ declaration: ArraySlice<UInt8>) {
        guard let first = declaration.first else { return }
        // Statement at-rules (@import, @charset, @namespace, @layer) never help an email paint.
        if first == ASCII.at { altered = true; return }
        guard let colon = declaration.firstIndex(of: ASCII.colon) else { altered = true; return }
        let name = Scanner.trim(declaration[declaration.startIndex..<colon])
        let value = Scanner.trim(declaration[(colon + 1)...])
        guard !name.isEmpty else { altered = true; return }
        let lowerName = Scanner.lowercased(name)
        if Scanner.droppedProperties.contains(lowerName) { altered = true; return }
        let lowerValue = Scanner.lowercased(value)
        if Scanner.contains(lowerValue, Scanner.expressionNeedle), Scanner.contains(Scanner.compact(lowerValue), Scanner.expressionCall) {
            altered = true
            return
        }
        if lowerName == Scanner.positionName, Scanner.contains(lowerValue, Scanner.fixedNeedle) { altered = true; return }
        // image-set() accepts bare strings as URLs, which would bypass the url() rewriting below.
        if Scanner.contains(lowerValue, Scanner.imageSetNeedle) { altered = true; return }
        var finalValue = Array(value)
        if Scanner.contains(lowerValue, Scanner.urlNeedle) {
            finalValue = rewriteURLs(finalValue)
        }
        output.append(contentsOf: name)
        output.append(ASCII.colon)
        output.append(ASCII.space)
        output.append(contentsOf: finalValue)
        output.append(ASCII.semicolon)
    }

    private mutating func rewriteURLs(_ value: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(value.count)
        var index = 0
        let count = value.count
        while index < count {
            let byte = value[index]
            if byte == ASCII.quote || byte == ASCII.apostrophe {
                let end = Scanner.endOfString(in: value, from: index)
                out.append(contentsOf: value[index..<end])
                index = end
                continue
            }
            if Scanner.isURLFunctionStart(value, at: index) {
                var cursor = index + 4
                var inner: [UInt8] = []
                var closed = false
                while cursor < count, Scanner.isWhitespace(value[cursor]) { cursor += 1 }
                if cursor < count, value[cursor] == ASCII.quote || value[cursor] == ASCII.apostrophe {
                    let quote = value[cursor]
                    cursor += 1
                    while cursor < count {
                        let inside = value[cursor]
                        if inside == ASCII.backslash, cursor + 1 < count {
                            inner.append(value[cursor + 1])
                            cursor += 2
                            continue
                        }
                        cursor += 1
                        if inside == quote { break }
                        inner.append(inside)
                    }
                    while cursor < count, value[cursor] != ASCII.closeParen { cursor += 1 }
                } else {
                    while cursor < count, value[cursor] != ASCII.closeParen {
                        inner.append(value[cursor])
                        cursor += 1
                    }
                }
                if cursor < count {
                    closed = true
                    cursor += 1
                }
                // An unterminated url( swallows the rest of the value in a real parser too.
                let tokenEnd = closed ? cursor : count
                let decision = filter.rewrite(url: Array(Scanner.trim(inner[...])))
                if decision.blocked { blocked += 1 }
                switch decision.rewrite {
                case .keep:
                    out.append(contentsOf: value[index..<tokenEnd])
                case .replace(let replacement):
                    altered = true
                    out.append(contentsOf: replacement)
                }
                index = tokenEnd
                continue
            }
            out.append(byte)
            index += 1
        }
        return out
    }

    // MARK: Helpers

    static let none = Array("none".utf8)

    static func urlToken(_ url: String) -> [UInt8] {
        var out = Array("url(\"".utf8)
        for byte in url.utf8 {
            if byte == ASCII.quote || byte == ASCII.backslash { out.append(ASCII.backslash) }
            out.append(byte)
        }
        out.append(contentsOf: Array("\")".utf8))
        return out
    }

    private static func isURLFunctionStart(_ value: [UInt8], at index: Int) -> Bool {
        guard index + 3 < value.count else { return false }
        guard value[index] | 0x20 == ASCII.u, value[index + 1] | 0x20 == ASCII.r, value[index + 2] | 0x20 == ASCII.l,
              value[index + 3] == ASCII.openParen else {
            return false
        }
        // "xurl(" would be a different (unknown) function; only a standalone url token matters.
        return index == 0 || !isIdentByte(value[index - 1])
    }

    private static func endOfString(in value: [UInt8], from start: Int) -> Int {
        let quote = value[start]
        var index = start + 1
        while index < value.count {
            let byte = value[index]
            if byte == ASCII.backslash, index + 1 < value.count { index += 2; continue }
            index += 1
            if byte == quote || byte == ASCII.newline { return index }
        }
        return index
    }

    private static func isDroppedPrelude(_ prelude: ArraySlice<UInt8>) -> Bool {
        guard prelude.first == ASCII.at else { return false }
        let lower = lowercased(prelude)
        return hasPrefix(lower, importNeedle) || hasPrefix(lower, charsetNeedle) || hasPrefix(lower, namespaceNeedle)
    }

    /// `#foo` in a selector must keep matching the element whose id became `ss-foo`.
    private static func rewriteIDSelectors(_ prelude: [UInt8], altered: inout Bool) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(prelude.count + 8)
        var index = 0
        while index < prelude.count {
            let byte = prelude[index]
            if byte == ASCII.quote || byte == ASCII.apostrophe {
                let end = endOfString(in: prelude, from: index)
                out.append(contentsOf: prelude[index..<end])
                index = end
                continue
            }
            out.append(byte)
            if byte == ASCII.hash, index + 1 < prelude.count, isIdentStartByte(prelude[index + 1]) {
                out.append(contentsOf: idPrefix)
                altered = true
            }
            index += 1
        }
        return out
    }

    static func trim(_ slice: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var start = slice.startIndex
        var end = slice.endIndex
        while start < end, isWhitespace(slice[start]) { start += 1 }
        while end > start, isWhitespace(slice[end - 1]) { end -= 1 }
        return slice[start..<end]
    }

    static func lowercased(_ slice: ArraySlice<UInt8>) -> [UInt8] {
        slice.map { $0 >= ASCII.upperA && $0 <= ASCII.upperZ ? $0 + 0x20 : $0 }
    }

    static func compact(_ bytes: [UInt8]) -> [UInt8] {
        bytes.filter { !isWhitespace($0) }
    }

    static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count, let first = needle.first else { return needle.isEmpty }
        var index = 0
        let last = haystack.count - needle.count
        while index <= last {
            if haystack[index] == first {
                var match = true
                var offset = 1
                while offset < needle.count {
                    if haystack[index + offset] != needle[offset] { match = false; break }
                    offset += 1
                }
                if match { return true }
            }
            index += 1
        }
        return false
    }

    static func hasPrefix(_ bytes: [UInt8], _ prefix: [UInt8]) -> Bool {
        bytes.count >= prefix.count && bytes[0..<prefix.count].elementsEqual(prefix)
    }

    static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == ASCII.space || byte == ASCII.tab || byte == ASCII.newline || byte == ASCII.carriageReturn || byte == ASCII.formFeed
    }

    private static func isIdentByte(_ byte: UInt8) -> Bool {
        isIdentStartByte(byte) || (byte >= ASCII.zero && byte <= ASCII.nine)
    }

    private static func isIdentStartByte(_ byte: UInt8) -> Bool {
        (byte >= ASCII.lowerA && byte <= ASCII.lowerZ) || (byte >= ASCII.upperA && byte <= ASCII.upperZ)
            || byte == ASCII.underscore || byte == ASCII.hyphen || byte == ASCII.backslash || byte >= 0x80
    }

    private static let droppedProperties: Set<[UInt8]> = [
        Array("behavior".utf8), Array("-ms-behavior".utf8), Array("-moz-binding".utf8),
    ]
    private static let expressionNeedle = Array("expression".utf8)
    private static let expressionCall = Array("expression(".utf8)
    private static let positionName = Array("position".utf8)
    private static let fixedNeedle = Array("fixed".utf8)
    private static let imageSetNeedle = Array("image-set(".utf8)
    private static let urlNeedle = Array("url(".utf8)
    private static let importNeedle = Array("@import".utf8)
    private static let charsetNeedle = Array("@charset".utf8)
    private static let namespaceNeedle = Array("@namespace".utf8)
    private static let idPrefix = Array("ss-".utf8)
}

private enum ASCII {
    static let space = UInt8(ascii: " ")
    static let tab = UInt8(ascii: "\t")
    static let newline = UInt8(ascii: "\n")
    static let carriageReturn = UInt8(ascii: "\r")
    static let formFeed: UInt8 = 0x0C
    static let slash = UInt8(ascii: "/")
    static let star = UInt8(ascii: "*")
    static let quote = UInt8(ascii: "\"")
    static let apostrophe = UInt8(ascii: "'")
    static let backslash = UInt8(ascii: "\\")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let semicolon = UInt8(ascii: ";")
    static let colon = UInt8(ascii: ":")
    static let at = UInt8(ascii: "@")
    static let hash = UInt8(ascii: "#")
    static let underscore = UInt8(ascii: "_")
    static let hyphen = UInt8(ascii: "-")
    static let zero = UInt8(ascii: "0")
    static let nine = UInt8(ascii: "9")
    static let lowerA = UInt8(ascii: "a")
    static let lowerZ = UInt8(ascii: "z")
    static let upperA = UInt8(ascii: "A")
    static let upperZ = UInt8(ascii: "Z")
    static let u = UInt8(ascii: "u")
    static let r = UInt8(ascii: "r")
    static let l = UInt8(ascii: "l")
}
