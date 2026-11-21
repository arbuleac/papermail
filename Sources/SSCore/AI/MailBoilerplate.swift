import Foundation

/// The parts of a message's own words that tell a reader nothing about the conversation, found by their shape (string
/// work only, a message's text a few KB at most): a mail system's banner (“CAUTION: This email originated from outside
/// of the organization…”), “Sent from my iPhone”, the sender's card under their sign-off (title, phone, address) and a
/// legal disclaimer; and, for a message cut to a digest, the greeting, an opening pleasantry and the sign-off itself.
///
/// Help Me Write's context drops them before it spends its budget (`ReplyContextBuilder`): a digest of an older message
/// should carry what it said, not “Hi Alex, Hope you had a good weekend!”, and a phone number or a postal address in a
/// signature adds nothing to a reply. A message sent whole keeps its greeting and its sign-off name, which show the model
/// how the thread greets and signs.
enum MailBoilerplate {
    /// A line and its key: its start, lower-cased, trimmed, curly apostrophes made straight. Each line is lower-cased
    /// once, however many shapes it is tried against.
    private struct Line {
        var text: String
        var key: String
        var isBlank: Bool

        init(_ text: Substring) {
            self.text = String(text)
            key = MailBoilerplate.key(text)
            isBlank = key.isEmpty
        }
    }

    /// The first 130 characters, trimmed and lower-cased: enough to know a line by its start, and short to compute.
    private static func key<S: StringProtocol>(_ line: S) -> String {
        let start = line.drop { $0 == " " || $0 == "\t" || $0 == "\r" }
        var key = String(start.prefix(130)).lowercased()
        if key.contains("\u{2019}") { key = key.replacingOccurrences(of: "\u{2019}", with: "'") }
        while let last = key.last, last == " " || last == "\t" || last == "\r" { key.removeLast() }
        return key
    }

