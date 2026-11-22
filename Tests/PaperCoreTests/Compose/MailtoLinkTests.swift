import XCTest
@testable import PaperCore

/// `mailto:` links (RFC 6068) read into a new composer's fields: the RFC's own examples (section 6), then the
/// edge cases links met in the wild produce. Only to, cc, bcc, subject and body are read; nothing is ever sent.
final class MailtoLinkTests: XCTestCase {
    private func link(_ string: String, file: StaticString = #filePath, line: UInt = #line) -> MailtoLink {
        guard let link = MailtoLink(string: string) else {
            XCTFail("\(string) did not parse", file: file, line: line)
            return MailtoLink()
        }
        return link
    }

    private func addresses(_ list: [EmailAddress]) -> [String] {
        list.map(\.address)
    }

    // MARK: RFC 6068 section 6.1, basic examples

    func testASingleAddress() {
        XCTAssertEqual(link("mailto:chris@example.com"), MailtoLink(to: [EmailAddress(address: "chris@example.com")]))
    }

    func testASubject() {
        let parsed = link("mailto:infobot@example.com?subject=current-issue")
        XCTAssertEqual(addresses(parsed.to), ["infobot@example.com"])
        XCTAssertEqual(parsed.subject, "current-issue")
        XCTAssertEqual(parsed.body, "")
    }

    func testABody() {
        XCTAssertEqual(link("mailto:infobot@example.com?body=send%20current-issue").body, "send current-issue")
    }

    func testABodyLineBreakBecomesANewline() {
        XCTAssertEqual(link("mailto:infobot@example.com?body=send%20current-issue%0D%0Asend%20index").body,
                       "send current-issue\nsend index")
    }

    func testInReplyToIsIgnored() {
        XCTAssertEqual(link("mailto:list@example.org?In-Reply-To=%3C3469A91.D10AF4C@example.com%3E"),
                       MailtoLink(to: [EmailAddress(address: "list@example.org")]))
    }

    func testSubscribeBody() {
        let parsed = link("mailto:majordomo@example.com?body=subscribe%20bamboo-l")
        XCTAssertEqual(addresses(parsed.to), ["majordomo@example.com"])
        XCTAssertEqual(parsed.body, "subscribe bamboo-l")
    }

    func testCcAndBody() {
        let parsed = link("mailto:joe@example.com?cc=bob@example.com&body=hello")
        XCTAssertEqual(addresses(parsed.to), ["joe@example.com"])
        XCTAssertEqual(addresses(parsed.cc), ["bob@example.com"])
        XCTAssertEqual(parsed.body, "hello")
    }

    func testAnEscapedPercentInTheAddress() {
        XCTAssertEqual(addresses(link("mailto:gorby%25kremvax@example.com").to), ["gorby%kremvax@example.com"])
    }

    func testAnEscapedQuestionMarkInTheAddressAndAnUnknownHeader() {
        XCTAssertEqual(link("mailto:unlikely%3Faddress@example.com?blat=foop"),
                       MailtoLink(to: [EmailAddress(address: "unlikely?address@example.com")]))
    }

    func testAnEscapedAmpersandInTheAddress() {
        XCTAssertEqual(addresses(link("mailto:Mike%26family@example.org").to), ["Mike&family@example.org"])
    }

    // MARK: RFC 6068 section 6.2, complicated email addresses

    func testQuotedLocalPartsAreKeptWhole() {
        XCTAssertEqual(addresses(link("mailto:%22not%40me%22@example.org").to), ["\"not@me\"@example.org"])
        XCTAssertEqual(addresses(link("mailto:%22oh%5C%5Cno%22@example.org").to), ["\"oh\\\\no\"@example.org"])
        XCTAssertEqual(addresses(link("mailto:%22%5C%5C%5C%22it's%5C%20ugly%5C%5C%5C%22%22@example.org").to),
                       ["\"\\\\\\\"it's\\ ugly\\\\\\\"\"@example.org"])
    }

