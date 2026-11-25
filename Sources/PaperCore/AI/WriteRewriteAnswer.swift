import Foundation

/// How a rewrite's answer in the DRAFT form is read (spec §5.56): the rewritten part, then at most one line per side,
/// `<<<BEFORE code>>>new words<<<END BEFORE code>>>` and `<<<AFTER code>>>new words<<<END AFTER code>>>`, for the
/// words right beside the selection the request offered (`WriteRewriteFrame`).
///
/// `split` reads the whole answer so far each time more of it arrives, as `WriteSubjectLine` does: providers deliver
/// deltas cut anywhere, the whole text at once, or the whole text after deltas, and reading the whole again gives the
/// same for all three. Only markers that carry the request's code count, so neither the user's draft nor mail can forge
/// one; a marker without the code, or with another, is ordinary text.
///
/// The guards (`stripEchoes`, `repeatsDraft`) read the final part against what was sent, so an answer that copies the
/// draft never lands over it.
public enum WriteRewriteAnswer {
    public enum Side: Sendable, Hashable, CaseIterable {
        case before, after
    }

    public struct Split: Sendable, Hashable {
        /// The rewritten part, to show and to land: every code-bound marker and seam line out. While streaming, what
        /// may still turn out to be a marker, or a seam line whose end has not come, is held back.
        public var part: String
        /// The new words proposed for each side's window, trimmed of spaces and tabs; nil when none, or the side came
        /// twice (`conflicted`).
        public var before: String?
        public var after: String?
        /// The sides a complete seam line came for, conflicted ones included.
        public var proposed: Set<Side>
        /// The sides more than one seam line came for: neither is taken.
        public var conflicted: Set<Side>
        /// A seam line came that was cut short or malformed (no end on its line): it was dropped.
        public var malformed: Bool

        public init(part: String, before: String? = nil, after: String? = nil, proposed: Set<Side> = [],
                    conflicted: Set<Side> = [], malformed: Bool = false) {
            self.part = part
            self.before = before
            self.after = after
            self.proposed = proposed
            self.conflicted = conflicted
            self.malformed = malformed
        }

        /// Whether any seam line came, well formed or not.
        public var cameWithSeamLines: Bool { !proposed.isEmpty || malformed }
    }

    /// The longest run held back at the end while it may still become a marker.
    static let maxHeld = 40

    // MARK: Splitting

