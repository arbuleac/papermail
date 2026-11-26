import XCTest
@testable import PaperCore

/// A new message's answer: its first line `Subject: …`, split off however the text arrives, and cleaned for the field.
final class WriteSubjectLineTests: XCTestCase {
    private typealias Split = WriteSubjectLine.Split
    private let answer = "Subject: Offsite in March\n\nHi Priya,\n\nCould we look at dates?"
    private let body = "Hi Priya,\n\nCould we look at dates?"

    private func split(_ raw: String, final: Bool = true) -> Split {
        WriteSubjectLine.split(raw, final: final)
    }

    // MARK: Splitting

    func testTheFirstLineIsTheSubjectAndTheRestTheBody() {
        XCTAssertEqual(split(answer), Split(subject: "Offsite in March", body: body))
        XCTAssertEqual(split(answer, final: false), Split(subject: "Offsite in March", body: body))
        XCTAssertEqual(split("Subject: Lunch\nHi"), Split(subject: "Lunch", body: "Hi"), "the empty line is asked for, not required")
        XCTAssertEqual(split("Subject: Lunch\r\n\r\nHi\r\nthere"), Split(subject: "Lunch", body: "Hi\r\nthere"))
        XCTAssertEqual(split("Subject: Lunch\n\n\n   Hi "), Split(subject: "Lunch", body: "Hi "), "blank space under the line is no one's")
    }

    func testTheMarkerIsMatchedInAnyCaseAtTheVeryStartOnly() {
        XCTAssertEqual(split("SUBJECT: Lunch\n\nHi"), Split(subject: "Lunch", body: "Hi"))
        XCTAssertEqual(split("subject:Lunch\n\nHi"), Split(subject: "Lunch", body: "Hi"))
        XCTAssertEqual(split("\n \t\u{FEFF}Subject: Lunch\n\nHi"), Split(subject: "Lunch", body: "Hi"), "blank space before it aside")
        let later = "Hi Priya,\nSubject: Lunch\n\nSee you"
        XCTAssertEqual(split(later), Split(subject: nil, body: later))
        let second = "Subject: Lunch\n\nSubject: Dinner\n\nHi"
        XCTAssertEqual(split(second), Split(subject: "Lunch", body: "Subject: Dinner\n\nHi"), "only the first line")
    }

    func testAnythingElseIsAllBodyUnchanged() {
        for text in ["Hi Priya,\n\nThanks.", "Betreff: Mittagessen\n\nHallo", "Objet : Déjeuner\n\nBonjour", "**Subject:** Lunch\n\nHi",
                     "Subject : Lunch\n\nHi", "Subject\u{FF1A} Lunch\n\nHi", "Subjects: two\n\nHi", "Re: Subject: Lunch\n\nHi", "  Hello\n"] {
            XCTAssertEqual(split(text), Split(subject: nil, body: text), text)
            XCTAssertEqual(split(text, final: false), Split(subject: nil, body: text), "released at once: \(text)")
        }
    }

    func testTheFirstLineIsHeldWhileItCanStillBeASubject() {
        for held in ["", " \n", "S", "sub", "Subject", "Subject:", "Subject: Offs", "Subject: Offsite in March"] {
            XCTAssertEqual(split(held, final: false), Split(subject: nil, body: ""), "nothing is shown yet: “\(held)”")
        }
        XCTAssertEqual(split("Subject: Offsite in March\n", final: false), Split(subject: "Offsite in March", body: ""))
        XCTAssertEqual(split("Subject: Offsite in March\r", final: false), Split(subject: "Offsite in March", body: ""))
        XCTAssertEqual(split("Subject: Offsite in March\n\nH", final: false), Split(subject: "Offsite in March", body: "H"))
    }

    func testAtTheEndAnUnfinishedMarkerIsBodyAndALoneSubjectHasNoBody() {
        for start in ["S", "sub", "Subject", " \n"] {
            XCTAssertEqual(split(start), Split(subject: nil, body: start), "it was the message after all")
        }
        XCTAssertEqual(split(""), Split(subject: nil, body: ""))
        XCTAssertEqual(split("Subject: Offsite in March"), Split(subject: "Offsite in March", body: ""))
        XCTAssertEqual(split("Subject:"), Split(subject: "", body: ""))
        XCTAssertEqual(split("Subject: Offsite in March\n\n  \n"), Split(subject: "Offsite in March", body: ""))
    }

