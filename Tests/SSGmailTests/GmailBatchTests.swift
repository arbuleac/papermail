import Foundation
import SSCore
import XCTest
@testable import SSGmail

final class GmailBatchTests: XCTestCase {
    func testRequestBodyEmbedsOneGetPerPath() throws {
        let request = try GmailBatch.request(paths: ["/gmail/v1/users/me/messages/a?format=metadata", "/gmail/v1/users/me/messages/b?format=metadata"], boundary: "bnd")
        let body = String(decoding: try XCTUnwrap(request.body), as: UTF8.self)

        XCTAssertEqual(request.method, .post)
        XCTAssertEqual(request.url.absoluteString, "https://www.googleapis.com/batch/gmail/v1")
        XCTAssertEqual(request.headers["Content-Type"], "multipart/mixed; boundary=bnd")
        let expected = "--bnd\r\nContent-Type: application/http\r\nContent-ID: <item-0>\r\n\r\nGET /gmail/v1/users/me/messages/a?format=metadata HTTP/1.1\r\n\r\n\r\n"
            + "--bnd\r\nContent-Type: application/http\r\nContent-ID: <item-1>\r\n\r\nGET /gmail/v1/users/me/messages/b?format=metadata HTTP/1.1\r\n\r\n\r\n"
            + "--bnd--\r\n"
        XCTAssertEqual(body, expected)
    }

    func testParsesGoogleShapedReply() throws {
        let reply = StubResponse.batch(boundary: "batch_abc", parts: [
            (0, 200, "{\"id\":\"a\",\"threadId\":\"t\"}"),
            (1, 404, GmailFixtures.notFoundError),
            (2, 200, "{\n  \"id\": \"c\",\n  \"threadId\": \"t\"\n}"),
        ])

        let parts = try GmailBatch.parse(reply.body, contentType: reply.headers["Content-Type"])

        XCTAssertEqual(parts.map(\.status), [200, 404, 200])
        XCTAssertEqual(parts.map(\.index), [0, 1, 2])
        XCTAssertEqual(parts[0].headers["content-type"], "application/json; charset=UTF-8")
        let first = try JSONDecoder().decode(GmailMessage.self, from: parts[0].body)
        XCTAssertEqual(first.id, "a")
        let third = try JSONDecoder().decode(GmailMessage.self, from: parts[2].body)
        XCTAssertEqual(third.id, "c")
    }

    func testQuotedBoundaryAndBareLineFeeds() throws {
        let body = "--b1\nContent-Type: application/http\n\nHTTP/1.1 200 OK\nContent-Type: application/json\n\n{\"id\":\"x\",\"threadId\":\"t\"}\n--b1--\n"
        let parts = try GmailBatch.parse(Data(body.utf8), contentType: "multipart/mixed; boundary=\"b1\"")

        XCTAssertEqual(parts.count, 1)
        XCTAssertNil(parts[0].index)
        XCTAssertEqual(parts[0].status, 200)
        XCTAssertEqual(String(decoding: parts[0].body, as: UTF8.self), "{\"id\":\"x\",\"threadId\":\"t\"}")
    }

    func testRejectsRepliesWithoutMultipartShape() {
        XCTAssertThrowsError(try GmailBatch.parse(Data("<html>".utf8), contentType: "text/html"))
        XCTAssertThrowsError(try GmailBatch.parse(Data("nothing here".utf8), contentType: "multipart/mixed; boundary=zzz"))
        XCTAssertThrowsError(try GmailBatch.parse(Data("--zzz\r\nContent-Type: application/http\r\n\r\nnot a status line\r\n--zzz--".utf8), contentType: "multipart/mixed; boundary=zzz"))
        XCTAssertThrowsError(try GmailBatch.parse(Data(), contentType: nil))
    }

    func testBoundaryExtraction() {
        XCTAssertEqual(GmailBatch.boundary(from: "multipart/mixed; boundary=abc"), "abc")
        XCTAssertEqual(GmailBatch.boundary(from: "multipart/mixed; charset=UTF-8; boundary=\"a b\""), "a b")
        XCTAssertEqual(GmailBatch.boundary(from: "multipart/mixed; BOUNDARY=up"), "up")
        XCTAssertNil(GmailBatch.boundary(from: "application/json"))
        XCTAssertNil(GmailBatch.boundary(from: nil))
    }

    func testBase64URLRoundTrip() throws {
        let bytes = Data((0..<256).map { UInt8($0) })
        let encoded = Base64URL.encode(bytes)
        XCTAssertFalse(encoded.contains("+") || encoded.contains("/") || encoded.contains("="))
        XCTAssertEqual(Base64URL.decode(encoded), bytes)
        XCTAssertEqual(Base64URL.decode("JVBERi0"), Data("%PDF-".utf8))
        XCTAssertEqual(Base64URL.decode("JVBERi0="), Data("%PDF-".utf8), "padded input is accepted too")
        XCTAssertEqual(Base64URL.decode(" SGVs\nbG8 "), Data("Hello".utf8), "whitespace is ignored")
        XCTAssertNil(Base64URL.decode("@@@"))
    }

    func testRFC2047EncodeAndDecode() {
        XCTAssertEqual(RFC2047.encodeIfNeeded("plain ascii"), "plain ascii")
        XCTAssertEqual(RFC2047.encodeIfNeeded("caf\u{E9}"), "=?UTF-8?B?Y2Fmw6k=?=")
        XCTAssertEqual(RFC2047.decode("=?UTF-8?B?Y2Fmw6k=?="), "caf\u{E9}")
        XCTAssertEqual(RFC2047.decode("=?utf-8?q?caf=C3=A9_au_lait?="), "caf\u{E9} au lait")
        XCTAssertEqual(RFC2047.decode("=?UTF-8?B?YWI=?= =?UTF-8?B?Y2Q=?="), "abcd", "whitespace between encoded words is dropped")
        XCTAssertEqual(RFC2047.decode("plain =?UTF-8?B?Y2Fmw6k=?= end"), "plain caf\u{E9} end")
        XCTAssertEqual(RFC2047.decode("no words here"), "no words here")
        XCTAssertEqual(RFC2047.decode("=?BOGUS-CHARSET?B?Y2Fmw6k=?="), "caf\u{E9}", "unknown charsets fall back to UTF-8")
        let words = RFC2047.encodedWords(for: String(repeating: "\u{1F600}", count: 30))
        XCTAssertGreaterThan(words.count, 1)
        for word in words {
            XCTAssertLessThanOrEqual(word.count, 75)
            XCTAssertTrue(word.hasPrefix("=?UTF-8?B?") && word.hasSuffix("?="))
        }
        XCTAssertEqual(RFC2047.decode(words.joined(separator: " ")), String(repeating: "\u{1F600}", count: 30))
    }
}
