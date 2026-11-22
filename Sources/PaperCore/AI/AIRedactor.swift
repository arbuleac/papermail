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

    /// Unicode letters and digits on both sides of the @, as internationalised addresses have (“jörg@müller.de”). It
    /// starts only where an address could (the lookbehind), so a long run of letters or digits with no @ is read once,
    /// not again from each of its characters.
    private static let address = regex(
        #"(?i)(?<![\p{L}\p{N}._%+\-])(?:mailto:)?([\p{L}\p{N}._%+\-]+@([\p{L}\p{N}\-]+(?:\.[\p{L}\p{N}\-]+)*\.\p{L}{2,}))"#
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

    /// Chinese, Japanese and Korean, which run on without spaces (“验证码是482913”): their characters neither end a code
    /// word nor count as part of a code's word.
    private static let runOnScripts = #"\p{Han}\p{Hiragana}\p{Katakana}\p{Hangul}"#

    /// Words that say a number nearby is a code. “code” stands alone so a postcode or a barcode does not count;
    /// German compounds are listed, and Chinese, Japanese and Korean words, which have no word boundary to stand alone at.
    private static let codeWord = regex(
        #"(?i)\b(?:code|codes|otp|pin|passcode|password|passwort|one[- ]time|two[- ]factor|2fa|mfa|verif\w*|confirm\w* number|código|codice|kod|kode|bestätigungscode|sicherheitscode|verifizierungscode|anmeldecode|zugangscode)\b|验证码|驗證碼|認証|コード|인증"#
    )
    /// The words among them that say a code follows, whatever its shape: beside one, five to ten letters and digits with a
    /// digit among them count in any order (“ABC123”, “XY-4821”). The bare word “code” is weaker, so a promotion's “Use
    /// code SAVE10” stays.
    private static let strongCodeWord = regex(
        #"(?i)\b(?:otp|passcode|password|passwort|one[- ]time|two[- ]factor|2fa|mfa|verif\w*|(?:sign|log)[- ]?in code|security code|access code|auth\w* code|bestätigungscode|sicherheitscode|verifizierungscode|anmeldecode|zugangscode)\b|\bcode(?:\s+is\b|\s*:)|验证码|驗證碼|認証|コード|인증"#
    )
    /// What could be a code, for `isCode` to decide by its shape: digits in up to three groups (“482 913”, “48-29-13”),
    /// optionally after one letter and a dash (“G-482913”), or letters and digits, one dash at most (“ABCD-1234”), with a
    /// digit among them. Not part of an amount, a time, a version or a longer word or number. Every repeat is bounded,
    /// so a long run of digits costs no more than its length.
    private static let codeCandidate = regex(
        #"(?<![[\w$€£¥#.,/-]--["# + runOnScripts + #"]])"#
            + #"(?:(?:[A-Za-z]-)?\d{2,4}(?:[ -]\d{2,4}){1,2}|(?=[A-Za-z-]{0,20}\d)[A-Za-z\d]{1,10}(?:-[A-Za-z\d]{1,10})?)"#
            + #"(?![[\w/:-]--["# + runOnScripts + #"]]|[.,]\d)"#
    )
    /// Numbers labelled as something else keep their digits even beside the word “code”, as does a promotion's code.
    private static let otherNumberLabel = regex(
        #"(?i)\b(?:order|invoice|booking|reference|ref|tracking|ticket|case|account|confirmation|reservation|flight|room|phone|tel|promo\w*|discount|coupon)\b[^\n]{0,15}$"#
    )
    private static let codeWordDistance = 40

    private static func redactingCodes(in text: String) -> String {
        let string = text as NSString
        let all = NSRange(location: 0, length: string.length)
        let words = codeWord.matches(in: text, range: all).map(\.range)
        guard !words.isEmpty else { return text }
        let strongWords = strongCodeWord.matches(in: text, range: all).map(\.range)
        let candidates = codeCandidate.matches(in: text, range: all).map(\.range).filter { candidate in
            let token = string.substring(with: candidate)
            let strong = isNear(candidate, strongWords)
            guard isCode(token, strong: strong), strong || isNear(candidate, words) else { return false }
            let before = string.substring(with: NSRange(location: max(0, candidate.location - 30),
                                                         length: min(30, candidate.location)))
            return otherNumberLabel.firstMatch(in: before, range: NSRange(location: 0, length: (before as NSString).length)) == nil
        }
        guard !candidates.isEmpty else { return text }
        let result = NSMutableString(string: string)
        for range in candidates.reversed() { result.replaceCharacters(in: range, with: "[code]") }
        return result as String
    }

    /// Whether `token` has a code's shape. Digits alone: four to eight, two groups of three or four, or three groups of
    /// two to four that are not a date's (“2026-11-20”). Letters and digits, five to ten of them: beside a strong code
    /// word (`strong`) in any order and with one dash at most (“ABC123”, “H4K-29Q”); beside the bare word, only as one
    /// run with a letter after a digit (“K7QX9P”), which a word with a number at its end is not (“SAVE10”, “COVID19”).
    static func isCode(_ token: String, strong: Bool) -> Bool {
        let isDigits: (Substring) -> Bool = { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
        var groups = token.split(whereSeparator: { $0 == " " || $0 == "-" })
        // An issuer's letter before the digits (“G-482913”): the digits decide.
        if groups.count > 1, groups[0].count == 1, groups[0].first?.isLetter == true, groups.dropFirst().allSatisfy(isDigits) {
            groups.removeFirst()
        }
        let sizes = groups.map(\.count)
        if groups.allSatisfy(isDigits) {
            switch sizes.count {
            case 1: return (4...8).contains(sizes[0])
            case 2: return sizes.allSatisfy { (3...4).contains($0) }
            case 3: return sizes.allSatisfy { (2...4).contains($0) } && sizes != [4, 2, 2] && sizes != [2, 2, 4]
            default: return false
            }
        }
        let characters = groups.joined()
        guard (5...10).contains(characters.count), characters.contains(where: \.isNumber), characters.contains(where: \.isLetter) else {
            return false
        }
        if strong { return groups.count == 1 || sizes.allSatisfy { $0 >= 2 } }
        guard groups.count == 1, let digit = characters.firstIndex(where: \.isNumber) else { return false }
        return characters[digit...].contains(where: \.isLetter)
    }

    /// Whether one of `words` (in text order, not overlapping) lies within `codeWordDistance` of `candidate`, before or
    /// after it: found by halving, so a long mail with many codes and code words costs no more than its length.
    private static func isNear(_ candidate: NSRange, _ words: [NSRange]) -> Bool {
        let end = NSMaxRange(candidate)
        var low = 0
        var high = words.count
        while low < high {
            let middle = (low + high) / 2
            if words[middle].location < end { low = middle + 1 } else { high = middle }
        }
        // `low` is the first word starting at or after the candidate's end; the words before it start before that end.
        if low < words.count, words[low].location - end <= codeWordDistance { return true }
        for index in stride(from: low - 1, through: max(0, low - 2), by: -1) {
            let word = words[index]
            if NSMaxRange(word) <= candidate.location { return candidate.location - NSMaxRange(word) <= codeWordDistance }
        }
        return false
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