    /// Splits `raw`, the answer so far (`final`: all of it), for a request whose fence code is `fence`.
    public static func split(_ raw: String, final: Bool, fence: String) -> Split {
        guard !fence.isEmpty else { return Split(part: raw) }
        let bytes = Array(raw.utf8)
        let code = Array(fence.lowercased().utf8)
        let count = bytes.count

        // Every code-bound marker, in order; and a start of one cut off by the end of what has come.
        var markers: [Marker] = []
        var partialStart: Int?
        var index = 0
        while index < count {
            guard bytes[index] == lessThan else {
                index += 1
                continue
            }
            switch parseMarker(bytes, at: index, code: code) {
            case .marker(let marker):
                markers.append(marker)
                index = marker.end
            case .partial:
                if count - index <= maxHeld { partialStart = index }
                index = count
            case .none:
                index += 1
            }
        }

        var limit = final ? count : (partialStart ?? count)
        var kept: [UInt8] = []
        kept.reserveCapacity(count)
        var selectionOpen: Int?
        var selectionEnd: Int?
        var proposals: [Side: String] = [:]
        var proposed: Set<Side> = []
        var conflicted: Set<Side> = []
        var malformed = false
        var position = 0
        var at = 0
        reading: while at < markers.count {
            let marker = markers[at]
            guard marker.start < limit else { break }
            kept.append(contentsOf: bytes[position..<marker.start])
            switch marker.name {
            case .before where !marker.isEnd, .after where !marker.isEnd:
                let side: Side = marker.name == .before ? .before : .after
                let lineEnd = firstLineBreak(in: bytes, from: marker.end)
                if at + 1 < markers.count {
                    let next = markers[at + 1]
                    if next.isEnd, next.name == marker.name, next.start < (lineEnd ?? count), next.end <= limit {
                        let words = String(decoding: bytes[marker.end..<next.start], as: UTF8.self)
                            .trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
                        if proposed.contains(side) {
                            conflicted.insert(side)
                            proposals[side] = nil
                        } else {
                            proposed.insert(side)
                            proposals[side] = words
                        }
                        position = Self.endOfSeamLine(in: bytes, from: next.end, limit: limit, kept: kept)
                        at += 2
                        continue reading
                    }
                }
                guard let lineEnd else {
                    if final {
                        malformed = true
                        position = count
                        at = markers.count
                        continue reading
                    }
                    // Its line has not ended: what follows may still close it. Nothing of it shows meanwhile.
                    limit = marker.start
                    position = marker.start
                    break reading
                }
                malformed = true
                position = Self.endOfSeamLine(in: bytes, from: lineEnd, limit: limit, kept: kept)
                at += 1
                while at < markers.count, markers[at].start < lineEnd { at += 1 }
            case .selection:
                if !marker.isEnd {
                    if selectionOpen == nil { selectionOpen = kept.count }
                } else if selectionOpen != nil, selectionEnd == nil {
                    selectionEnd = kept.count
                }
                position = marker.end
                at += 1
            default:
                position = marker.end
                at += 1
            }
        }
        if position < limit { kept.append(contentsOf: bytes[position..<limit]) }

        var part: ArraySlice<UInt8> = kept[...]
        if let open = selectionOpen {
            if let end = selectionEnd {
                part = kept[open..<end]
            } else if kept[..<open].allSatisfy(isASCIIBlank) {
                part = kept[open...]
            }
        }
        let cut = cuttingMiswrittenMarkers(Array(part), code: code)
        part = cut.bytes[...]
        if cut.found { malformed = true }
        if !final {
            // A “<<<” on the line still coming may be a marker written wrongly, whose code has not come yet: it shows
            // once its line ends, or at the end.
            let lineStart = (part.lastIndex(where: isLineBreak) ?? part.startIndex - 1) + 1
            if let open = firstIndex(of: markerOpening, in: part, from: lineStart) { part = part[..<open] }
            // A line break the part ends on may be the one before a seam line: it shows once more comes after it, and
            // the session trims the part's ends at landing anyway.
            while let last = part.last, last == lineFeed || last == carriageReturn { part = part.dropLast() }
        }
        return Split(part: String(decoding: part, as: UTF8.self), before: proposals[.before], after: proposals[.after],
                     proposed: proposed, conflicted: conflicted, malformed: malformed)
    }

    /// Where reading goes on after a seam block ending at `end` (or a malformed seam line, whose rest of the line goes,
    /// ending at its line break). A block that stands on a line of its own (nothing but blanks before it on its line, in
    /// what is `kept`, and after it up to its line break) takes the rest of that line and its line break with it, so a
    /// seam line the model wrote first leaves the part to start on its own first line, in place, as it streams.
    /// Otherwise `end`.
    private static func endOfSeamLine(in bytes: [UInt8], from end: Int, limit: Int, kept: [UInt8]) -> Int {
        let lineStart = (kept.lastIndex(where: isLineBreak) ?? -1) + 1
        guard kept[lineStart...].allSatisfy({ $0 == space || $0 == tab }) else { return end }
        var index = end
        while index < limit, bytes[index] == space || bytes[index] == tab { index += 1 }
        guard index < limit else { return index }
        if bytes[index] == carriageReturn {
            index += 1
            if index < limit, bytes[index] == lineFeed { index += 1 }
            return index
        }
        return bytes[index] == lineFeed ? index + 1 : end
    }

