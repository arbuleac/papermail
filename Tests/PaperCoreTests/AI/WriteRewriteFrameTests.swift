import XCTest
@testable import PaperCore

/// What a selection's rewrite sends of the draft around it: cleaned, cut for length, redacted at blanks where the body
/// is still what a mail link filled in, and the windows offered only as the field holds them.
final class WriteRewriteFrameTests: XCTestCase {
    private let fence = "1a2b3c4d"

    /// The ask for `marked`, the selection between “[” and “]”, its windows found as the app finds them.
    private func around(_ marked: String) -> (around: WriteAsk.Around, selection: String) {
        let open = (marked as NSString).range(of: "[").location
        let text = marked.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "") as NSString
        let close = (marked as NSString).range(of: "]").location - 1
        let core = NSRange(location: open, length: close - open)
        let own = NSRange(location: 0, length: text.length)
        let found = WriteSeamWindows.find(in: text, core: core, own: own, blocked: { _ in false })
        return (WriteAsk.Around(before: text.substring(to: core.location), after: text.substring(from: NSMaxRange(core)),
                                beforeGap: found.beforeGap, beforeWindow: found.beforeWindow,
                                afterGap: found.afterGap, afterWindow: found.afterWindow),
                text.substring(with: core))
    }

    private func frame(_ marked: String, redacts: Bool = false) -> WriteRewriteFrame {
        let (around, selection) = around(marked)
        return WriteRewriteFrame.make(around: around, selection: selection, redacts: redacts, fence: fence)
    }

    func testThePiecesAreTheDraftAroundTheSelection() {
        let made = frame("Thanks. It has room for 40 people and [we can has the garden too], so the March dates work.")
        XCTAssertEqual(made.lead, "Thanks. It has room for ")
        XCTAssertEqual(made.before, "40 people and")
        XCTAssertEqual(made.gapBefore, " ")
        XCTAssertEqual(made.selection, "we can has the garden too")
        XCTAssertEqual(made.gapAfter, "")
        XCTAssertEqual(made.after, ", so the March")
        XCTAssertEqual(made.trail, " dates work.")
        XCTAssertEqual(made.sentBefore + made.selection + made.sentAfter,
                       "Thanks. It has room for 40 people and we can has the garden too, so the March dates work.")
        XCTAssertTrue(made.offersWindow)
    }

    func testCleaningTakesOutInvisibleCharactersPicturesAndTheCodeAndFoldsEmptyLines() {
        let made = frame("Hi\u{200B} Priya,\r\n\r\n\r\n\r\nSee \u{FFFC}the 1A2B3C4D plan.\n\nI [can] come.\r\n\n\n\nBest")
        XCTAssertEqual(made.lead, "Hi Priya,\n\nSee the  plan.\n\n", "a reply's text loses its pictures too")
        XCTAssertEqual(made.before, "I")
        XCTAssertEqual(made.after, "come", "a full stop that ends the line is no glue")
        XCTAssertEqual(made.trail, ".\n\nBest")
        XCTAssertFalse((made.lead + made.trail).lowercased().contains(fence))
        let halves = frame("x 1a2b1a2b3c4d3c4d y [z]")
        XCTAssertFalse(halves.lead.lowercased().contains(fence), "taking the code out never joins it again")
    }

    func testAWindowThatCleaningWouldChangeIsNotOffered() {
        let invisible = frame("one two\u{200B}three [four] five")
        XCTAssertNil(invisible.before, "the field holds a mark the request would not send: the window is not those words")
        XCTAssertEqual(invisible.lead, "one twothree")
        XCTAssertEqual(invisible.gapBefore, " ")
        XCTAssertEqual(invisible.after, "five")
        let coded = frame("say 1a2b3c4d [now] ok")
        XCTAssertNil(coded.before)
    }

    func testTheBudgetKeepsWhatIsNearestTheSelection() {
        let word = "word "
        let long = String(repeating: word, count: 2_000)
        let both = frame(long + "end [x] start " + long)
        XCTAssertLessThanOrEqual(both.sentBefore.count, WriteRewriteFrame.maxBefore)
        XCTAssertLessThanOrEqual(both.sentAfter.count, WriteRewriteFrame.maxAfter)
        XCTAssertTrue(both.lead.hasPrefix("[\u{2026}] word"), "cut after a blank, the cut marked")
        XCTAssertTrue(both.lead.hasSuffix("word "))
        XCTAssertTrue(both.trail.hasSuffix("word […]"))
        XCTAssertEqual(both.before, "word word end")
        XCTAssertEqual(both.after, "start word word")

        // Room one side leaves goes to the other, up to 8,000 together.
        let shortAfter = frame(long + "end [x] the end.")
        XCTAssertGreaterThan(shortAfter.sentBefore.count, WriteRewriteFrame.maxBefore)
        XCTAssertLessThanOrEqual(shortAfter.sentBefore.count + shortAfter.sentAfter.count, WriteRewriteFrame.maxTotal)
        let shortBefore = frame("Hi, [x] start " + long)
        XCTAssertGreaterThan(shortBefore.sentAfter.count, WriteRewriteFrame.maxAfter)
        XCTAssertLessThanOrEqual(shortBefore.sentBefore.count + shortBefore.sentAfter.count, WriteRewriteFrame.maxTotal)
        XCTAssertEqual(frame("this is a short [one] here").lead, "this ", "nothing is cut that fits")
    }

    // MARK: A body a mail link filled in

    func testALinkAndAnAddressBesideTheSelectionAreRedacted() {
        let made = frame("Mail dana@example.test or see https://example.test/reset?t=SECRET1 then [call me] tomorrow at noon "
                         + "about https://example.test/x?k=SECRET2 please", redacts: true)
        let sent = made.sentBefore + made.selection + made.sentAfter
        XCTAssertFalse(sent.contains("dana@"))
        XCTAssertFalse(sent.contains("SECRET1"))
        XCTAssertFalse(sent.contains("SECRET2"))
        XCTAssertTrue(sent.contains("an address at example.test"))
        XCTAssertTrue(sent.contains("[link: example.test]"))
    }

    func testASelectionStartingInsideALinkSendsNoFragmentOfIt() {
        let made = frame("Reset at https://example.test/reset?token=QUERYTOKEN&step=[2 and tell me] when done", redacts: true)
        let turn = made.markedBody(fence: fence)
        XCTAssertFalse(turn.contains("QUERYTOKEN"), "the run the selection cuts goes out of the request whole")
        XCTAssertFalse(turn.contains("example.test/reset"))
        XCTAssertFalse(turn.contains("step="))
        XCTAssertNil(made.before, "that side has no window")
        XCTAssertEqual(made.lead, "Reset at ")
        let ending = frame("Open [the page at https://example.test/a?]token=QUERYTOKEN now", redacts: true)
        XCTAssertFalse(ending.markedBody(fence: fence).contains("QUERYTOKEN"))
        XCTAssertNil(ending.after)
    }

    /// `AIRedactor` reads around a code (its label within a few words) and a card number spaced out in groups. Pieces
    /// cut at blanks may part a code from its label, or a card number's groups from each other: then the redacted
    /// pieces would send what the whole, redacted, does not, and the selection goes alone.
    func testPiecesThatWouldHideACodeOrACardFromTheRedactorSendTheSelectionAlone() {
        let label = around("[Your verification code is] 481516. Please enter it within 10 minutes.")
        XCTAssertEqual(WriteRewriteFrame.make(around: label.around, selection: label.selection, redacts: true, fence: fence).after,
                       "481516. Please enter", "the code would go unredacted in the window, its label in the selection")
        XCTAssertFalse(WriteRewriteFrame.redactsInPiecesAsAWhole(label.around, selection: label.selection))
        let window = around("Your verification code is 481516. Please enter [it] within 10 minutes.")
        XCTAssertFalse(WriteRewriteFrame.redactsInPiecesAsAWhole(window.around, selection: window.selection),
                       "the label in the text before, the code in the window beside the selection")
        for marked in ["Card 4111 1111 [1111 1111] for the booking.", "Card 4111 1111 [1111 1111 for the booking.]",
                       "Card [4111 1111] 1111 1111 for the booking."] {
            let card = around(marked)
            XCTAssertFalse(WriteRewriteFrame.redactsInPiecesAsAWhole(card.around, selection: card.selection),
                           "each piece too short for the card check: \(marked)")
        }
        let labelled = around("Your verification code:[481516] expires soon")
        XCTAssertFalse(WriteRewriteFrame.redactsInPiecesAsAWhole(labelled.around, selection: labelled.selection),
                       "the selection is the code: the words sent before it, its run's start left out, still label it")
        let cutLabel = around("Use 481516 to verif[y it] please")
        XCTAssertFalse(WriteRewriteFrame.redactsInPiecesAsAWhole(cutLabel.around, selection: cutLabel.selection),
                       "the label's start, which the selection cuts and the frame never sends, is read with the selection")
    }

    func testPiecesThatRedactAsTheWholeKeepTheDraftAround() {
        for marked in ["Hello Dana, could [you] check the plan",
                       "Mail dana@example.test or see https://example.test/reset?t=SECRET1 then [call me] tomorrow",
                       "Reset at https://example.test/reset?token=QUERYTOKEN&step=[2 and tell me] when done",
                       "Your code is [ready] and the venue is booked for 40 people.",
                       "[Thanks]. Your verification code is 481516."] {
            let body = around(marked)
            XCTAssertTrue(WriteRewriteFrame.redactsInPiecesAsAWhole(body.around, selection: body.selection), marked)
        }
    }

    func testARedactedBodysWindowIsOfferedOnlyAtBlanksAndAsItIs() {
        let made = frame("Hello Dana, could [you] check the plan", redacts: true)
        XCTAssertEqual(made.before, "Hello Dana, could")
        XCTAssertEqual(made.after, "check the plan")
        let joined = frame("Hello Dana, could[you] check", redacts: true)
        XCTAssertNil(joined.before, "no blank between the window and the selection")
        XCTAssertFalse(joined.lead.contains("could"), "and the word the selection touches goes out")
        let notRedacted = frame("Hello Dana, could[you] check")
        XCTAssertEqual(notRedacted.before, "Hello Dana, could", "the user's own text keeps its window")
    }
}