    // Authoring mistakes the recipient fields already clean up open the same clean, sendable token.
    func testADoubledMailtoPrefixIsDropped() {
        let parsed = link("mailto:mailto:info@shop.example?cc=MAILTO:x@y.example&bcc=mailto:%22not%40me%22@example.org")
        XCTAssertEqual(addresses(parsed.to), ["info@shop.example"])
        XCTAssertEqual(addresses(parsed.cc), ["x@y.example"])
        XCTAssertEqual(addresses(parsed.bcc), ["\"not@me\"@example.org"], "a quoted local part survives the prefix")
        XCTAssertTrue((parsed.to + parsed.cc).allSatisfy { AddressListParser.isValid($0.address) })
    }

    func testAWholeAddressInQuotesLosesItsQuotes() {
        let parsed = link("mailto:%22a@b.example%22?to=%27c@d.example%27")
        XCTAssertEqual(addresses(parsed.to), ["a@b.example", "c@d.example"])
        XCTAssertTrue(parsed.to.allSatisfy { AddressListParser.isValid($0.address) })
    }

    // MARK: RFC 6068 section 6.3, non-ASCII

    func testUTF8Subjects() {
        XCTAssertEqual(link("mailto:user@example.org?subject=caf%C3%A9").subject, "café")
        XCTAssertEqual(link("mailto:user@example.org?subject=%28%E2%80%A6%29").subject, "(…)")
    }

    func testAnEncodedWordSubjectIsKeptAsWritten() {
        XCTAssertEqual(link("mailto:user@example.org?subject=%3D%3Futf-8%3FQ%3Fcaf%3DC3%3DA9%3F%3D").subject, "=?utf-8?Q?caf=C3=A9?=")
    }

    func testAnInternationalDomain() {
        let parsed = link("mailto:user@%E7%B4%8D%E8%B1%86.example.org?subject=Test&body=NATTO")
        XCTAssertEqual(addresses(parsed.to), ["user@納豆.example.org"])
        XCTAssertEqual(parsed.subject, "Test")
        XCTAssertEqual(parsed.body, "NATTO")
    }

    // MARK: Several addresses

    func testCommaSeparatedAddressesInThePath() {
        XCTAssertEqual(addresses(link("mailto:addr1@an.example,addr2@an.example").to), ["addr1@an.example", "addr2@an.example"])
    }

    func testAddressesInAToHeaderOnly() {
        XCTAssertEqual(addresses(link("mailto:?to=addr1@an.example,addr2@an.example").to), ["addr1@an.example", "addr2@an.example"])
    }

    func testThePathAndRepeatedHeadersCombine() {
        let parsed = link("mailto:addr1@an.example?to=addr2@an.example&TO=addr3@an.example&cc=c1@an.example&cc=c2@an.example"
                          + "&bcc=b1@an.example&Bcc=b2@an.example")
        XCTAssertEqual(addresses(parsed.to), ["addr1@an.example", "addr2@an.example", "addr3@an.example"])
        XCTAssertEqual(addresses(parsed.cc), ["c1@an.example", "c2@an.example"])
        XCTAssertEqual(addresses(parsed.bcc), ["b1@an.example", "b2@an.example"])
    }

    func testAnAddressNamedTwiceInOneFieldIsKeptOnce() {
        XCTAssertEqual(addresses(link("mailto:a@an.example?to=A@an.example,b@an.example").to), ["a@an.example", "b@an.example"])
    }

    func testAnEncodedCommaStillSeparatesAddresses() {
        XCTAssertEqual(addresses(link("mailto:?to=a%40an.example%2Cb%40an.example").to), ["a@an.example", "b@an.example"])
    }

    func testADisplayNameInAHeader() {
        XCTAssertEqual(link("mailto:?cc=Ben%20Carter%20%3Cben@contoso.test%3E").cc,
                       [EmailAddress(name: "Ben Carter", address: "ben@contoso.test")])
    }

    // MARK: Headers and their values

    func testHeaderNamesIgnoreCase() {
        let parsed = link("MAILTO:a@an.example?SUBJECT=Hi&Body=There&cC=c@an.example&BCC=b@an.example")
        XCTAssertEqual(parsed.subject, "Hi")
        XCTAssertEqual(parsed.body, "There")
        XCTAssertEqual(addresses(parsed.cc), ["c@an.example"])
        XCTAssertEqual(addresses(parsed.bcc), ["b@an.example"])
    }

    func testAPercentEncodedHeaderName() {
        XCTAssertEqual(link("mailto:a@an.example?%73ubject=Hi").subject, "Hi")
    }

