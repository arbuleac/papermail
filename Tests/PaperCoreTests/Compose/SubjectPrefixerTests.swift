import XCTest
@testable import PaperCore

final class SubjectPrefixerTests: XCTestCase {
    func testReplyAddsPrefixOnce() {
        XCTAssertEqual(SubjectPrefixer.reply("Hello"), "Re: Hello")
        XCTAssertEqual(SubjectPrefixer.reply("Re: Hello"), "Re: Hello")
        XCTAssertEqual(SubjectPrefixer.reply("RE: Hello"), "Re: Hello")
        XCTAssertEqual(SubjectPrefixer.reply("re:Hello"), "Re: Hello")
        XCTAssertEqual(SubjectPrefixer.reply("Re: Re: RE: Hello"), "Re: Hello")
    }

    func testLocalizedReplyPrefixesAreNormalized() {
        XCTAssertEqual(SubjectPrefixer.reply("AW: Hello"), "Re: Hello")
        XCTAssertEqual(SubjectPrefixer.reply("Antw: Hello"), "Re: Hello")
        XCTAssertEqual(SubjectPrefixer.reply("SV: Hello"), "Re: Hello")
        XCTAssertEqual(SubjectPrefixer.reply("Re : Hello"), "Re: Hello")
        XCTAssertEqual(SubjectPrefixer.reply("Re[2]: Hello"), "Re: Hello")
        XCTAssertEqual(SubjectPrefixer.reply("RE(3): Hello"), "Re: Hello")
    }

    func testForwardAddsPrefixOnce() {
        XCTAssertEqual(SubjectPrefixer.forward("Hello"), "Fwd: Hello")
        XCTAssertEqual(SubjectPrefixer.forward("Fwd: Hello"), "Fwd: Hello")
        XCTAssertEqual(SubjectPrefixer.forward("FW: Hello"), "Fwd: Hello")
        XCTAssertEqual(SubjectPrefixer.forward("Fw: Hello"), "Fwd: Hello")
        XCTAssertEqual(SubjectPrefixer.forward("WG: Hello"), "Fwd: Hello")
        XCTAssertEqual(SubjectPrefixer.forward("TR: Hello"), "Fwd: Hello")
    }

    func testReplyToForwardKeepsForwardMarker() {
        XCTAssertEqual(SubjectPrefixer.reply("Fwd: Hello"), "Re: Fwd: Hello")
        XCTAssertEqual(SubjectPrefixer.forward("Re: Hello"), "Fwd: Re: Hello")
    }

    func testIdempotence() {
        let subjects = ["Hello", "Re: Hello", "AW: WG: Hello", "", "   ", "Reminder: Hello", "Fw: Re: Fw: Hello", "Re[12]:x"]
        for subject in subjects {
            let reply = SubjectPrefixer.reply(subject)
            XCTAssertEqual(SubjectPrefixer.reply(reply), reply, subject)
            let forward = SubjectPrefixer.forward(subject)
            XCTAssertEqual(SubjectPrefixer.forward(forward), forward, subject)
        }
    }

    func testWordsThatMerelyStartWithAPrefixAreNotPrefixes() {
        XCTAssertEqual(SubjectPrefixer.reply("Reminder: Hello"), "Re: Reminder: Hello")
        XCTAssertEqual(SubjectPrefixer.reply("Research"), "Re: Research")
        XCTAssertEqual(SubjectPrefixer.forward("Fwd Hello"), "Fwd: Fwd Hello")
    }

    func testEmptySubject() {
        XCTAssertEqual(SubjectPrefixer.reply(""), "Re:")
        XCTAssertEqual(SubjectPrefixer.forward("  "), "Fwd:")
    }

    func testStripped() {
        XCTAssertEqual(SubjectPrefixer.stripped("Re: Fwd: AW: Hello "), "Hello")
        XCTAssertTrue(SubjectPrefixer.hasReplyPrefix("re: x"))
        XCTAssertFalse(SubjectPrefixer.hasReplyPrefix("Fwd: x"))
        XCTAssertTrue(SubjectPrefixer.hasForwardPrefix("Fwd: x"))
    }
}
