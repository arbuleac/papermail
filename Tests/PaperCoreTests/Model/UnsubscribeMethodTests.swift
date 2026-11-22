import XCTest
@testable import PaperCore

/// Reading `List-Unsubscribe` (RFC 2369) and `List-Unsubscribe-Post` (RFC 8058) into the one way to ask: a one-click
/// POST when both headers allow it, else the mailto request, else the page (https, then http).
final class UnsubscribeMethodTests: XCTestCase {
    private func method(_ list: String?, post: String? = nil) -> UnsubscribeMethod? {
        UnsubscribeMethod(listUnsubscribe: list, post: post)
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    // MARK: Order of preference

    func testOneClickNeedsTheExactPostValueBesideAnHTTPSAddress() {
        let list = "<mailto:leave@news.example.com>, <https://news.example.com/u/42>"
        XCTAssertEqual(method(list, post: "List-Unsubscribe=One-Click"), .oneClick(url("https://news.example.com/u/42")),
                       "one-click wins over a mailto listed before it")
        XCTAssertEqual(method(list, post: "  List-Unsubscribe=One-Click\r\n"), .oneClick(url("https://news.example.com/u/42")),
                       "the white space around a header value is not part of it")
        for almost in ["List-Unsubscribe=one-click", "List-Unsubscribe=One-Click; extra", "One-Click", "", "List-Unsubscribe"] {
            XCTAssertEqual(method(list, post: almost), .mailto(url("mailto:leave@news.example.com")), "`\(almost)` is no promise")
        }
        XCTAssertEqual(method("<http://news.example.com/u/42>", post: "List-Unsubscribe=One-Click"),
                       .browser(url("http://news.example.com/u/42")), "never a POST in the clear")
        XCTAssertEqual(method("<mailto:leave@news.example.com>", post: "List-Unsubscribe=One-Click"),
                       .mailto(url("mailto:leave@news.example.com")), "a post header with no https address changes nothing")
        XCTAssertEqual(method("<https://a.example/1>, <https://b.example/2>", post: "List-Unsubscribe=One-Click"),
                       .oneClick(url("https://a.example/1")), "the first https address")
    }

    func testMailtoComesBeforeAPageAndHTTPSBeforeHTTP() {
        XCTAssertEqual(method("<https://news.example.com/u>, <mailto:leave@news.example.com?subject=unsubscribe>"),
                       .mailto(url("mailto:leave@news.example.com?subject=unsubscribe")))
        XCTAssertEqual(method("<http://news.example.com/u>, <https://news.example.com/s>"), .browser(url("https://news.example.com/s")))
        XCTAssertEqual(method("<http://news.example.com/u>"), .browser(url("http://news.example.com/u")), "http only as the last resort")
        XCTAssertEqual(method("<HTTPS://NEWS.EXAMPLE.COM/U>"), .browser(url("HTTPS://NEWS.EXAMPLE.COM/U")), "schemes in any case")
        XCTAssertEqual(method("<MAILTO:LEAVE@NEWS.EXAMPLE.COM>"), .mailto(url("MAILTO:LEAVE@NEWS.EXAMPLE.COM")))
    }

    // MARK: RFC 2369 syntax

    func testCommentsAndFoldingWhiteSpaceAreTolerated() {
        // The RFC's own example, a comment before the address.
        XCTAssertEqual(method("(Use this command to get off the list) <mailto:list-manager@host.com?body=unsubscribe%20list>"),
                       .mailto(url("mailto:list-manager@host.com?body=unsubscribe%20list")))
        // A long address broken across lines: the white space inside the brackets goes.
        XCTAssertEqual(method("<https://news.example.com/\r\n unsubscribe?u=1\t&t=2>"),
                       .browser(url("https://news.example.com/unsubscribe?u=1&t=2")))
        // A comment may nest and quote a parenthesis, and an address inside it is not one.
        XCTAssertEqual(method(#"(see (the) \) <https://evil.example/>) <mailto:leave@news.example.com>"#),
                       .mailto(url("mailto:leave@news.example.com")))
        XCTAssertEqual(UnsubscribeMethod.uris(in: " <a:1> ,\r\n\t<b:2>,<c:3> (x) "), ["a:1", "b:2", "c:3"])
    }

    func testOnlyBracketedMailtoHTTPSAndHTTPAddressesCount() {
        XCTAssertNil(method(nil))
        XCTAssertNil(method(""))
        XCTAssertNil(method(nil, post: "List-Unsubscribe=One-Click"), "a post header alone is nothing")
        XCTAssertNil(method("https://news.example.com/u"), "an address outside angle brackets is not read")
        XCTAssertNil(method("<ftp://news.example.com/u>, <javascript:alert(1)>, <tel:+15551234>"))
        XCTAssertNil(method("<mailto:?subject=unsubscribe>"), "a mailto with no recipient")
        XCTAssertNil(method("<https:///u>"), "a page with no host")
        XCTAssertNil(method("<https://alex:secret@news.example.com/u>"), "a page carrying a user name and password")
        XCTAssertNil(method("<https://news.example.com/u"), "an unclosed bracket")
        XCTAssertEqual(method("<https://alex@news.example.com/u>, <https://news.example.com/v>"),
                       .browser(url("https://news.example.com/v")), "one with a user name is skipped, not the rest")
        XCTAssertNil(method("<https://news.example.com/" + String(repeating: "a", count: 2100) + ">"), "an address past 2048 bytes")
        XCTAssertNil(method("<mailto:leave@news.example.com> " + String(repeating: " ", count: 9000)), "a header past 8 KB")
    }

    func testCapturedHeadersAreTrimmedAndBounded() {
        XCTAssertEqual(UnsubscribeMethod.capturedHeader("  <mailto:a@b.c>\r\n"), "<mailto:a@b.c>")
        XCTAssertNil(UnsubscribeMethod.capturedHeader(" \t "))
        XCTAssertNil(UnsubscribeMethod.capturedHeader(nil))
        XCTAssertNil(UnsubscribeMethod.capturedHeader(String(repeating: "x", count: 8 * 1024 + 1)))
    }

    func testAMessageOffersWhatItsStoredHeadersOffer() {
        var message = MessageMetadata(id: MessageID(accountID: AccountID("a"), providerID: "m"),
                                      conversationID: ConversationID(accountID: AccountID("a"), providerID: "c"),
                                      subject: "Issue", snippet: "", from: nil, date: Date(), roles: [.inbox], isRead: true,
                                      isStarred: false, hasAttachments: false)
        XCTAssertNil(UnsubscribeMethod(message: message), "a message stored before the headers were kept")
        message.listUnsubscribe = "<https://news.example.com/u>"
        message.listUnsubscribePost = "List-Unsubscribe=One-Click"
        XCTAssertEqual(UnsubscribeMethod(message: message), .oneClick(url("https://news.example.com/u")))
    }

    // MARK: What each method does

    func testTheMailtoRequestCarriesTheLinksFieldsAndADefaultSubject() throws {
        let account = AccountID("acct")
        let full = try XCTUnwrap(method("<mailto:leave@news.example.com?subject=Stop%20please&body=unsubscribe%0D%0Ame%20%3Cnow%3E>"))
        let message = try XCTUnwrap(full.mailMessage(from: account))
        XCTAssertEqual(message.accountID, account)
        XCTAssertEqual(message.to.map(\.address), ["leave@news.example.com"])
        XCTAssertEqual(message.subject, "Stop please")
        XCTAssertEqual(message.text, "unsubscribe\nme <now>")
        XCTAssertEqual(message.html, "<div>unsubscribe<br>me &lt;now&gt;</div>", "Graph sends the HTML alone, escaped")
        XCTAssertNil(message.inReplyTo, "a request of its own, not a reply")
        XCTAssertTrue(message.attachments.isEmpty)

        let bare = try XCTUnwrap(method("<mailto:leave@news.example.com>")?.mailMessage(from: account))
        XCTAssertEqual(bare.subject, "Unsubscribe", "a link with no subject")
        XCTAssertEqual(bare.text, "")
        XCTAssertEqual(bare.html, "")

        XCTAssertNil(UnsubscribeMethod.oneClick(url("https://news.example.com/u")).mailMessage(from: account))
        XCTAssertNil(UnsubscribeMethod.browser(url("https://news.example.com/u")).mailMessage(from: account))
    }

    /// The request leaves silently from the user's account with words the sender chose: it goes to the one list
    /// address and nowhere else, so a sender cannot turn a click into mail to people it picked.
    func testTheMailtoRequestGoesToOneAddressOnly() throws {
        let account = AccountID("acct")
        let hidden = try XCTUnwrap(method("<mailto:leave@news.example.com?cc=a@victim.example&bcc=b@victim.example,c@victim.example&body=hi>"))
        XCTAssertEqual(hidden, .mailto(url("mailto:leave@news.example.com?cc=a@victim.example&bcc=b@victim.example,c@victim.example&body=hi")))
        let message = try XCTUnwrap(hidden.mailMessage(from: account))
        XCTAssertEqual(message.to.map(\.address), ["leave@news.example.com"])
        XCTAssertEqual(message.cc, [], "a Cc in the link is never used")
        XCTAssertEqual(message.bcc, [], "nor a Bcc")

        // Several recipients, in the path or in `to` fields: not a request Paper sends. The page is used if
        // offered, and nothing otherwise.
        XCTAssertNil(method("<mailto:a@victim.example,b@victim.example>"))
        XCTAssertNil(method("<mailto:leave@news.example.com?to=a@victim.example>"))
        XCTAssertEqual(method("<mailto:a@victim.example,b@victim.example>, <https://news.example.com/u>"),
                       .browser(url("https://news.example.com/u")))
        XCTAssertEqual(method("<mailto:a@victim.example;b@victim.example>, <mailto:leave@news.example.com>"),
                       .mailto(url("mailto:leave@news.example.com")), "the first mailto with one recipient")
        XCTAssertEqual(method("<mailto:leave@news.example.com?to=LEAVE@news.example.com>"),
                       .mailto(url("mailto:leave@news.example.com?to=LEAVE@news.example.com")), "the same address twice is one")
        XCTAssertNil(UnsubscribeMethod.mailto(url("mailto:a@victim.example,b@victim.example")).mailMessage(from: account),
                     "a stored request naming several is never sent")
    }

    func testRequestsAndPagesAreToldApartAndTravelAsOperations() throws {
        XCTAssertTrue(UnsubscribeMethod.oneClick(url("https://a.example/u")).isRequest)
        XCTAssertTrue(UnsubscribeMethod.mailto(url("mailto:a@a.example")).isRequest)
        XCTAssertFalse(UnsubscribeMethod.browser(url("https://a.example/u")).isRequest)
        XCTAssertEqual(UnsubscribeMethod.browser(url("https://a.example/u")).url, url("https://a.example/u"))

        // The outbox stores the change as JSON: the method and its URI come back as they went in, and change nothing.
        let change = MetadataChange.unsubscribe(.oneClick(url("https://news.example.com/u/42?t=a%20b")))
        let decoded = try JSONDecoder().decode(MetadataChange.self, from: JSONEncoder().encode(change))
        XCTAssertEqual(decoded, change)
        XCTAssertEqual(change.kind, .unsubscribe)
        let message = MessageMetadata(id: MessageID(accountID: AccountID("a"), providerID: "m"),
                                      conversationID: ConversationID(accountID: AccountID("a"), providerID: "c"),
                                      subject: "", snippet: "", from: nil, date: Date(), roles: [.inbox], isRead: false,
                                      isStarred: false, hasAttachments: false)
        XCTAssertEqual(applying(change, to: message), message)
    }
}
