import Foundation

/// Takes out of mail text what a model needs no copy of before it leaves the Mac: addresses (to the person's name, or
/// “an address at contoso.com”), links (to “[link: contoso.com]”, so a full address never leaves and cannot be echoed
/// into a reply), one-time codes near words like “code” or “verification” (“[code]”), card numbers that pass a Luhn
/// check (“[card number]”), and invisible characters, a common place to hide instructions. Order numbers and amounts
/// stay: a reply often needs them.
///
/// Pure and Sendable: the regular expressions are immutable and shared, so a context build off the main thread costs
/// no setup.
public struct AIRedactor: Sendable {
    /// Lower-cased address → the name written in its place.
    public var names: [String: String]

    public init(names: [String: String] = [:]) {
        var lowered: [String: String] = [:]
        for (address, name) in names { lowered[address.lowercased()] = name }
        self.names = lowered
    }

    public func redact(_ text: String) -> String {
        var text = Self.removingInvisibleCharacters(text)
        text = Self.replace(Self.schemeLink, in: text) { match, string in
            let (link, tail) = Self.trimmedLink(string.substring(with: match.range))
            return Self.linkPlaceholder(for: link) + tail
        }
        text = Self.replace(Self.address, in: text) { match, string in
            let address = string.substring(with: match.range(at: 1)).lowercased()
            let domain = string.substring(with: match.range(at: 2)).lowercased()
            return names[address] ?? "an address at \(domain)"
        }
        text = Self.replace(Self.bareLink, in: text) { match, string in
            let (link, tail) = Self.trimmedLink(string.substring(with: match.range))
            return Self.linkPlaceholder(for: link) + tail
        }
        text = Self.replace(Self.cardCandidate, in: text) { match, string in
            let candidate = string.substring(with: match.range)
            let digits = candidate.filter { $0.isASCII && $0.isNumber }
            return (13...19).contains(digits.count) && Self.passesLuhn(digits) ? "[card number]" : candidate
        }
        return Self.redactingCodes(in: text)
    }

    // MARK: Invisible characters

