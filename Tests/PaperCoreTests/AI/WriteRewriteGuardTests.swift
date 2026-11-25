import XCTest
@testable import PaperCore

/// The guards on a rewrite's final part: a restated edge of the draft is taken off, and a part that copies the draft
/// fails rather than land over it.
final class WriteRewriteGuardTests: XCTestCase {
    private let frame = WriteRewriteFrame(
        lead: "Hi Priya,\n\nThanks for the notes. I checked the venue yesterday. It has room for ", before: "40 people and",
        gapBefore: " ", selection: "we can has the garden too", gapAfter: "", after: ", so the March", trail: " dates work.")

    func testARestatedEdgeIsTakenOff() {
        XCTAssertEqual(WriteRewriteAnswer.stripEchoes("people and we can have the garden too", frame: frame),
                       "we can have the garden too", "two words of the draft before it")
        XCTAssertEqual(WriteRewriteAnswer.stripEchoes("we can have the garden too, so the March dates work.", frame: frame),
                       "we can have the garden too", "the sentence's end after it")
        XCTAssertEqual(WriteRewriteAnswer.stripEchoes("I checked the venue yesterday. It has room for 40 people and we can have "
                                                      + "the garden too", frame: frame),
                       "we can have the garden too", "a whole sentence before it")
        XCTAssertEqual(WriteRewriteAnswer.stripEchoes("and we can have the garden too", frame: frame),
                       "and we can have the garden too", "one word is no echo")
    }

    func testAWholeDraftGivenBackWithTheRewriteInPlaceComesBackToThePart() {
        let echo = "Hi Priya,\n\nThanks for the notes. I checked the venue yesterday. It has room for 40 people and we can "
            + "have the garden too, so the March dates work."
        XCTAssertEqual(WriteRewriteAnswer.stripEchoes(echo, frame: frame), "we can have the garden too")
    }

    func testAPartThatWasTheDraftAloneFails() {
        XCTAssertNil(WriteRewriteAnswer.stripEchoes("It has room for 40 people and", frame: frame))
        XCTAssertNil(WriteRewriteAnswer.stripEchoes("40 people and, so the March dates work.", frame: frame))
    }

    func testTheSelectionsOwnWordsAreNoEcho() {
        let own = WriteRewriteFrame(lead: "We will meet at the ", gapBefore: "", selection: "the station at noon", trail: "")
        XCTAssertEqual(WriteRewriteAnswer.stripEchoes("at the station at noon", frame: own), "station at noon",
                       "the draft's last words, “at the”, restated")
        let starts = WriteRewriteFrame(lead: "Meet me at ", gapBefore: "", selection: "me at noon", trail: "")
        XCTAssertEqual(WriteRewriteAnswer.stripEchoes("me at noon sharp", frame: starts), "me at noon sharp",
                       "the selection began with them")
    }

    private let long = WriteRewriteFrame(
        lead: "We met on Monday to go over the plan for the spring offsite, and everyone agreed that the venue by the "
            + "river is the best choice for the whole team this year. ", selection: "we can has the garden",
        trail: " The budget is set and the dates are fixed.")

    func testAPartThatCopiesTheDraftFails() {
        let copy = "everyone agreed that the venue by the river is the best choice for the whole team, and we can have the garden"
        XCTAssertTrue(WriteRewriteAnswer.repeatsDraft(copy, frame: long, instruction: ""))
        XCTAssertFalse(WriteRewriteAnswer.repeatsDraft("we can have the garden as well", frame: long, instruction: ""))
        XCTAssertFalse(WriteRewriteAnswer.repeatsDraft(copy, frame: long,
                                                       instruction: "Say that everyone agreed that the venue by the river is the "
                                                           + "best choice for the whole team"),
                       "the user asked for those words")
        let ownWords = WriteRewriteFrame(lead: long.lead, selection: "everyone agreed that the venue by the river is the best "
                                         + "choice for the whole team", trail: "")
        XCTAssertFalse(WriteRewriteAnswer.repeatsDraft(copy, frame: ownWords, instruction: ""), "the selection held them")
    }

    func testAShortDraftIsNotChecked() {
        let short = WriteRewriteFrame(lead: "Hi Priya, ", selection: "see u thurs", trail: " Thanks.")
        XCTAssertFalse(WriteRewriteAnswer.repeatsDraft("Hi Priya, see you on Thursday. Thanks. Hi Priya, see you", frame: short,
                                                       instruction: ""))
    }

    func testTheGuardsAreFastOnALongDraft() {
        let sentence = "The quick brown fox jumps over the lazy dog near the river bank today. "
        let around = String(repeating: sentence, count: 120)
        let frame = WriteRewriteFrame(lead: String(around.prefix(6_000)), selection: "a part to rewrite here",
                                      trail: String(around.prefix(2_000)))
        let answer = String(repeating: "Something new and different, word by word, each time. ", count: 30)
        let clock = ContinuousClock()
        var slowest = Duration.zero
        for _ in 0..<5 {
            let elapsed = clock.measure {
                _ = WriteRewriteAnswer.stripEchoes(answer, frame: frame)
                _ = WriteRewriteAnswer.repeatsDraft(answer, frame: frame, instruction: "")
            }
            slowest = max(slowest, elapsed)
        }
        // Budget 5 ms; the suite runs alongside other builds, so the test allows headroom for a loaded machine.
        XCTAssertLessThan(slowest, .milliseconds(50))
    }
}
