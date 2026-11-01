import Foundation
import SSCore
import XCTest
@testable import SSGmail

final class GmailBodyParserTests: XCTestCase {
    private func decode(_ json: String) throws -> GmailMessage {
        try JSONDecoder().decode(GmailMessage.self, from: Data(json.utf8))
    }

    private func part(_ json: String) throws -> GmailPart {
        try JSONDecoder().decode(GmailPart.self, from: Data(json.utf8))
    }

    private func message(payload: GmailPart) throws -> GmailMessage {
        var message = try decode(GmailFixtures.metadataM2)
        message.payload = payload
        return message
    }

    func testParsesAlternativeWithInlineImageAndPDF() throws {
        let body = GmailBodyParser.body(from: try decode(GmailFixtures.fullMessage))

        XCTAssertEqual(body.html, GmailFixtures.html)
        XCTAssertEqual(body.text, GmailFixtures.plainText)
        XCTAssertEqual(body.attachments.count, 2)

        let logo = body.attachments[0]
        XCTAssertEqual(logo.id, "ATT_LOGO")
        XCTAssertEqual(logo.filename, "logo.png")
        XCTAssertEqual(logo.mimeType, "image/png")
        XCTAssertEqual(logo.sizeBytes, 2048)
        XCTAssertEqual(logo.contentID, "logo@ss", "angle brackets are stripped so cid: lookups match")
        XCTAssertTrue(logo.isInline)

        let pdf = body.attachments[1]
        XCTAssertEqual(pdf.id, "ATT_PDF")
        XCTAssertEqual(pdf.filename, "report.pdf")
        XCTAssertEqual(pdf.mimeType, "application/pdf")
        XCTAssertEqual(pdf.sizeBytes, 90210)
        XCTAssertNil(pdf.contentID)
        XCTAssertFalse(pdf.isInline)
    }

    func testPlainTextOnlyMessage() throws {
        let text = "Just text \u{2014} with unicode"
        let payload = try part("""
        {"partId":"","mimeType":"text/plain","filename":"","headers":[{"name":"Content-Type","value":"text/plain; charset=\\"UTF-8\\""}],
         "body":{"size":\(text.utf8.count),"data":"\(Base64URL.encode(Data(text.utf8)))"}}
        """)

        let body = GmailBodyParser.body(from: try message(payload: payload))

        XCTAssertNil(body.html)
        XCTAssertEqual(body.text, text)
        XCTAssertTrue(body.attachments.isEmpty)
    }

    func testInlinePartWithoutDispositionIsInlineWhenItHasContentID() throws {
        let payload = try part("""
        {"partId":"","mimeType":"multipart/related","filename":"","body":{"size":0},"parts":[
          {"partId":"0","mimeType":"text/html","filename":"","body":{"size":3,"data":"\(Base64URL.encode(Data("<p>".utf8)))"}},
          {"partId":"1","mimeType":"image/gif","filename":"","headers":[{"name":"Content-ID","value":"<pixel@x>"}],"body":{"attachmentId":"ATT_GIF","size":42}},
          {"partId":"2","mimeType":"image/jpeg","filename":"photo.jpg","body":{"attachmentId":"ATT_JPG","size":99}}
        ]}
        """)

        let body = GmailBodyParser.body(from: try message(payload: payload))

        XCTAssertEqual(body.html, "<p>")
        XCTAssertEqual(body.attachments.count, 2)
        XCTAssertTrue(body.attachments[0].isInline)
        XCTAssertEqual(body.attachments[0].contentID, "pixel@x")
        XCTAssertEqual(body.attachments[0].filename, "pixel.gif", "a nameless inline part gets a name the UI can show")
        XCTAssertFalse(body.attachments[1].isInline)
        XCTAssertNil(body.attachments[1].contentID)
    }

    func testAttachedTextFileIsAnAttachmentNotTheBody() throws {
        let payload = try part("""
        {"partId":"","mimeType":"multipart/mixed","filename":"","body":{"size":0},"parts":[
          {"partId":"0","mimeType":"text/plain","filename":"","body":{"size":5,"data":"\(Base64URL.encode(Data("hello".utf8)))"}},
          {"partId":"1","mimeType":"text/plain","filename":"notes.txt","headers":[{"name":"Content-Disposition","value":"attachment; filename=\\"notes.txt\\""}],"body":{"attachmentId":"ATT_TXT","size":12}}
        ]}
        """)

        let body = GmailBodyParser.body(from: try message(payload: payload))

        XCTAssertEqual(body.text, "hello")
        XCTAssertEqual(body.attachments.map(\.id), ["ATT_TXT"])
        XCTAssertEqual(body.attachments[0].mimeType, "text/plain")
    }

