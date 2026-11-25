import Foundation

/// The new words a rewrite's answer gave for the few words right beside the selection, as the writer accepted them
/// (spec §5.56): `AIWriter` yields them once, just before a good ending (`AIWriteEvent.join`), and the session lands
/// them with the part in the draft's one undo step. Nil for a side that stays as it is.
public struct WriteJoin: Sendable, Hashable {
    public var before: String?
    public var after: String?

    public init(before: String? = nil, after: String? = nil) {
        self.before = before
        self.after = after
    }

    /// The most words of a window an accepted proposal may change (a word replaced, added or taken away each count one).
    public static let maxEdits = 2
    /// How much longer than the window a proposal may be, in UTF-16 units, within `WriteSeamWindows.maxLength`.
    public static let maxGrowth = 16

    /// `proposed` as the new words for the window `offered`, or nil when nothing changes: the side was not offered, the
    /// proposal is the window as it was, or it fails a check. It stays on one line, holds no control, invisible or
    /// picture character and no fence syntax or code, is at most `WriteSeamWindows.maxLength` units and at most
    /// `maxGrowth` more than the window, and changes at most `maxEdits` of its words (case, punctuation and spacing
    /// are free). An empty proposal takes the window away, which changes each of its words.
    public static func accept(_ proposed: String, replacing offered: String?, fence: String) -> String? {
        guard let offered else { return nil }
        let words = proposed.trimmingCharacters(in: CharacterSet(charactersIn: " \t"))
        guard words != offered else { return nil }
        for scalar in words.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0D, 0x85, 0x2028, 0x2029, 0xFFFC: return nil
            default: break
            }
            if scalar.properties.generalCategory == .control || AIRedactor.isInvisible(scalar) { return nil }
        }
        guard !words.contains("<<<"), !words.contains(">>>") else { return nil }
        if !fence.isEmpty, words.range(of: fence, options: .caseInsensitive) != nil { return nil }
        guard words.utf16.count <= min(WriteSeamWindows.maxLength, offered.utf16.count + maxGrowth) else { return nil }
        guard editDistance(WriteRewriteAnswer.words(of: words), WriteRewriteAnswer.words(of: offered)) <= maxEdits else {
            return nil
        }
        return words
    }

    /// The Levenshtein distance between two lists of words.
    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
        var previous = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var current = [i + 1] + [Int](repeating: 0, count: b.count)
            for (j, right) in b.enumerated() {
                current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (left == right ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
