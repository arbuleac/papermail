import Foundation
import SwiftSoup

/// Elements that might begin a quoted earlier message, gathered in document order during one traversal so
/// `QuoteDetector` never has to query the tree itself. The sanitizer fills it from the scrub it already performs.
struct QuoteCandidates {
    /// div.gmail_quote, blockquote.gmail_quote, div.yahoo_quoted and blockquote[type=cite].
    private(set) var vendorContainers: [Element] = []
    /// div#divRplyFwdMsg and div#appendonsend, Outlook on the web's boundary markers.
    private(set) var outlookMarkers: [Element] = []
    private(set) var rules: [Element] = []
    /// div[style*=border-top], the box Outlook desktop draws around its From/Sent/To/Subject header.
    private(set) var borderedBlocks: [Element] = []
    private(set) var blockquotes: [Element] = []

    /// The attribute values that decide candidacy. Filled by whoever enumerates the attributes anyway.
    struct Facts {
        var classValue: [UInt8] = []
        var id: [UInt8] = []
        var type: [UInt8] = []
        var styleMentionsBorderTop = false

        init() {}

        /// Looks up only what `consider` will ask about for this tag.
        init(of element: Element, tag: [UInt8]) {
            if tag == QuoteCandidates.divTag {
                classValue = (try? element.attr(QuoteCandidates.classKey)) ?? []
                id = (try? element.attr(QuoteCandidates.idKey)) ?? []
                styleMentionsBorderTop = QuoteCandidates.mentionsBorderTop((try? element.attr(QuoteCandidates.styleKey)) ?? [])
            } else if tag == QuoteCandidates.blockquoteTag {
                classValue = (try? element.attr(QuoteCandidates.classKey)) ?? []
                type = (try? element.attr(QuoteCandidates.typeKey)) ?? []
            }
        }
    }

    mutating func consider(_ element: Element, tag: [UInt8], facts: Facts) {
        if tag == Self.divTag {
            if Self.hasClassToken(facts.classValue, Self.gmailQuote) || Self.hasClassToken(facts.classValue, Self.yahooQuoted) {
                vendorContainers.append(element)
            }
            if facts.id == Self.replyForwardMarker || facts.id == Self.appendOnSend {
                outlookMarkers.append(element)
            }
            if facts.styleMentionsBorderTop {
                borderedBlocks.append(element)
            }
        } else if tag == Self.blockquoteTag {
            if Self.hasClassToken(facts.classValue, Self.gmailQuote) || Self.equalsIgnoringCase(facts.type, Self.cite) {
                vendorContainers.append(element)
            }
            blockquotes.append(element)
        } else if tag == Self.hrTag {
            rules.append(element)
        }
    }

    /// A cheap first cut; `QuoteDetector` verifies the header text before trusting it.
    static func mentionsBorderTop(_ style: [UInt8]) -> Bool {
        let needle = borderTop
        guard style.count >= needle.count else { return false }
        var index = 0
        let last = style.count - needle.count
        while index <= last {
            var offset = 0
            while offset < needle.count, style[index + offset] | 0x20 == needle[offset] { offset += 1 }
            if offset == needle.count { return true }
            index += 1
        }
        return false
    }

    private static func hasClassToken(_ classValue: [UInt8], _ token: [UInt8]) -> Bool {
        guard classValue.count >= token.count else { return false }
        var start = 0
        let count = classValue.count
        while start < count {
            while start < count, isSpace(classValue[start]) { start += 1 }
            var end = start
            while end < count, !isSpace(classValue[end]) { end += 1 }
            if end - start == token.count, equalsIgnoringCase(classValue[start..<end], token) { return true }
            start = end
        }
        return false
    }

    private static func equalsIgnoringCase(_ value: ArraySlice<UInt8>, _ expected: [UInt8]) -> Bool {
        guard value.count == expected.count else { return false }
        for (byte, wanted) in zip(value, expected) where lowercased(byte) != wanted { return false }
        return true
    }

    private static func equalsIgnoringCase(_ value: [UInt8], _ expected: [UInt8]) -> Bool {
        equalsIgnoringCase(value[...], expected)
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    static let classKey = Array("class".utf8)
    static let idKey = Array("id".utf8)
    static let typeKey = Array("type".utf8)
    static let styleKey = Array("style".utf8)

    private static let divTag = Array("div".utf8)
    private static let blockquoteTag = Array("blockquote".utf8)
    private static let hrTag = Array("hr".utf8)
    private static let gmailQuote = Array("gmail_quote".utf8)
    private static let yahooQuoted = Array("yahoo_quoted".utf8)
    private static let cite = Array("cite".utf8)
    private static let replyForwardMarker = Array("divRplyFwdMsg".utf8)
    private static let appendOnSend = Array("appendonsend".utf8)
    private static let borderTop = Array("border-top".utf8)
}
