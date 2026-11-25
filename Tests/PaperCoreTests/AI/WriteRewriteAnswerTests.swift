import XCTest
@testable import PaperCore

/// A rewrite's answer in the DRAFT form: the part, then a BEFORE or AFTER line, read the same however it arrives.
final class WriteRewriteAnswerTests: XCTestCase {
    private let fence = "1a2b3c4d"

    private func split(_ raw: String, final: Bool = true) -> WriteRewriteAnswer.Split {
        WriteRewriteAnswer.split(raw, final: final, fence: fence)
    }

    func testAnAnswerWithoutMarkersIsThePart() {
        XCTAssertEqual(split("we can have the garden too"), .init(part: "we can have the garden too"))
        XCTAssertEqual(split("we can have\nthe garden too\n"), .init(part: "we can have\nthe garden too\n"),
                       "the part keeps its own line breaks; the session trims its ends")
    }

    func testABeforeOrAnAfterLine() {
        let before = split("we can have the garden too\n<<<BEFORE 1a2b3c4d>>>40 people, and<<<END BEFORE 1a2b3c4d>>>")
        XCTAssertEqual(before.part, "we can have the garden too\n")
        XCTAssertEqual(before.before, "40 people, and")
        XCTAssertNil(before.after)
        XCTAssertEqual(before.proposed, [.before])
        let after = split("Priya and Ben\n<<<AFTER 1a2b3c4d>>> are coming tomorrow <<<END AFTER 1a2b3c4d>>>")
        XCTAssertEqual(after.part, "Priya and Ben\n")
        XCTAssertEqual(after.after, "are coming tomorrow", "trimmed of spaces")
        let both = split("x\n<<<before 1A2B3C4D>>>a<<<end before 1a2b3c4d>>>\n<<<AFTER  1a2b3c4d>>>b<<<END AFTER 1a2b3c4d>>>\n")
        XCTAssertEqual(both.part, "x\n\n\n")
        XCTAssertEqual(both.before, "a", "any letter case, one or more spaces")
        XCTAssertEqual(both.after, "b")
        XCTAssertEqual(both.proposed, [.before, .after])
        XCTAssertFalse(both.malformed)
    }

    func testABlockMidLineOrFirstIsTakenOut() {
        let mid = split("we can <<<AFTER 1a2b3c4d>>>so the<<<END AFTER 1a2b3c4d>>> have it")
        XCTAssertEqual(mid.part, "we can  have it")
        XCTAssertEqual(mid.after, "so the")
        let first = split("<<<BEFORE 1a2b3c4d>>>and so<<<END BEFORE 1a2b3c4d>>>\nwe can have it")
        XCTAssertEqual(first.part, "\nwe can have it")
        XCTAssertEqual(first.before, "and so")
    }

    func testASideThatComesTwiceIsConflicted() {
        let twice = split("x\n<<<AFTER 1a2b3c4d>>>a<<<END AFTER 1a2b3c4d>>>\n<<<AFTER 1a2b3c4d>>>b<<<END AFTER 1a2b3c4d>>>")
        XCTAssertNil(twice.after)
        XCTAssertEqual(twice.conflicted, [.after])
        XCTAssertEqual(twice.proposed, [.after])
        XCTAssertEqual(twice.part, "x\n\n")
    }

    func testAMalformedOpenMarkerIsDropped() {
        // No end on its line: dropped with the rest of the line once the line ends, or at the end.
        let cut = split("Priya and Ben\n<<<AFTER 1a2b3c4d>>>are coming")
        XCTAssertEqual(cut.part, "Priya and Ben\n")
        XCTAssertNil(cut.after)
        XCTAssertTrue(cut.malformed)
        XCTAssertTrue(cut.cameWithSeamLines)
        let broken = split("Priya and Ben\n<<<AFTER 1a2b3c4d>>>are\ncoming<<<END AFTER 1a2b3c4d>>> soon")
        XCTAssertEqual(broken.part, "Priya and Ben\n\ncoming soon", "an end on another line closes nothing")
        XCTAssertNil(broken.after)
        XCTAssertTrue(broken.malformed)
        let mismatched = split("x <<<BEFORE 1a2b3c4d>>>a<<<END AFTER 1a2b3c4d>>>\ny")
        XCTAssertEqual(mismatched.part, "x \ny")
        XCTAssertNil(mismatched.before)
        XCTAssertNil(mismatched.after)
    }