    func testAPlusIsAPlusNotASpace() {
        let parsed = link("mailto:a+tag@an.example?subject=1+1&body=a+b")
        XCTAssertEqual(addresses(parsed.to), ["a+tag@an.example"])
        XCTAssertEqual(parsed.subject, "1+1")
        XCTAssertEqual(parsed.body, "a+b")
    }

    func testABareLineFeedOrCarriageReturnIsANewline() {
        XCTAssertEqual(link("mailto:a@an.example?body=one%0Atwo%0Dthree%0D%0A%0D%0Afour").body, "one\ntwo\nthree\n\nfour")
    }

    func testALineBreakInTheSubjectBecomesASpace() {
        XCTAssertEqual(link("mailto:a@an.example?subject=Line%0D%0Abreak").subject, "Line break")
    }

    func testTheFirstSubjectAndBodyCount() {
        let parsed = link("mailto:a@an.example?subject=First&subject=Second&body=One&body=Two")
        XCTAssertEqual(parsed.subject, "First")
        XCTAssertEqual(parsed.body, "One")
    }

    func testAQuestionMarkOrEqualsSignInsideAValueIsKept() {
        let parsed = link("mailto:a@an.example?subject=Why?&body=x=y")
        XCTAssertEqual(parsed.subject, "Why?")
        XCTAssertEqual(parsed.body, "x=y")
    }

    func testEveryOtherHeaderIsIgnored() {
        let parsed = link("mailto:a@an.example?attach=%2Fetc%2Fpasswd&Attachment=x&in-reply-to=%3Cm@x%3E&references=%3Cm@x%3E"
                          + "&from=evil@an.example&reply-to=evil@an.example&x-unknown=1&keywords=k&novalue&=empty")
        XCTAssertEqual(parsed, MailtoLink(to: [EmailAddress(address: "a@an.example")]))
    }

    func testABareFragmentIsNotPartOfTheMessage() {
        let parsed = link("mailto:a@an.example?subject=Hi#section")
        XCTAssertEqual(parsed.subject, "Hi")
        XCTAssertEqual(link("mailto:a@an.example#frag"), MailtoLink(to: [EmailAddress(address: "a@an.example")]))
    }

    func testAnEmptyLinkOpensAnEmptyComposer() {
        XCTAssertEqual(link("mailto:"), MailtoLink())
        XCTAssertEqual(link("mailto:?"), MailtoLink())
    }

    // MARK: Malformed input never crashes

    func testAMalformedEscapeIsKeptAsWritten() {
        let parsed = link("mailto:a@an.example?subject=100%&body=50%2&cc=%zzc@an.example")
        XCTAssertEqual(parsed.subject, "100%")
        XCTAssertEqual(parsed.body, "50%2")
        XCTAssertEqual(addresses(parsed.cc), ["%zzc@an.example"])
    }

    func testBytesThatAreNotUTF8LeaveTheFieldAsWritten() {
        // Latin-1 é, which some old pages still write.
        let parsed = link("mailto:a@an.example?subject=caf%E9&body=ok")
        XCTAssertEqual(parsed.subject, "caf%E9")
        XCTAssertEqual(parsed.body, "ok", "the other fields still decode")
    }

    func testOtherSchemesAreNotMailLinks() {
        XCTAssertNil(MailtoLink(string: "https://example.com/?to=a@an.example"))
        XCTAssertNil(MailtoLink(string: "mailt"))
        XCTAssertNil(MailtoLink(string: ""))
        XCTAssertNil(MailtoLink(url: URL(fileURLWithPath: "/tmp/mailto:a@an.example")))
    }

    func testAURLFromLaunchServicesReadsTheSame() throws {
        let url = try XCTUnwrap(URL(string: "mailto:ben@contoso.test?cc=ana@contoso.test&subject=Lunch%3F&body=Noon%0D%0AThe%20usual"))
        XCTAssertEqual(MailtoLink(url: url), MailtoLink(to: [EmailAddress(address: "ben@contoso.test")],
                                                        cc: [EmailAddress(address: "ana@contoso.test")],
                                                        subject: "Lunch?", body: "Noon\nThe usual"))
    }
}