    /// `part` without the markers the model wrote wrongly (“<<<AFTER code>>” with two “>”, “<<< AFTER code >>>”,
    /// “<<<AFTER: code>>>”), which `parseMarker` does not take for markers. The request's code comes only in its markers:
    /// every piece of the request was stripped of it, so text that holds it is a marker. From the run of “<” before the
    /// code on its line (or the line's start when there is none) to the line's end goes; a line that held nothing else
    /// goes with its line break. `found` says that one was cut: a seam line that was malformed.
    static func cuttingMiswrittenMarkers(_ part: [UInt8], code: [UInt8]) -> (bytes: [UInt8], found: Bool) {
        guard !code.isEmpty else { return (part, false) }
        var bytes = part
        var found = false
        var from = 0
        while let at = firstIndex(ofCaseless: code, in: bytes, from: from) {
            found = true
            var lineStart = at
            while lineStart > 0, !isLineBreak(bytes[lineStart - 1]) { lineStart -= 1 }
            var lineEnd = at + code.count
            while lineEnd < bytes.count, !isLineBreak(bytes[lineEnd]) { lineEnd += 1 }
            var start = lineStart
            if let less = bytes[lineStart..<at].lastIndex(of: lessThan) {
                start = less
                while start > lineStart, bytes[start - 1] == lessThan { start -= 1 }
            }
            if bytes[lineStart..<start].allSatisfy({ $0 == space || $0 == tab }) {
                start = lineStart
                if lineEnd < bytes.count {
                    let crlf = bytes[lineEnd] == carriageReturn && lineEnd + 1 < bytes.count && bytes[lineEnd + 1] == lineFeed
                    lineEnd += crlf ? 2 : 1
                }
            }
            bytes.removeSubrange(start..<lineEnd)
            from = start
        }
        return (bytes, found)
    }

    /// The first place from `from` where `word` (lowercase ASCII) stands in `bytes`, in any letter case.
    private static func firstIndex(ofCaseless word: [UInt8], in bytes: [UInt8], from: Int) -> Int? {
        guard word.count <= bytes.count else { return nil }
        var index = from
        while index + word.count <= bytes.count {
            if match(word, in: bytes, at: index) == true { return index }
            index += 1
        }
        return nil
    }

    /// The first place from `from` where `run` stands in `bytes`.
    private static func firstIndex(of run: [UInt8], in bytes: ArraySlice<UInt8>, from: Int) -> Int? {
        var index = from
        while index + run.count <= bytes.endIndex {
            if bytes[index..<(index + run.count)].elementsEqual(run) { return index }
            index += 1
        }
        return nil
    }

    // MARK: Guards