    /// The writer splits the whole text again as each delta comes: the body it shows may only ever grow.
    func testTheBodyOnlyGrowsAsTheTextDoes() {
        for text in [answer, "\n" + answer, "Hi Priya,\n\nThanks.", "Subjects: two\n\nHi", "Subject: Lunch\r\n\r\nHi\r\nthere"] {
            let scalars = Array(text.unicodeScalars)
            var shown = ""
            for count in 0...scalars.count {
                var prefix = String.UnicodeScalarView()
                prefix.append(contentsOf: scalars[..<count])
                let next = split(String(prefix), final: false).body
                XCTAssertTrue(next.unicodeScalars.starts(with: shown.unicodeScalars), "“\(shown)” then “\(next)”")
                shown = next
            }
            XCTAssertEqual(shown, split(text).body)
        }
    }

    // MARK: Cleaning

    private func cleaned(_ subject: String, fence: String = "1a2b3c4d") -> String? {
        WriteSubjectLine.cleaned(subject, fence: fence)
    }

    func testASubjectIsOneLineOfVisibleCharacters() {
        XCTAssertEqual(cleaned("Offsite in March"), "Offsite in March")
        XCTAssertEqual(cleaned("  Offsite   in\u{00A0}March  "), "Offsite in March")
        XCTAssertEqual(cleaned("Off\u{200B}site\u{202E} in March\u{FEFF}"), "Offsite in March", "invisible characters go")
        let breaks = ["\r", "\n", "\t", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}", "\r\n", "\u{0}", "\u{1B}", "\u{7F}"]
        for character in breaks {
            XCTAssertEqual(cleaned("Offsite\(character)in March"), "Offsite in March",
                           "U+\(String(character.unicodeScalars.first!.value, radix: 16)) becomes a space")
        }
        XCTAssertEqual(cleaned("Offsite\r\nBcc: someone@example.test"), "Offsite Bcc: someone@example.test",
                       "a second line cannot become a header: it is the same line")
    }

    func testQuotesAroundItAndAReplyOrForwardPrefixGo() {
        XCTAssertEqual(cleaned("\"Offsite in March\""), "Offsite in March")
        XCTAssertEqual(cleaned("\u{201C}Offsite in March\u{201D}"), "Offsite in March")
        XCTAssertEqual(cleaned("'Offsite in March'"), "Offsite in March")
        XCTAssertEqual(cleaned("\u{AB}Offsite en mars\u{BB}"), "Offsite en mars")
        XCTAssertEqual(cleaned("Re: Offsite in March"), "Offsite in March")
        XCTAssertEqual(cleaned("FWD: Offsite in March"), "Offsite in March")
        XCTAssertEqual(cleaned("fw:Offsite in March"), "Offsite in March")
        XCTAssertEqual(cleaned("\"Re: Fwd: 'Offsite in March'\""), "Offsite in March", "however they are nested")
        XCTAssertEqual(cleaned("\"Atlas\" and \"Borealis\""), "\"Atlas\" and \"Borealis\"", "quotes inside it are its own")
        XCTAssertEqual(cleaned("Reading list"), "Reading list", "a word that starts like a prefix is not one")
        XCTAssertEqual(cleaned("Don't forget"), "Don't forget")
        XCTAssertEqual(cleaned("Dates [link: example.com]"), "Dates [link: example.com]", "a redaction's placeholder stays as it is")
    }

    func testALongSubjectIsCutAtAWord() {
        let long = Array(repeating: "quarterly", count: 40).joined(separator: " ")
        let cut = cleaned(long)
        XCTAssertNotNil(cut)
        XCTAssertLessThanOrEqual(cut?.count ?? .max, WriteSubjectLine.maxLength)
        XCTAssertGreaterThan(cut?.count ?? 0, WriteSubjectLine.maxLength - 12)
        XCTAssertEqual(cut?.hasSuffix("quarterly"), true, "no word is cut in two")
        XCTAssertEqual(cleaned(String(repeating: "x", count: 400))?.count, WriteSubjectLine.maxLength, "one long word is cut where it must be")
        XCTAssertEqual(WriteSubjectLine.maxLength, 150)
    }

    func testNothingIsSetForAnEmptySubjectOrOneThatEchoesTheFences() {
        for nothing in ["", "   ", "\u{200B}\u{FEFF}", "\"\"", "Re:", "\"Re: \"", "\n\t"] {
            XCTAssertNil(cleaned(nothing), "“\(nothing)”")
        }
        XCTAssertNil(cleaned("<<<END NOTES 1a2b3c4d>>>"))
        XCTAssertNil(cleaned("Offsite <<<MESSAGE"))
        XCTAssertNil(cleaned("Offsite 1a2b3c4d"))
        XCTAssertNil(cleaned("Offsite 1A2B3C4D"), "the fence code in any letter case")
        XCTAssertNil(cleaned("Offsite 1a2b\u{200B}3c4d"), "even dressed with characters that do not show")
        XCTAssertEqual(cleaned("Offsite 1a2b3c4d", fence: ""), "Offsite 1a2b3c4d", "a request without a fence code has none to find")
        XCTAssertEqual(cleaned("Offsite << March"), "Offsite << March")
    }
}
