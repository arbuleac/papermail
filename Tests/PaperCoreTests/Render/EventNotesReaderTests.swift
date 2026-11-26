import XCTest
@testable import PaperCore

/// An event's notes as text with https and tel links only (docs/ARCHITECTURE.md, "Rendering" › Event notes): nothing
/// of the notes ever loads, no other scheme is a link, and nothing written in the text is detected as one.
final class EventNotesReaderTests: XCTestCase {
    private func linked(_ notes: EventNotes?) -> [String] {
        guard let notes else { return [] }
        let text = notes.text as NSString
        return notes.links.map { text.substring(with: NSRange(location: $0.location, length: $0.length)) + " -> " + $0.url }
    }

    func testHTMLBecomesTextWithItsLinks() throws {
        let notes = try XCTUnwrap(EventNotesReader.notes(from: """
            <p>Agenda for <b>Thursday</b>:<br>first the numbers</p>
            <ul><li>Roadmap</li><li>Hiring</li></ul>
            <p>Doc: <a href="https://docs.example.test/agenda?x=1&amp;y=2">the agenda</a></p>
            """))
        XCTAssertEqual(notes.text, "Agenda for Thursday:\nfirst the numbers\n\n• Roadmap\n• Hiring\n\nDoc: the agenda")
        XCTAssertEqual(linked(notes), ["the agenda -> https://docs.example.test/agenda?x=1&y=2"])
        XCTAssertFalse(notes.isCut)
    }

    func testOnlyHttpsAndTelAreLinks() throws {
        let notes = try XCTUnwrap(EventNotesReader.notes(from: """
            <a href="https://ok.example.test/">secure</a> <a href="http://plain.example.test/">plain</a>
            <a href="mailto:x@example.test">mail</a> <a href="javascript:alert(1)">script</a>
            <a href="data:text/html,hi">data</a> <a href="ftp://files.example.test/">ftp</a>
            <a href="file:///etc/passwd">file</a> <a href="https://zoom.us@evil.test/j/1">userinfo</a>
            <a href="tel:+15550134,,601225430%23">dial</a>
            """))
        XCTAssertEqual(linked(notes), ["secure -> https://ok.example.test/", "dial -> tel:+15550134,,601225430%23"])
        for word in ["plain", "mail", "script", "data", "ftp", "file", "userinfo"] {
            XCTAssertTrue(notes.text.contains(word), "\(word) stays text")
        }
    }

    func testImagesStylesScriptsAndFormsNeverReachTheText() throws {
        let notes = try XCTUnwrap(EventNotesReader.notes(from: """
            <style>.x { background: url(https://tracker.example.test/s.png) }</style>
            <script>fetch("https://tracker.example.test/")</script>
            <p>Hello<img src="https://tracker.example.test/pixel.gif" alt="pixel"></p>
            <iframe src="https://evil.example.test/"></iframe><form><input value="secret"></form>
            <svg><text>vector</text></svg><noscript>none</noscript>
            """))
        XCTAssertEqual(notes.text, "Hello")
        XCTAssertTrue(notes.links.isEmpty)
    }

    func testSeparatorsFoldAndBlankLinesCollapse() throws {
        let notes = try XCTUnwrap(EventNotesReader.notes(from: """
            Weekly look at the work.


            ________________________________________________________________________________
            Microsoft Teams meeting
            ==========
            Join   on   your computer
            """))
        XCTAssertEqual(notes.text, "Weekly look at the work.\n\nMicrosoft Teams meeting\n\nJoin on your computer")
    }

    func testBareHttpsAddressesAreLinksAndNothingElseIs() throws {
        let notes = try XCTUnwrap(EventNotesReader.notes(from: """
            Shortlist: https://docs.example.test/lisbon. Old: http://old.example.test
            Call +1 555 0134 or write to sam@example.test, see www.example.test or example.test
            """))
        XCTAssertEqual(linked(notes), ["https://docs.example.test/lisbon -> https://docs.example.test/lisbon"])
    }

    func testTablesKeepTheirCellsApart() throws {
        let notes = try XCTUnwrap(EventNotesReader.notes(from: "<table><tr><td>US</td><td>+1 555 0134</td></tr></table>"))
        XCTAssertEqual(notes.text, "US\t+1 555 0134")
    }