    func testForwardedMessageIsAnAttachmentAndNotRecursed() throws {
        let payload = try part("""
        {"partId":"","mimeType":"multipart/mixed","filename":"","body":{"size":0},"parts":[
          {"partId":"0","mimeType":"text/html","filename":"","body":{"size":9,"data":"\(Base64URL.encode(Data("<p>fwd</p>".utf8)))"}},
          {"partId":"1","mimeType":"message/rfc822","filename":"","headers":[{"name":"Content-Disposition","value":"attachment"}],"body":{"attachmentId":"ATT_EML","size":500},
           "parts":[{"partId":"1.0","mimeType":"text/plain","filename":"","body":{"size":5,"data":"\(Base64URL.encode(Data("inner".utf8)))"}}]}
        ]}
        """)

        let body = GmailBodyParser.body(from: try message(payload: payload))

        XCTAssertEqual(body.html, "<p>fwd</p>")
        XCTAssertNil(body.text, "the embedded message's text must not leak into the outer body")
        XCTAssertEqual(body.attachments.map(\.filename), ["attachment.eml"])
    }

    func testLatin1FallbackWhenBytesAreNotUTF8() throws {
        let latin1 = Data([0x63, 0x61, 0x66, 0xE9])
        let payload = try part("""
        {"partId":"","mimeType":"text/plain","filename":"","headers":[{"name":"Content-Type","value":"text/plain; charset=iso-8859-1"}],
         "body":{"size":4,"data":"\(Base64URL.encode(latin1))"}}
        """)

        let body = GmailBodyParser.body(from: try message(payload: payload))

        XCTAssertEqual(body.text, "caf\u{E9}")
    }

    func testMultipleHTMLPartsAreConcatenatedInOrder() throws {
        let payload = try part("""
        {"partId":"","mimeType":"multipart/mixed","filename":"","body":{"size":0},"parts":[
          {"partId":"0","mimeType":"text/html","filename":"","body":{"size":3,"data":"\(Base64URL.encode(Data("<a>".utf8)))"}},
          {"partId":"1","mimeType":"text/html","filename":"","body":{"size":3,"data":"\(Base64URL.encode(Data("<b>".utf8)))"}}
        ]}
        """)

        let body = GmailBodyParser.body(from: try message(payload: payload))

        XCTAssertEqual(body.html, "<a><b>")
    }

    func testEmptyPayloadYieldsEmptyBody() throws {
        var message = try decode(GmailFixtures.metadataM2)
        message.payload = nil
        let body = GmailBodyParser.body(from: message)
        XCTAssertNil(body.html)
        XCTAssertNil(body.text)
        XCTAssertTrue(body.attachments.isEmpty)
    }

    func testOversizedTextPartIsDeferredRatherThanListedAsAttachment() throws {
        let payload = try part("""
        {"partId":"","mimeType":"multipart/alternative","filename":"","body":{"size":0},"parts":[
          {"partId":"0","mimeType":"text/plain","filename":"","body":{"size":5,"data":"\(Base64URL.encode(Data("hello".utf8)))"}},
          {"partId":"1","mimeType":"text/html","filename":"","headers":[{"name":"Content-Type","value":"text/html; charset=\\"UTF-8\\""}],"body":{"attachmentId":"ATT_HTML","size":123456}}
        ]}
        """)

        var parsed = GmailBodyParser.parse(try message(payload: payload))

        XCTAssertEqual(parsed.body.text, "hello")
        XCTAssertNil(parsed.body.html)
        XCTAssertTrue(parsed.body.attachments.isEmpty)
        let expected = GmailBodyParser.DeferredText(mimeType: "text/html", attachmentID: "ATT_HTML", contentType: "text/html; charset=\"UTF-8\"")
        XCTAssertEqual(parsed.deferred, [expected])

        parsed.resolve(expected, bytes: Data("<p>big</p>".utf8))

        XCTAssertEqual(parsed.body.html, "<p>big</p>")
        XCTAssertTrue(parsed.deferred.isEmpty)
    }

    func testUnnamedPartWithoutAttachmentIDIsDropped() throws {
        let payload = try part("""
        {"partId":"","mimeType":"multipart/mixed","filename":"","body":{"size":0},"parts":[
          {"partId":"0","mimeType":"text/plain","filename":"","body":{"size":5,"data":"\(Base64URL.encode(Data("hello".utf8)))"}},
          {"partId":"1","mimeType":"text/calendar","filename":"","body":{"size":5,"data":"\(Base64URL.encode(Data("BEGIN".utf8)))"}}
        ]}
        """)

        let body = GmailBodyParser.body(from: try message(payload: payload))

        XCTAssertEqual(body.text, "hello")
        XCTAssertTrue(body.attachments.isEmpty, "a part with neither a name nor an attachment id can be neither fetched nor shown")
    }
}