    /// `part` without the draft it restates at either end: where its first words are the last words sent before the
    /// selection (two or more), or its last words the first sent after it, those words go, with the punctuation and
    /// blanks that join them to the rest (but for the mark that ends a sentence the selection ended). A whole draft
    /// given back with the rewrite in place comes back to the part. Words the selection itself begins or ends with are
    /// its own, never an echo. Nil when nothing but blanks would be left: the answer was the draft.
    ///
    /// Words that match across a sentence's end may play another part there: in “I spoke to John Smith. [He said
    /// yes.]”, the answer “John Smith said yes.” names him, and restates nothing. So at the start, matching words are an
    /// echo only where the selection carries on the sentence before it (no sentence end or line break between the last
    /// word before it and its first word), where they begin a sentence or a line of the text before, where they are all
    /// of the text before, or where the answer ends a sentence after them as the text before does (“the whole team. We
    /// can have …”); the end mirrors it.
    public static func stripEchoes(_ part: String, frame: WriteRewriteFrame) -> String? {
        var ids = TokenIDs()
        let tokens = Self.tokens(of: part)
        guard !tokens.isEmpty else { return part }
        let partIDs = tokens.map { ids.id($0.word) }
        let sentBefore = frame.sentBefore
        let sentAfter = frame.sentAfter
        let beforeTokens = Self.tokens(of: sentBefore)
        let afterTokens = Self.tokens(of: sentAfter)
        let selectionTokens = Self.tokens(of: frame.selection)
        let before = beforeTokens.map { ids.id($0.word) }
        let after = afterTokens.map { ids.id($0.word) }
        let selection = selectionTokens.map { ids.id($0.word) }

        // What lies between the last word before the selection and its first, and between its last and the first after.
        let joinBefore = String(sentBefore[(beforeTokens.last?.range.upperBound ?? sentBefore.startIndex)...])
            + frame.selection[..<(selectionTokens.first?.range.lowerBound ?? frame.selection.endIndex)]
        let joinAfter = String(frame.selection[(selectionTokens.last?.range.upperBound ?? frame.selection.startIndex)...])
            + sentAfter[..<(afterTokens.first?.range.lowerBound ?? sentAfter.endIndex)]
        let continuesBefore = !holdsSentenceBoundary(joinBefore)
        let continuesAfter = !holdsSentenceBoundary(joinAfter)

        var first = 0
        if let k = longestEcho(prefixOf: partIDs[...], suffixOf: before, own: selection[...], allowed: { k in
            // The echo is the last k words before: they begin a sentence or a line there, are all of them, or end a
            // sentence in the answer as they do there.
            let start = before.count - k
            let next = k < tokens.count ? tokens[k].range.lowerBound : part.endIndex
            return continuesBefore || start == 0
                || holdsSentenceBoundary(sentBefore[beforeTokens[start - 1].range.upperBound..<beforeTokens[start].range.lowerBound])
                || holdsSentenceBoundary(part[tokens[k - 1].range.upperBound..<next])
        }) {
            first = k
        }
        var last = tokens.count
        if first < tokens.count,
           let k = longestEcho(prefixOf: ArraySlice(partIDs[first...].reversed()), suffixOf: Array(after.reversed()),
                               own: ArraySlice(selection.reversed()), allowed: { k in
                                   // The echo is the first k words after: they end a sentence or a line there, are all
                                   // of them, or begin a sentence in the answer as they do there.
                                   let echoStart = tokens.count - k
                                   let previous = echoStart > 0 ? tokens[echoStart - 1].range.upperBound : part.startIndex
                                   return continuesAfter || k == after.count
                                       || holdsSentenceBoundary(sentAfter[afterTokens[k - 1].range.upperBound..<afterTokens[k].range.lowerBound])
                                       || holdsSentenceBoundary(part[previous..<tokens[echoStart].range.lowerBound])
                               }) {
            last = tokens.count - k
        }
        guard first < last else { return nil }
        let start = first == 0 ? part.startIndex : tokens[first].range.lowerBound
        var end = last == tokens.count ? part.endIndex : tokens[last - 1].range.upperBound
        if last < tokens.count {
            // A selection that ended a sentence keeps its end: “It is big. The garden is too.” is “It is big.”, while
            // “too, so the March dates work.” is “too”, the comma being the text after's.
            let mark = part[end..<tokens[last].range.lowerBound].prefix { !$0.isWhitespace }
            let selectionEnd = frame.selection[(selectionTokens.last?.range.upperBound ?? frame.selection.startIndex)...]
            if holdsSentenceBoundary(selectionEnd), holdsSentenceBoundary(mark) { end = mark.endIndex }
        }
        let kept = part[start..<end]
        guard kept.contains(where: { !$0.isWhitespace }) else { return nil }
        return String(kept)
    }

    /// Whether `text`, what lies between two words, ends a sentence or a line.
    static func holdsSentenceBoundary<S: StringProtocol>(_ text: S) -> Bool {
        text.unicodeScalars.contains { sentenceBoundaries.contains($0) }
    }

    private static let sentenceBoundaries: Set<Unicode.Scalar> = [
        ".", "!", "?", "\u{2026}", "\u{3002}", "\u{FF01}", "\u{FF1F}",
        "\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}",
    ]