    private static func lines(of text: String) -> [Line] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(Line.init)
    }

    private static func joined(_ lines: [Line]) -> String {
        lines.map(\.text).joined(separator: "\n")
    }

    /// A message sent whole: banners and “Sent from …” lines go, and everything under the sign-off's name line (or, with
    /// no sign-off, a trailing block of contact lines), a disclaimer included. `sawTheEnd` false: the text was cut short
    /// of the message's end, so what looks like a sign-off near its end is not looked for.
    static func trimmedForFullText(_ text: String, sawTheEnd: Bool = true) -> String {
        var lines = lines(of: text)
        dropBannersAndDisclaimer(&lines)
        guard sawTheEnd else { return joined(lines) }
        if let valediction = valedictionIndex(in: lines) {
            // The sign-off and the name under it stay: they show how the thread signs.
            var end = valediction + 1
            if let name = lines[end...].firstIndex(where: { !$0.isBlank }), isNameLine(lines[name].text) { end = name + 1 }
            lines = Array(lines[..<end])
        } else {
            dropTrailingContactLines(&lines)
        }
        return joined(lines)
    }

    /// A message cut to a digest: as for a whole one, and the greeting, an opening pleasantry and the sign-off with its
    /// name go too, so the first sentences the digest keeps are what the message said.
    static func trimmedForDigest(_ text: String, sawTheEnd: Bool = true) -> String {
        var lines = lines(of: text)
        dropBannersAndDisclaimer(&lines)
        if !sawTheEnd {
            // Its end not read: nothing near the cut is taken for a sign-off.
        } else if let valediction = valedictionIndex(in: lines) {
            lines = Array(lines[..<valediction])
        } else {
            dropTrailingContactLines(&lines)
        }
        dropGreeting(&lines)
        dropOpeningPleasantry(&lines)
        return joined(lines)
    }

    /// The text without its greeting: what a question in it asks, for the thread's summary.
    static func withoutGreeting(_ text: String) -> String {
        var lines = lines(of: text)
        lines.removeAll { isBanner(key: $0.key) }
        dropGreeting(&lines)
        return joined(lines)
    }

    private static func dropBannersAndDisclaimer(_ lines: inout [Line]) {
        lines.removeAll { isBanner(key: $0.key) || isSentFrom(key: $0.key) }
        // From a disclaimer's first line to the end (never the message's first line: then it is the message).
        guard let first = lines.firstIndex(where: { !$0.isBlank }) else { return }
        if let start = lines.indices.first(where: { $0 > first && isDisclaimer(key: lines[$0].key) }) {
            lines = Array(lines[..<start])
        }
    }

    // MARK: Shapes

    /// A mail system's warning about the sender, which every message from outside carries.
    static func isBanner(_ line: String) -> Bool { isBanner(key: key(line)) }

    private static func isBanner(key: String) -> Bool {
        guard let first = key.first, bannerStarts.contains(first) else { return false }
        return bannerPrefixes.contains { key.hasPrefix($0) }
    }

    private static let bannerPrefixes = [
        "caution:", "caution -", "[external]", "[ext]", "external email", "external sender", "external:", "*external*",
        "warning: this email originated", "this email originated from outside", "this message originated from outside",
        "this message was sent from outside", "you don't often get email from", "learn why this is important",
        "[caution]", "notice: this email originated",
    ]

    private static let bannerStarts = Set(bannerPrefixes.compactMap(\.first))

    /// “Sent from my iPhone”, “Get Outlook for iOS”: what the sender's app adds.
    static func isSentFrom(_ line: String) -> Bool { isSentFrom(key: key(line)) }

    private static func isSentFrom(key line: String) -> Bool {
        guard line.count <= 60, line.first == "s" || line.first == "g" else { return false }
        return line.hasPrefix("sent from my ") || line.hasPrefix("sent from outlook") || line.hasPrefix("get outlook for ")
            || line.hasPrefix("sent from mail for ") || line.hasPrefix("sent from yahoo mail") || line.hasPrefix("sent from gmail")
            || line.hasPrefix("sent via ") || line.hasPrefix("sent from the ")
    }

    private static func isDisclaimer(key: String) -> Bool {
        guard let first = key.first, disclaimerStarts.contains(first) else { return false }
        return disclaimerPrefixes.contains { key.hasPrefix($0) }
    }

    private static let disclaimerPrefixes = [
        "this email and any", "this e-mail and any", "this message and any", "this email is confidential",
        "this e-mail is confidential", "this message is confidential", "this communication is confidential",
        "this email may contain confidential", "this e-mail may contain confidential", "confidentiality notice",
        "confidentiality note", "disclaimer:", "the information contained in this", "the information in this email",
        "if you are not the intended recipient", "important notice:", "legal disclaimer",
    ]

    private static let disclaimerStarts = Set(disclaimerPrefixes.compactMap(\.first))

    /// The last sign-off line (“Best,”, “Kind regards,”, “Thanks!”) among the message's last lines, never its first.
    private static func valedictionIndex(in lines: [Line]) -> Int? {
        let filled = lines.indices.filter { !lines[$0].isBlank }
        guard filled.count > 1 else { return nil }
        for index in filled.suffix(14).reversed() where index != filled.first {
            if isValediction(key: lines[index].key) { return index }
        }
        return nil
    }

    static func isValediction(_ line: String) -> Bool { isValediction(key: key(line)) }

    private static func isValediction(key: String) -> Bool {
        guard key.count <= 24 else { return false }
        var words = key
        while let last = words.last, ",.!-\u{2014}".contains(last) { words.removeLast() }
        words = words.trimmingCharacters(in: .whitespaces)
        return valedictions.contains(words)
    }

    private static let valedictions: Set<String> = [
        "best", "best regards", "kind regards", "warm regards", "warmest regards", "regards", "many thanks", "thanks",
        "thank you", "thanks so much", "thanks again", "thanks in advance", "thank you so much", "cheers", "all the best",
        "best wishes", "with best wishes", "sincerely", "yours sincerely", "sincerely yours", "yours", "talk soon",
        "speak soon", "take care", "warmly", "thx", "br", "kr", "with thanks", "many thanks again", "with kind regards",
        "with best regards", "love", "see you", "see you soon", "have a great day", "have a good weekend",
        "have a great weekend", "ta", "cordially", "respectfully",
    ]

    /// A name under a sign-off: a few words of letters, no digits, no address, no title separators.
    private static func isNameLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let words = trimmed.split(separator: " ")
        guard (1...4).contains(words.count), trimmed.count <= 40, trimmed.first?.isLetter == true else { return false }
        return !trimmed.contains { $0.isNumber || "@|:/".contains($0) }
    }

    /// A trailing card with no sign-off above it: phone, fax, web and address lines at the very end.
    private static func dropTrailingContactLines(_ lines: inout [Line]) {
        while let last = lines.last, last.isBlank || isContactLine(key: last.key) {
            lines.removeLast()
        }
    }

    static func isContactLine(_ line: String) -> Bool { isContactLine(key: key(line)) }

    private static func isContactLine(key text: String) -> Bool {
        guard !text.isEmpty, text.count <= 120 else { return false }
        if contactPrefixes.contains(where: { text.hasPrefix($0) }) { return true }
        if text.contains(" | ") { return true }
        return text.filter(\.isNumber).count >= 7 && text.split(separator: " ").count <= 8
    }

    private static let contactPrefixes = ["m:", "t:", "p:", "f:", "e:", "w:", "tel", "mobile", "phone", "cell", "fax",
                                          "www.", "http://", "https://", "office:", "direct:"]

    /// “Hi Alex,” on its own line, or leading the first line (“Hi Alex, can we…”): up to its first comma, exclamation
    /// mark or colon, a few words in.
    private static func dropGreeting(_ lines: inout [Line]) {
        guard let first = lines.firstIndex(where: { !$0.isBlank }) else { return }
        let line = lines[first].text.trimmingCharacters(in: .whitespaces)
        let text = lines[first].key
        guard greetingWords.contains(where: { text == $0 || text.hasPrefix($0 + " ") || text.hasPrefix($0 + ",")
            || text.hasPrefix($0 + "!") }) else { return }
        let characters = Array(line)
        guard let stop = characters.prefix(40).firstIndex(where: { $0 == "," || $0 == "!" || $0 == ":" }) else {
            // “Hi Alex” with nothing after it.
            if text.count <= 30, !text.contains(where: { ".?".contains($0) }) { lines.remove(at: first) }
            return
        }
        let rest = String(characters[(stop + 1)...]).trimmingCharacters(in: .whitespaces)
        if rest.isEmpty {
            lines.remove(at: first)
        } else {
            lines[first] = Line(Substring(rest.prefix(1).uppercased() + rest.dropFirst()))
        }
    }

    private static let greetingWords = ["hi", "hello", "hey", "dear", "hiya", "morning", "good morning", "good afternoon",
                                        "good evening", "greetings", "hi all", "hello all", "hi there", "hey there"]

    /// An opening sentence that only greets (“Hope you had a good weekend!”, “Thanks for getting back to me.”), when
    /// something follows it.
    private static func dropOpeningPleasantry(_ lines: inout [Line]) {
        guard let first = lines.firstIndex(where: { !$0.isBlank }) else { return }
        let opening = lines[first].key
        guard let initial = opening.first, pleasantryStarts.contains(initial),
              pleasantries.contains(where: { opening.hasPrefix($0) }) else { return }
        let line = lines[first].text.trimmingCharacters(in: .whitespaces)
        let sentence = ReplyContextBuilder.sentences(of: line).first ?? ""
        guard sentence.count <= 90 else { return }
        let rest = String(line.dropFirst(sentence.count)).trimmingCharacters(in: .whitespaces)
        let othersFollow = !rest.isEmpty || lines[(first + 1)...].contains { !$0.isBlank }
        guard othersFollow else { return }
        if rest.isEmpty { lines.remove(at: first) } else { lines[first] = Line(Substring(rest)) }
    }

    private static let pleasantries = [
        "hope you", "i hope you", "hope this", "i hope this", "hope all", "i hope all", "hope everything", "i hope everything",
        "hope your", "i hope your", "thanks for your email", "thanks for the email", "thanks for your message",
        "thanks for the message", "thanks for your reply", "thanks for the reply", "thanks for your note",
        "thanks for the note", "thanks for getting back", "thank you for your email", "thank you for the email",
        "thank you for your message", "thank you for your reply", "thank you for getting back", "thanks for the quick reply",
        "thanks for the quick response", "sorry for the slow", "sorry for the late", "sorry for the delayed",
        "apologies for the slow", "apologies for the late", "apologies for the delayed", "good to hear from you",
        "great to hear from you", "nice to hear from you", "happy friday", "happy monday", "i trust you",
    ]

    private static let pleasantryStarts = Set(pleasantries.compactMap(\.first))
}