    /// `text` without zero-width, bidirectional-control, tag and variation-selector characters: they render as
    /// nothing, so a model would read words the user never saw.
    public static func removingInvisibleCharacters(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: isInvisible) else { return text }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.lazy.filter { !isInvisible($0) })
        return String(scalars)
    }

    static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180B...0x180F, 0x200B...0x200F, 0x202A...0x202E,
             0x2060...0x2064, 0x2066...0x206F, 0x3164, 0xFE00...0xFE0F, 0xFEFF, 0xFFA0, 0xE0000...0xE007F, 0xE0100...0xE01EF:
            return true
        default:
            return false
        }
    }

    // MARK: Links

    private static let schemeLink = regex(#"(?i)\b(?:https?://|www\.)[^\s<>"'`]+"#)
    /// A domain followed by a path (“acme.test/reset?t=…”), as plain-text mail writes links; a domain alone (“at
    /// contoso.com”) is ordinary prose and stays.
    private static let bareLink = regex(#"(?i)(?<![\w@./-])(?:[\p{L}\p{N}-]+\.)+\p{L}{2,}/[^\s<>"'`]*"#)

    /// The link and the punctuation that ends the sentence around it, which stays in the text.
    private static func trimmedLink(_ link: String) -> (String, String) {
        var link = link
        var tail = ""
        while let last = link.last {
            let closing: Character? = [")": "(", "]": "[", "}": "{", ">": "<"][last]
            if ".,;:!?'\"".contains(last) || (closing.map { open in link.filter { $0 == open }.count < link.filter { $0 == last }.count } ?? false) {
                tail.insert(last, at: tail.startIndex)
                link.removeLast()
            } else {
                break
            }
        }
        return (link, tail)
    }

    private static func linkPlaceholder(for link: String) -> String {
        let withScheme = link.lowercased().hasPrefix("http") ? link : "http://" + link
        var host = URLComponents(string: withScheme)?.host ?? fallbackHost(of: link)
        host = host.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.isEmpty ? "[link]" : "[link: \(host)]"
    }

    private static func fallbackHost(of link: String) -> String {
        var rest = Substring(link)
        if let scheme = rest.range(of: "://") { rest = rest[scheme.upperBound...] }
        let authority = rest.prefix { !"/?#".contains($0) }
        let host = authority.split(separator: "@").last.map { $0.prefix { $0 != ":" } } ?? ""
        return String(host)
    }

    // MARK: Addresses

    /// Unicode letters and digits on both sides of the @, as internationalised addresses have (“jörg@müller.de”).
    private static let address = regex(
        #"(?i)(?:mailto:)?([\p{L}\p{N}._%+\-]+@([\p{L}\p{N}\-]+(?:\.[\p{L}\p{N}\-]+)*\.\p{L}{2,}))"#
    )

    // MARK: Card numbers

    private static let cardCandidate = regex(#"(?<![\d])(?:\d[ \-]?){12,18}\d(?![\d])"#)

    static func passesLuhn(_ digits: String) -> Bool {
        var sum = 0
        for (offset, character) in digits.reversed().enumerated() {
            guard var digit = character.wholeNumberValue else { return false }
            if offset % 2 == 1 {
                digit *= 2
                if digit > 9 { digit -= 9 }
            }
            sum += digit
        }
        return sum % 10 == 0
    }

    // MARK: One-time codes

    /// Words that say a number nearby is a code. “code” stands alone so a postcode or a barcode does not count;
    /// German compounds are listed.
    private static let codeWord = regex(
        #"(?i)\b(?:code|codes|otp|pin|passcode|password|one[- ]time|two[- ]factor|2fa|mfa|verif\w*|confirm\w* number|código|codice|kod|kode|bestätigungscode|sicherheitscode|verifizierungscode|anmeldecode|zugangscode)\b"#
    )
    /// Four to eight digits, or two groups of three or four (“482 913”), optionally after one letter and a dash
    /// (“G-482913”); or five to ten letters and digits with a letter after a digit (“K7QX9P”, Steam's “F7G2K”), which a
    /// word with a number at its end is not (a promotion's “SAVE10” stays). Not part of an amount, a time, a version or
    /// a longer word or number.
    private static let codeCandidate = regex(
        #"(?<![\w$€£¥#.,/-])(?:(?:[A-Z]-)?(?:\d{3,4}[ -]\d{3,4}|\d{4,8})|(?=[A-Za-z\d]*\d[A-Za-z\d]*[A-Za-z])[A-Za-z\d]{5,10})(?![\w/:-]|[.,]\d)"#
    )
    /// Numbers labelled as something else keep their digits even beside the word “code”.
    private static let otherNumberLabel = regex(
        #"(?i)\b(?:order|invoice|booking|reference|ref|tracking|ticket|case|account|confirmation|reservation|flight|room|phone|tel)\b[^\n]{0,15}$"#
    )
    private static let codeWordDistance = 40

    private static func redactingCodes(in text: String) -> String {
        let string = text as NSString
        let all = NSRange(location: 0, length: string.length)
        let words = codeWord.matches(in: text, range: all).map(\.range)
        guard !words.isEmpty else { return text }
        let candidates = codeCandidate.matches(in: text, range: all).map(\.range).filter { candidate in
            let near = words.contains { word in
                if NSMaxRange(word) <= candidate.location { return candidate.location - NSMaxRange(word) <= codeWordDistance }
                if word.location >= NSMaxRange(candidate) { return word.location - NSMaxRange(candidate) <= codeWordDistance }
                return false
            }
            guard near else { return false }
            let before = string.substring(with: NSRange(location: max(0, candidate.location - 30),
                                                         length: min(30, candidate.location)))
            return otherNumberLabel.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) == nil
        }
        guard !candidates.isEmpty else { return text }
        let result = NSMutableString(string: string)
        for range in candidates.reversed() { result.replaceCharacters(in: range, with: "[code]") }
        return result as String
    }

    // MARK: Helpers

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals tested in AIRedactorTests; a typo is a programming error caught there.
        try! NSRegularExpression(pattern: pattern)
    }

    private static func replace(_ expression: NSRegularExpression, in text: String,
                                with replacement: (NSTextCheckingResult, NSString) -> String) -> String {
        let string = text as NSString
        let matches = expression.matches(in: text, range: NSRange(location: 0, length: string.length))
        guard !matches.isEmpty else { return text }
        let result = NSMutableString(string: string)
        for match in matches.reversed() {
            result.replaceCharacters(in: match.range, with: replacement(match, string))
        }
        return result as String
    }
}