    /// The fewest consecutive words of the draft an answer may repeat before it is taken for a copy of it.
    public static let repeatRun = 12

    /// Whether `part` holds a run of `repeatRun` words that was also sent around the selection, and that neither the
    /// selection nor the instruction holds: the model copied the draft into its answer, which would land over the part
    /// and so put the draft into it twice.
    public static func repeatsDraft(_ part: String, frame: WriteRewriteFrame, instruction: String) -> Bool {
        var ids = TokenIDs()
        let around = (tokens(of: frame.sentBefore) + tokens(of: frame.sentAfter)).map { ids.id($0.word) }
        guard around.count >= repeatRun else { return false }
        let partIDs = tokens(of: part).map { ids.id($0.word) }
        guard partIDs.count >= repeatRun else { return false }
        let own = grams(of: tokens(of: frame.selection).map { ids.id($0.word) })
            .union(grams(of: tokens(of: instruction).map { ids.id($0.word) }))
        let sent = grams(of: around)
        for start in 0...(partIDs.count - repeatRun) {
            let gram = Gram(ids: Array(partIDs[start..<(start + repeatRun)]))
            if sent.contains(gram), !own.contains(gram) { return true }
        }
        return false
    }

    // MARK: Words

    /// The words of `text` as the guards and `WriteJoin` compare them: the system's word boundaries in any script,
    /// lowercased, with ’ and ' alike.
    public static func words(of text: String) -> [String] {
        tokens(of: text).map(\.word)
    }

    struct Token {
        var word: String
        var range: Range<String.Index>
    }

