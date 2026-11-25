import Foundation

/// The few words right beside a selection that its rewrite may change so the part joins its sentence (spec §5.56): up
/// to three words on each side, on the selection's own line, inside the user's own text. Found on the main thread as the
/// user asks for the rewrite (`WriteSession.run`), from at most `maxRead` UTF-16 units on each side, so it costs the same
/// on a long body as on a short one.
///
/// What is found here is what the request may offer (`WriteRewriteFrame` can still hold a window back) and the only
/// range outside the selection the landed rewrite may ever change: a word that is not in a window cannot change,
/// whatever the model writes.
public enum WriteSeamWindows {
    /// The most words a window holds.
    public static let maxWords = 3
    /// The most UTF-16 units a window holds: a word that would pass it is not taken.
    public static let maxLength = 48
    /// The longest run of blanks between the selection and its window: more is layout, not a joint.
    public static let maxGap = 8
    /// How far from the selection's edge a window is looked for.
    static let maxRead = 64

    /// The joint on each side of `core` in `text`: the blanks right beside it (`beforeGap`, `afterGap`) and the window of
    /// words beyond them (`beforeWindow`, `afterWindow`), as UTF-16 lengths measured outward from the core's edges.
    /// A gap is reported only where it joins the core to text on its own line, since only such a gap may be dropped at
    /// landing; a window of 0 is none. `blocked` is true at an index a window may not hold (a composer's link or
    /// picture); a window starts after the last such index, and ends before the first.
    public static func find(in text: NSString, core: NSRange, own: NSRange, blocked: (Int) -> Bool)
        -> (beforeGap: Int, beforeWindow: Int, afterGap: Int, afterWindow: Int) {
        guard own.location >= 0, own.location <= core.location, NSMaxRange(core) <= NSMaxRange(own),
              NSMaxRange(own) <= text.length else { return (0, 0, 0, 0) }
        let before = beforeSide(of: core, in: text, own: own, blocked: blocked)
        let after = afterSide(of: core, in: text, own: own, blocked: blocked)
        return (before.gap, before.window, after.gap, after.window)
    }

    // MARK: The two sides

    private static func beforeSide(of core: NSRange, in text: NSString, own: NSRange,
                                   blocked: (Int) -> Bool) -> (gap: Int, window: Int) {
        var gapStart = core.location
        while gapStart > own.location, core.location - gapStart <= maxGap, isGapBlank(text.character(at: gapStart - 1)) {
            gapStart -= 1
        }
        let gap = core.location - gapStart
        // A long run of blanks, the start of a line or of the user's text: nothing there to join to.
        guard gap <= maxGap, gapStart > own.location, !isLineBreak(text.character(at: gapStart - 1)) else { return (0, 0) }

        var regionStart = gapStart
        while regionStart > own.location, gapStart - regionStart < maxRead {
            let index = regionStart - 1
            let unit = text.character(at: index)
            if isLineBreak(unit) || unit == 0xFFFC || blocked(index) { break }
            regionStart = index
        }
        // Never half of a letter outside the Basic Multilingual Plane.
        if regionStart < gapStart, UTF16.isTrailSurrogate(text.character(at: regionStart)) { regionStart += 1 }
        guard regionStart < gapStart else { return (gap, 0) }

        var starts: [Int] = []
        text.enumerateSubstrings(in: NSRange(location: regionStart, length: gapStart - regionStart),
                                 options: [.byWords, .reverse, .substringNotRequired]) { _, word, _, stop in
            guard gapStart - word.location <= maxLength else {
                stop.pointee = true
                return
            }
            starts.append(word.location)
            if starts.count == maxWords { stop.pointee = true }
        }
        // The most words that make a clean window: its outer edge never cuts into a link, an address or a path.
        for start in starts.reversed() {
            let window = NSRange(location: start, length: gapStart - start)
            if opensCleanly(at: start, in: text, own: own), holdsOnlyWords(text.substring(with: window)) {
                return (gap, window.length)
            }
        }
        return (gap, 0)
    }