    func testAnAnchorWithNoTextShowsItsAddress() throws {
        let notes = EventNotesReader.notes(from: #"<p>Menu: <a href="https://menu.example.test/"></a></p>"#)
        XCTAssertEqual(linked(notes), ["https://menu.example.test/ -> https://menu.example.test/"])
    }

    func testLongNotesAreCutAtABreakAndTheirLinksPastTheCutDropped() throws {
        let words = String(repeating: "word ", count: 900)
        let source = "<p><a href=\"https://first.example.test/\">first</a> " + words + "<a href=\"https://late.example.test/\">late</a></p>"
        let notes = try XCTUnwrap(EventNotesReader.notes(from: source))
        XCTAssertTrue(notes.isCut)
        XCTAssertLessThanOrEqual(notes.text.utf16.count, EventNotes.maxLength)
        XCTAssertTrue(notes.text.hasSuffix("word…"), String(notes.text.suffix(20)))
        XCTAssertEqual(notes.links.map(\.url), ["https://first.example.test/"])
    }

    func testNothingToShowIsNoNotes() {
        XCTAssertNil(EventNotesReader.notes(from: nil))
        XCTAssertNil(EventNotesReader.notes(from: "   \n "))
        XCTAssertNil(EventNotesReader.notes(from: #"<p><img src="https://x.example.test/a.png"></p>"#))
    }

    func testPlainTextWithALessThanSignIsNotHTML() throws {
        let notes = try XCTUnwrap(EventNotesReader.notes(from: "Budget < 5k & > 2k"))
        XCTAssertEqual(notes.text, "Budget < 5k & > 2k")
    }

    /// Exchange's plain text, as Google keeps an Exchange organizer's DESCRIPTION: an address in angle brackets is no
    /// tag, so the lines stay lines, the join address is a link and the codes can be read off their lines.
    func testPlainTextWithAddressesInAngleBracketsIsNotHTML() throws {
        let source = """
            Click here to join the meeting<https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0>
            Meeting ID: 284 113 905 771
            Passcode: Qx7bTe
            Contact: Jane Doe <jane@example.test>
            """
        XCTAssertFalse(EventNotesReader.isHTML(source))
        let notes = try XCTUnwrap(EventNotesReader.notes(from: source))
        XCTAssertEqual(notes.text, source)
        XCTAssertEqual(linked(notes), ["https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0 -> "
                                       + "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0"])
        XCTAssertEqual(EventNotesReader.joinAddress(in: notes), "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0")
        let codes = EventNotesReader.callCodes(in: notes.text)
        XCTAssertEqual(codes.meetingID, "284 113 905 771")
        XCTAssertEqual(codes.passcode, "Qx7bTe")
    }

    func testOnlyRealTagsMakeHTML() {
        for html in ["a<br>b", "<p>x</p>", "x</div>", "<!-- c -->x", #"<a href="https://x.test">y</a>"#, "<B>bold", "<h2 id=t>x",
                     "<span\nclass=x>y"] {
            XCTAssertTrue(EventNotesReader.isHTML(html), html)
        }
        for plain in ["a < b", "x<y", "<https://x.test/a>", "Jane <jane@x.test>", "<brian@x.test>", "<pizza>", "if x<y and y>z",
                      "<", "<1>"] {
            XCTAssertFalse(EventNotesReader.isHTML(plain), plain)
        }
    }

    func testASourcePastWhatIsParsedIsCutToo() throws {
        let source = "Agenda\n" + String(repeating: "x", count: EventNotesReader.maxParsed)
        let notes = try XCTUnwrap(EventNotesReader.notes(from: "Agenda\n" + String(repeating: "word ", count: 600)
                                                         + String(repeating: " ", count: EventNotesReader.maxParsed)
                                                         + "Meeting ID: 1"))
        XCTAssertTrue(notes.isCut, "the rest was dropped: the card says where it is")
        XCTAssertTrue(notes.text.hasSuffix("…"))
        XCTAssertTrue(try XCTUnwrap(EventNotesReader.notes(from: source)).isCut)
    }

    func testTheEnglishCallCodesAreLifted() {
        let teams = """
            Microsoft Teams meeting
            Meeting ID: 284 113 905 771
            Passcode: Qx7bTe
            Phone Conference ID: 601 225 430#
            """
        let codes = EventNotesReader.callCodes(in: teams)
        XCTAssertEqual(codes.meetingID, "284 113 905 771")
        XCTAssertEqual(codes.passcode, "Qx7bTe")
        let zoom = EventNotesReader.callCodes(in: "Meeting number: 812-3456-7890\nAccess code: 551 902")
        XCTAssertEqual(zoom.meetingID, "812-3456-7890")
        XCTAssertEqual(zoom.passcode, "551 902")
        let german = EventNotesReader.callCodes(in: "Besprechungs-ID: 284 113 905 771\nKennung: Qx7bTe")
        XCTAssertNil(german.meetingID, "English labels only")
        XCTAssertNil(german.passcode)
        XCTAssertNil(EventNotesReader.callCodes(in: "Password: https://evil.example.test/x").passcode, "not a code")
    }

    func testAJoinAddressInTheNotesIsTakenOnlyOnAKnownHost() throws {
        let zoom = EventNotesReader.notes(from: "Docs https://docs.example.test/a then https://acme.zoom.us/j/81234567890")
        XCTAssertEqual(EventNotesReader.joinAddress(in: zoom), "https://acme.zoom.us/j/81234567890")
        let other = EventNotesReader.notes(from: "Join at https://securezoom.us/j/1 or https://call.example.test/x")
        XCTAssertNil(EventNotesReader.joinAddress(in: other))
    }

    func testAHashInAPhoneLinkIsWrittenEncoded() {
        XCTAssertEqual(EventLinkPolicy.phoneURL("+15550134,,601225430#")?.absoluteString, "tel:+15550134,,601225430%23")
        XCTAssertNil(EventLinkPolicy.phoneURL("+1555;javascript"))
        XCTAssertNotNil(EventLinkPolicy.checked(URL(string: "tel:+1-555-0134")!))
        XCTAssertNil(EventLinkPolicy.checked(URL(string: "tel:+1555@evil")!))
    }
}
