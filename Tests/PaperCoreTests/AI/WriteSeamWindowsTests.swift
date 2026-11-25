import XCTest
@testable import PaperCore

/// The few words beside a selection a rewrite may change: up to three a side, on the selection's line, inside the user's
/// own text, never into a link, an address or fence syntax.
final class WriteSeamWindowsTests: XCTestCase {
    /// The windows around the one `[…]` in `marked`, as text: (before gap, before window, after gap, after window).
    private func windows(_ marked: String, own: NSRange? = nil, blocked: (Int) -> Bool = { _ in false })
        -> (gapBefore: String, before: String, gapAfter: String, after: String) {
        let open = (marked as NSString).range(of: "[").location
        let text = marked.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "") as NSString
        let close = (marked as NSString).range(of: "]").location - 1
        let core = NSRange(location: open, length: close - open)
        let found = WriteSeamWindows.find(in: text, core: core, own: own ?? NSRange(location: 0, length: text.length), blocked: blocked)
        let gapBefore = text.substring(with: NSRange(location: core.location - found.beforeGap, length: found.beforeGap))
        let before = text.substring(with: NSRange(location: core.location - found.beforeGap - found.beforeWindow, length: found.beforeWindow))
        let gapAfter = text.substring(with: NSRange(location: NSMaxRange(core), length: found.afterGap))
        let after = text.substring(with: NSRange(location: NSMaxRange(core) + found.afterGap, length: found.afterWindow))
        return (gapBefore, before, gapAfter, after)
    }

    func testUpToThreeWordsASideWithThePunctuationBetweenThem() {
        let found = windows("It has room for 40 people and [we can has the garden too], so the March dates work.")
        XCTAssertEqual(found.before, "40 people and")
        XCTAssertEqual(found.gapBefore, " ")
        XCTAssertEqual(found.gapAfter, "")
        XCTAssertEqual(found.after, ", so the March", "punctuation inside the window")
        XCTAssertEqual(windows("Fine, [thanks].").after, "", "punctuation alone is no window")
        XCTAssertEqual(windows("Fine, [thanks].").before, "Fine,")
    }

    func testAWindowStaysOnTheSelectionsLine() {
        for breakCharacter in ["\n", "\r", "\u{2028}", "\u{2029}"] {
            let found = windows("One two three\(breakCharacter)four [five] six\(breakCharacter)seven eight")
            XCTAssertEqual(found.before, "four", breakCharacter.debugDescription)
            XCTAssertEqual(found.after, "six", breakCharacter.debugDescription)
        }
        let start = windows("Hello there\n[John] is coming tomorrow.")
        XCTAssertEqual(start.before, "", "a selection that starts a line has nothing before it to join")
        XCTAssertEqual(start.gapBefore, "")
        XCTAssertEqual(start.after, "is coming tomorrow")
        XCTAssertEqual(start.gapAfter, " ")
    }

    func testAWindowStopsAtAPictureABlockedIndexAndTheOwnText() {
        let picture = windows("one two\u{FFFC}three [four] five\u{FFFC}six")
        XCTAssertEqual(picture.before, "three")
        XCTAssertEqual(picture.after, "five")
        // “link” is blocked: the window starts after it.
        let text = "see the link here [now] ok"
        let link = (text as NSString).range(of: "link")
        let blocked = windows(text, blocked: { NSLocationInRange($0, link) })
        XCTAssertEqual(blocked.before, "here")
        // The own text ends before the signature: the after window never passes it.
        let marked = "I can [come] by later\n-- \nAlex"
        let own = NSRange(location: 0, length: ("I can come by" as NSString).length)
        XCTAssertEqual(windows(marked, own: own).after, "by")
        XCTAssertEqual(windows("[Hello] there", own: NSRange(location: 0, length: 11)).before, "", "the own text's start")
    }

    func testALongGapOrOneHoldingALineBreakGivesNoWindow() {
        let wide = windows("one two         [three]         four")
        XCTAssertEqual(wide.before, "")
        XCTAssertEqual(wide.gapBefore, "", "nine blanks are layout, not a joint")
        XCTAssertEqual(wide.after, "")
        let tab = windows("one two\t[three]\u{00A0}four")
        XCTAssertEqual(tab.before, "one two")
        XCTAssertEqual(tab.gapBefore, "\t")
        XCTAssertEqual(tab.gapAfter, "\u{00A0}")
        let broken = windows("one two \n [three] \n four")
        XCTAssertEqual(broken.before, "")
        XCTAssertEqual(broken.after, "")
    }

    func testAMidWordEdgeCountsItsWord() {
        let found = windows("We were go[ing to the par]k with them")
        XCTAssertEqual(found.before, "We were go")
        XCTAssertEqual(found.after, "k with them")
    }

    func testAWholeParagraphSelectedHasNoWindows() {
        let found = windows("First paragraph here.\n\n[Second paragraph, all of it.]\n\nThird one.")
        XCTAssertEqual(found.before, "")
        XCTAssertEqual(found.after, "")
        XCTAssertEqual(windows("[All of it.]").after, "")
    }

    func testScriptsWithoutSpacesAreCutAtTheirWords() {
        let chinese = windows("我们明天[去公园]散步吧")
        XCTAssertFalse(chinese.before.isEmpty)
        XCTAssertTrue("我们明天".hasSuffix(chinese.before))
        XCTAssertFalse(chinese.after.isEmpty)
        XCTAssertTrue("散步吧".hasPrefix(chinese.after))
        let thai = windows("ฉันชอบ[กินข้าว]ผัดมาก")
        XCTAssertFalse(thai.before.isEmpty)
        XCTAssertTrue("ฉันชอบ".hasSuffix(thai.before))
        XCTAssertTrue("ผัดมาก".hasPrefix(thai.after))
    }

    func testAWindowIsAtMost48Units() {
        let long = String(repeating: "x", count: 30)
        let found = windows("aa \(long) \(long) [sel] \(long) \(long) bb")
        XCTAssertEqual(found.before, long, "a word that would pass 48 is not taken")
        XCTAssertEqual(found.after, long)
        XCTAssertEqual(windows("\(String(repeating: "y", count: 49)) [sel]").before, "")
    }

    func testALinkAnAddressOrAPathGivesNoWindow() {
        let url = "https://example.test/a/very/long/path/that/goes/on/and/onwards"
        XCTAssertEqual((url as NSString).length, 62)
        XCTAssertEqual(windows("see \(url) [now] ok").before, "")
        XCTAssertEqual(windows("[now] \(url)").after, "")
        XCTAssertEqual(windows("write to dana@example.test [today]").before, "", "an address is no window")
        XCTAssertEqual(windows("the well-known [fact]").before, "the well-known", "a hyphenated word is never cut")
        XCTAssertEqual(windows("[I can] come tomorrow.").after, "come tomorrow", "a full stop ends a sentence")
    }

    func testAWindowHoldingFenceSyntaxGivesNone() {
        XCTAssertEqual(windows("a <<<b [c]").before, "")
        XCTAssertEqual(windows("[c] d>>> e").after, "")
    }

    func testNothingOutsideTheTextOrAnEmptySelection() {
        let text = "abc" as NSString
        XCTAssertTrue(WriteSeamWindows.find(in: text, core: NSRange(location: 1, length: 5), own: NSRange(location: 0, length: 3),
                                            blocked: { _ in false }) == (0, 0, 0, 0))
        XCTAssertTrue(WriteSeamWindows.find(in: text, core: NSRange(location: 0, length: 1), own: NSRange(location: 1, length: 2),
                                            blocked: { _ in false }) == (0, 0, 0, 0))
    }
}