    private static func afterSide(of core: NSRange, in text: NSString, own: NSRange,
                                  blocked: (Int) -> Bool) -> (gap: Int, window: Int) {
        let ownEnd = NSMaxRange(own)
        let coreEnd = NSMaxRange(core)
        var gapEnd = coreEnd
        while gapEnd < ownEnd, gapEnd - coreEnd <= maxGap, isGapBlank(text.character(at: gapEnd)) { gapEnd += 1 }
        let gap = gapEnd - coreEnd
        guard gap <= maxGap, gapEnd < ownEnd, !isLineBreak(text.character(at: gapEnd)) else { return (0, 0) }

        var regionEnd = gapEnd
        while regionEnd < ownEnd, regionEnd - gapEnd < maxRead {
            let unit = text.character(at: regionEnd)
            if isLineBreak(unit) || unit == 0xFFFC || blocked(regionEnd) { break }
            regionEnd += 1
        }
        if regionEnd > gapEnd, regionEnd < text.length, UTF16.isTrailSurrogate(text.character(at: regionEnd)) { regionEnd -= 1 }
        guard regionEnd > gapEnd else { return (gap, 0) }

        var ends: [Int] = []
        text.enumerateSubstrings(in: NSRange(location: gapEnd, length: regionEnd - gapEnd),
                                 options: [.byWords, .substringNotRequired]) { _, word, _, stop in
            guard NSMaxRange(word) - gapEnd <= maxLength else {
                stop.pointee = true
                return
            }
            ends.append(NSMaxRange(word))
            if ends.count == maxWords { stop.pointee = true }
        }
        for end in ends.reversed() {
            let window = NSRange(location: gapEnd, length: end - gapEnd)
            if closesCleanly(at: end, in: text, own: own), holdsOnlyWords(text.substring(with: window)) {
                return (gap, window.length)
            }
        }
        return (gap, 0)
    }

    // MARK: Edges

    /// Whether a window may start at `start`: at the user's text's start, after a blank, a line break or a picture, or
    /// after a letter or a mark that cannot be part of a link, an address, a path or a number (a word boundary in a
    /// script written without spaces is one). After “/”, “@”, “.” or the like, the window would cut a token in two.
    private static func opensCleanly(at start: Int, in text: NSString, own: NSRange) -> Bool {
        guard start > own.location else { return true }
        let unit = text.character(at: start - 1)
        if isGapBlank(unit) || isLineBreak(unit) || unit == 0xFFFC { return true }
        return !isGlue(unit)
    }

    /// Whether a window may end at `end`: the mirror of `opensCleanly`, where a full stop, a colon or a question mark
    /// that ends a sentence (a blank or the text's end after it) is no glue.
    private static func closesCleanly(at end: Int, in text: NSString, own: NSRange) -> Bool {
        let ownEnd = NSMaxRange(own)
        guard end < ownEnd else { return true }
        let unit = text.character(at: end)
        if isGapBlank(unit) || isLineBreak(unit) || unit == 0xFFFC || !isGlue(unit) { return true }
        guard sentenceEnds.contains(unit) else { return false }
        let next = end + 1
        return next >= ownEnd || isGapBlank(text.character(at: next)) || isLineBreak(text.character(at: next))
    }

    /// Words only: never fence syntax, and never an address or a path, whose parts a two-word change could alter.
    private static func holdsOnlyWords(_ window: String) -> Bool {
        !window.contains("<<<") && !window.contains(">>>") && !window.contains("@") && !window.contains("/")
            && !window.contains("\\")
    }

    // MARK: Characters

    /// The blanks a gap is made of: a space, a tab, a no-break space.
    public static func isGapBlank(_ unit: unichar) -> Bool {
        unit == 0x20 || unit == 0x09 || unit == 0xA0
    }

    static func isLineBreak(_ unit: unichar) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x85 || unit == 0x2028 || unit == 0x2029 || unit == 0x0B || unit == 0x0C
    }

    /// Marks that join the parts of one token (a link, an address, a path, a file name, a number) or open and close
    /// markup.
    private static let glue: Set<unichar> = Set("/\\:@._-~=&?#%+|<>".utf16)
    private static let sentenceEnds: Set<unichar> = Set(".:?".utf16)

    private static func isGlue(_ unit: unichar) -> Bool {
        glue.contains(unit)
    }
}