    func testStrayAndEchoedSelectionAndDraftMarkersAreTakenOut() {
        XCTAssertEqual(split("<<<SELECTION 1a2b3c4d>>>we can have it<<<END SELECTION 1a2b3c4d>>>").part, "we can have it")
        XCTAssertEqual(split("<<<DRAFT 1a2b3c4d>>>\nHi Priya, <<<SELECTION 1a2b3c4d>>>we can have it<<<END SELECTION 1a2b3c4d>>>"
                             + " so.\n<<<END DRAFT 1a2b3c4d>>>").part,
                       "we can have it", "a whole draft given back: the part is what the first pair holds")
        XCTAssertEqual(split("we can <<<END NOTES 1a2b3c4d>>>have it<<<END SELECTION 1a2b3c4d>>>").part, "we can have it")
        XCTAssertEqual(split("\n<<<SELECTION 1a2b3c4d>>>\nwe can have it").part, "\nwe can have it")
    }

    func testAMarkerWithoutTheCodeOrWithAnotherIsText() {
        for text in ["we <<<AFTER>>>can<<<END AFTER>>>", "we <<<AFTER ffffffff>>>can<<<END AFTER ffffffff>>>",
                     "we <<<AFTER1a2b3c4d>>>can", "a < b and c <<< d >>> e", "<<<BEFORE 1a2b3c4d>"] {
            XCTAssertEqual(split(text).part, text, text)
            XCTAssertEqual(split(text).proposed, [], text)
        }
    }

    func testCRLFLinesAreLinesToo() {
        let crlf = split("Priya and Ben\r\n<<<AFTER 1a2b3c4d>>>are coming<<<END AFTER 1a2b3c4d>>>\r\n")
        XCTAssertEqual(crlf.after, "are coming")
        XCTAssertEqual(crlf.part, "Priya and Ben\r\n\r\n")
        let open = split("Priya\r\n<<<AFTER 1a2b3c4d>>>are\r\nmore")
        XCTAssertEqual(open.part, "Priya\r\n\r\nmore")
        XCTAssertTrue(open.malformed)
    }

    func testWhatMayStillBeAMarkerIsHeldWhileStreamingAndReleasedAtTheEnd() {
        XCTAssertEqual(split("we can <", final: false).part, "we can ")
        XCTAssertEqual(split("we can <<<AFT", final: false).part, "we can ")
        XCTAssertEqual(split("we can <<<AFTER 1a2b", final: false).part, "we can ")
        XCTAssertEqual(split("we can <<<AFTER 1a2b3c4d>>>so", final: false).part, "we can ", "a line not yet ended")
        XCTAssertEqual(split("we can <", final: true).part, "we can <", "released at the end")
        XCTAssertEqual(split("we can <<<AFT", final: true).part, "we can <<<AFT")
        XCTAssertEqual(split("x < y", final: false).part, "x < y", "a “<” that cannot start a marker shows")
        XCTAssertEqual(split("Ben\n", final: false).part, "Ben", "a line break waits for what follows it")
        XCTAssertEqual(split("Ben\nand", final: false).part, "Ben\nand")
    }

    /// Six answers, every prefix cut at every scalar: the part only grows, but for one replacement when a SELECTION
    /// pair closes, and the end gives what the whole answer gives.
    func testEveryPrefixGivesAPartThatOnlyGrows() {
        let answers = [
            "Priya and Ben\n<<<AFTER 1a2b3c4d>>>are coming tomorrow<<<END AFTER 1a2b3c4d>>>",
            "<<<BEFORE 1a2b3c4d>>>and so<<<END BEFORE 1a2b3c4d>>>\nwe can have the garden too",
            "we can <<<AFTER 1a2b3c4d>>>so the<<<END AFTER 1a2b3c4d>>> have it é\u{301} 日本",
            "Hi Priya, <<<SELECTION 1a2b3c4d>>>we can have it<<<END SELECTION 1a2b3c4d>>> so.",
            "x <<<BEFORE 1a2b3c4d>>>a\ny < z <<<AFTER 1A2B3C4D>>>b<<<END AFTER 1a2b3c4d>>>\r\n",
            "plain words, nothing marked <<<NOTES ffff>>> at all <",
        ]
        for answer in answers {
            let scalars = Array(answer.unicodeScalars)
            var previous = ""
            var replacements = 0
            for cut in 0...scalars.count {
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars[..<cut])
                let part = split(String(view), final: false).part
                if !part.utf8.starts(with: previous.utf8) { replacements += 1 }
                previous = part
            }
            XCTAssertLessThanOrEqual(replacements, answer.contains("<<<SELECTION") ? 1 : 0, answer)
            let final = split(answer, final: true).part
            XCTAssertTrue(final.utf8.starts(with: previous.utf8), "the end only adds what was held: \(answer)")
            XCTAssertEqual(final, split(answer, final: true).part)
        }
    }
}