    static func tokens(of text: String) -> [Token] {
        var tokens: [Token] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byWords) { word, range, _, _ in
            guard let word else { return }
            tokens.append(Token(word: word.lowercased().replacingOccurrences(of: "\u{2019}", with: "'"), range: range))
        }
        return tokens
    }

    /// Words as numbers, so runs of them compare and hash cheaply.
    private struct TokenIDs {
        private var ids: [String: Int] = [:]

        mutating func id(_ word: String) -> Int {
            if let id = ids[word] { return id }
            let id = ids.count
            ids[word] = id
            return id
        }
    }

    private struct Gram: Hashable {
        var ids: [Int]
    }

    private static func grams(of ids: [Int]) -> Set<Gram> {
        guard ids.count >= repeatRun else { return [] }
        var grams = Set<Gram>()
        for start in 0...(ids.count - repeatRun) { grams.insert(Gram(ids: Array(ids[start..<(start + repeatRun)]))) }
        return grams
    }

    /// The largest k ≥ 2 such that the first k words of `pattern` are the last k of `text`, are not also the first k
    /// words of `own`, and are `allowed`; nil when there is none. Linear: the longest such overlap is the state a
    /// Knuth–Morris–Pratt match of `pattern` ends `text` in, and every shorter one is a border of it.
    static func longestEcho(prefixOf pattern: ArraySlice<Int>, suffixOf text: [Int], own: ArraySlice<Int>,
                            allowed: (Int) -> Bool = { _ in true }) -> Int? {
        let pattern = Array(pattern)
        let own = Array(own)
        guard pattern.count >= 2, text.count >= 2 else { return nil }
        var failure = [Int](repeating: 0, count: pattern.count)
        var length = 0
        for index in 1..<pattern.count {
            while length > 0, pattern[index] != pattern[length] { length = failure[length - 1] }
            if pattern[index] == pattern[length] { length += 1 }
            failure[index] = length
        }
        var state = 0
        for word in text {
            if state == pattern.count { state = failure[state - 1] }
            while state > 0, word != pattern[state] { state = failure[state - 1] }
            if word == pattern[state] { state += 1 }
        }
        var k = state
        while k >= 2 {
            let isOwn = k <= own.count && own[0..<k] == pattern[0..<k]
            if !isOwn, allowed(k) { return k }
            k = failure[k - 1]
        }
        return nil
    }

    // MARK: Markers

    enum Name: CaseIterable {
        case before, after, selection, draft, conversation, notes, message, forwarded

        var bytes: [UInt8] {
            switch self {
            case .before: return Array("before".utf8)
            case .after: return Array("after".utf8)
            case .selection: return Array("selection".utf8)
            case .draft: return Array("draft".utf8)
            case .conversation: return Array("conversation".utf8)
            case .notes: return Array("notes".utf8)
            case .message: return Array("message".utf8)
            case .forwarded: return Array("forwarded".utf8)
            }
        }
    }

    struct Marker {
        var start: Int
        var end: Int
        var isEnd: Bool
        var name: Name
    }

    enum Parse {
        case marker(Marker)
        /// What has come so far is the start of a marker, cut off by the end.
        case partial
        case none
    }

    private static let lessThan = UInt8(ascii: "<")
    private static let markerOpening = Array("<<<".utf8)
    private static let tab = UInt8(ascii: "\t")
    private static let greaterThan = UInt8(ascii: ">")
    private static let space = UInt8(ascii: " ")
    private static let lineFeed = UInt8(ascii: "\n")
    private static let carriageReturn = UInt8(ascii: "\r")
    private static let endWord = Array("end ".utf8)

    /// The code-bound marker at `start`: `<<<`, an optional `END `, a name, one or more spaces, the code, `>>>`, in ASCII
    /// and any letter case.
    static func parseMarker(_ bytes: [UInt8], at start: Int, code: [UInt8]) -> Parse {
        let count = bytes.count
        var index = start
        for _ in 0..<3 {
            guard index < count else { return .partial }
            guard bytes[index] == lessThan else { return .none }
            index += 1
        }
        var isEnd = false
        switch match(endWord, in: bytes, at: index) {
        case .some(true):
            isEnd = true
            index += endWord.count
        case .none:
            // “<<<”, “<<<E”, “<<<EN”: the start of END (no name starts so), cut off by the end.
            return .partial
        case .some(false):
            break
        }
        var found: Name?
        for name in Name.allCases {
            switch match(name.bytes, in: bytes, at: index) {
            case .some(true): found = name
            case .none: return .partial
            case .some(false): continue
            }
            if found != nil { break }
        }
        guard let name = found else { return .none }
        index += name.bytes.count
        var spaces = 0
        while index < count, bytes[index] == space {
            spaces += 1
            index += 1
        }
        guard index < count else { return .partial }
        guard spaces > 0 else { return .none }
        switch match(code, in: bytes, at: index) {
        case .some(true): index += code.count
        case .none: return .partial
        case .some(false): return .none
        }
        for _ in 0..<3 {
            guard index < count else { return .partial }
            guard bytes[index] == greaterThan else { return .none }
            index += 1
        }
        return .marker(Marker(start: start, end: index, isEnd: isEnd, name: name))
    }

    /// Whether `word` (lowercase ASCII) is at `index`, in any case: true, false, or nil when the bytes end before it
    /// does while agreeing so far.
    private static func match(_ word: [UInt8], in bytes: [UInt8], at index: Int) -> Bool? {
        for (offset, expected) in word.enumerated() {
            let at = index + offset
            guard at < bytes.count else { return nil }
            var byte = bytes[at]
            if (0x41...0x5A).contains(byte) { byte += 0x20 }
            guard byte == expected else { return false }
        }
        return true
    }

    private static func firstLineBreak(in bytes: [UInt8], from index: Int) -> Int? {
        var at = index
        while at < bytes.count {
            if bytes[at] == lineFeed || bytes[at] == carriageReturn { return at }
            at += 1
        }
        return nil
    }

    private static func isLineBreak(_ byte: UInt8) -> Bool {
        byte == lineFeed || byte == carriageReturn
    }

    private static func isASCIIBlank(_ byte: UInt8) -> Bool {
        byte == space || byte == lineFeed || byte == carriageReturn || byte == UInt8(ascii: "\t")
    }
}
