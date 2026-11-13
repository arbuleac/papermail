import Foundation
import SSCore
import XCTest
@testable import SSGmail

/// A deliberately independent reader of the builder's output: headers unfolded, multiparts split on
/// their declared boundaries, base64 bodies decoded with Foundation.
private struct ParsedPart {
    var headers: [String: String]
    var rawBody: String
    var children: [ParsedPart]

    var contentType: String { headers["content-type"] ?? "" }
    var mediaType: String { contentType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? "" }

    var decodedBody: Data {
        if headers["content-transfer-encoding"]?.lowercased() == "base64" {
            return Data(base64Encoded: rawBody.filter { !$0.isWhitespace }) ?? Data()
        }
        return Data(rawBody.utf8)
    }

    func parameter(_ name: String, of header: String) -> String? {
        guard let value = headers[header] else { return nil }
        for piece in value.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[0].lowercased() == name else { continue }
            return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return nil
    }

    static func parse(_ text: String) -> ParsedPart {
        let separator = "\r\n\r\n"
        let headerText: String
        let body: String
        if let range = text.range(of: separator) {
            headerText = String(text[..<range.lowerBound])
            body = String(text[range.upperBound...])
        } else {
            headerText = text
            body = ""
        }
        var headers: [String: String] = [:]
        var unfolded: [String] = []
        for line in headerText.components(separatedBy: "\r\n") {
            // RFC 5322 §2.2.3: unfolding removes only the CRLF, the leading whitespace stays.
            if line.hasPrefix(" ") || line.hasPrefix("\t"), !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += line
            } else {
                unfolded.append(line)
            }
        }
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var part = ParsedPart(headers: headers, rawBody: body, children: [])
        if part.mediaType.hasPrefix("multipart/"), let boundary = part.parameter("boundary", of: "content-type") {
            let pieces = body.components(separatedBy: "--" + boundary)
            for piece in pieces.dropFirst() {
                if piece.hasPrefix("--") { break }
                // "\r\n" is a single Character in Swift, so drop one, not two.
                var inner = piece
                if inner.hasPrefix("\r\n") { inner = String(inner.dropFirst()) }
                if inner.hasSuffix("\r\n") { inner = String(inner.dropLast()) }
                part.children.append(parse(inner))
            }
        }
        return part
    }
}

final class MIMEBuilderTests: XCTestCase {
    private let accountID = AccountID("acct-mime")

    private func decodeEncodedWords(_ header: String) -> String {
        var output = ""
        var rest = Substring(header)
        while let start = rest.range(of: "=?UTF-8?B?"), let end = rest.range(of: "?=", range: start.upperBound..<rest.endIndex) {
            let payload = rest[start.upperBound..<end.lowerBound]
            output += String(decoding: Data(base64Encoded: String(payload)) ?? Data(), as: UTF8.self)
            rest = rest[end.upperBound...]
        }
        return output
    }

    func testFullMessageRoundTrips() throws {
        let pdfBytes = Data((0..<1000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF])
        let subject = "R\u{E9}sum\u{E9} \u{2013} \u{00DC}nicode \u{2713}"
        let html = "<p>Hi <b>there</b> <img src=\"cid:logo@ss\"></p>"
        let text = "Hi there\n\n\u{2014} Ada"
        let message = OutgoingMessage(
            accountID: accountID,
            to: [EmailAddress(name: "Doe, John", address: "john@example.com"), EmailAddress(address: "plain@example.com")],
            cc: [EmailAddress(name: "Zo\u{EB} \u{C5}str\u{F6}m", address: "zoe@example.com")],
            bcc: [EmailAddress(address: "hidden@example.com")],
            subject: subject,
            html: html,
            text: text,
            inReplyToInternetMessageID: "<parent@example.com>",
            references: ["<root@example.com>"],
            attachments: [
                OutgoingAttachment(filename: "report.pdf", mimeType: "application/pdf", data: pdfBytes),
                OutgoingAttachment(filename: "logo.png", mimeType: "image/png", data: pngBytes, contentID: "logo@ss"),
            ]
        )
        let date = Date(timeIntervalSince1970: 1_730_462_400)
        let builder = MIMEBuilder(message: message, from: EmailAddress(name: "Ada Lovelace", address: "ada@example.com"), messageID: "<fixed@example.com>", date: date, timeZone: TimeZone(secondsFromGMT: 0) ?? .current)

        let output = String(decoding: builder.build(), as: UTF8.self)

        XCTAssertTrue(output.utf8.allSatisfy { $0 < 128 }, "the raw message must be 7-bit clean")
        XCTAssertFalse(output.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "every line break is CRLF")
        for line in output.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.count, 998)
        }

        let root = ParsedPart.parse(output)
        XCTAssertEqual(root.headers["from"], "Ada Lovelace <ada@example.com>")
        XCTAssertEqual(root.headers["to"], "\"Doe, John\" <john@example.com>, plain@example.com")
        XCTAssertEqual(root.headers["bcc"], "hidden@example.com")
        XCTAssertEqual(root.headers["date"], "Fri, 01 Nov 2024 12:00:00 +0000")
        XCTAssertEqual(root.headers["message-id"], "<fixed@example.com>")
        XCTAssertEqual(root.headers["in-reply-to"], "<parent@example.com>")
        XCTAssertEqual(root.headers["references"], "<root@example.com> <parent@example.com>")
        XCTAssertEqual(root.headers["mime-version"], "1.0")

        let subjectHeader = try XCTUnwrap(root.headers["subject"])
        XCTAssertTrue(subjectHeader.hasPrefix("=?UTF-8?B?"))
        XCTAssertEqual(decodeEncodedWords(subjectHeader), subject)
        let ccHeader = try XCTUnwrap(root.headers["cc"])
        XCTAssertTrue(ccHeader.hasPrefix("=?UTF-8?B?"))
        XCTAssertTrue(ccHeader.hasSuffix(" <zoe@example.com>"))
        XCTAssertEqual(decodeEncodedWords(ccHeader), "Zo\u{EB} \u{C5}str\u{F6}m")

        XCTAssertEqual(root.mediaType, "multipart/mixed")
        XCTAssertEqual(root.children.count, 2)

        let alternative = root.children[0]
        XCTAssertEqual(alternative.mediaType, "multipart/alternative")
        XCTAssertEqual(alternative.children.map(\.mediaType), ["text/plain", "multipart/related"])
        XCTAssertEqual(alternative.children[0].parameter("charset", of: "content-type"), "UTF-8")
        XCTAssertEqual(String(decoding: alternative.children[0].decodedBody, as: UTF8.self), text)

        let related = alternative.children[1]
        XCTAssertEqual(related.parameter("type", of: "content-type"), "text/html")
        XCTAssertEqual(related.children.map(\.mediaType), ["text/html", "image/png"])
        XCTAssertEqual(String(decoding: related.children[0].decodedBody, as: UTF8.self), html)
        let inline = related.children[1]
        XCTAssertEqual(inline.headers["content-id"], "<logo@ss>")
        XCTAssertTrue(inline.headers["content-disposition"]?.hasPrefix("inline;") ?? false)
        XCTAssertEqual(inline.parameter("filename", of: "content-disposition"), "logo.png")
        XCTAssertEqual(inline.decodedBody, pngBytes)

        let pdf = root.children[1]
        XCTAssertEqual(pdf.mediaType, "application/pdf")
        XCTAssertEqual(pdf.parameter("name", of: "content-type"), "report.pdf")
        XCTAssertTrue(pdf.headers["content-disposition"]?.hasPrefix("attachment;") ?? false)
        XCTAssertNil(pdf.headers["content-id"])
        XCTAssertEqual(pdf.headers["content-transfer-encoding"], "base64")
        XCTAssertEqual(pdf.decodedBody, pdfBytes)
        for line in pdf.rawBody.components(separatedBy: "\r\n") where !line.isEmpty {
            XCTAssertLessThanOrEqual(line.count, 76, "base64 bodies are wrapped at 76 columns")
        }

        let boundaries = Set([root, alternative, related].compactMap { $0.parameter("boundary", of: "content-type") })
        XCTAssertEqual(boundaries.count, 3, "nested multiparts need distinct boundaries")
    }

    func testMessageWithoutAttachmentsKeepsMixedAroundAlternative() {
        let message = OutgoingMessage(accountID: accountID, to: [EmailAddress(address: "a@example.com")], subject: "Plain ASCII subject", html: "<p>x</p>", text: "x")
        let root = ParsedPart.parse(String(decoding: MIMEBuilder(message: message).build(), as: UTF8.self))

        XCTAssertEqual(root.headers["subject"], "Plain ASCII subject", "ASCII is never encoded")
        XCTAssertNil(root.headers["from"], "Gmail fills From when the builder is given none")
        XCTAssertNil(root.headers["cc"])
        XCTAssertNil(root.headers["in-reply-to"])
        XCTAssertNil(root.headers["references"])
        XCTAssertEqual(root.mediaType, "multipart/mixed")
        XCTAssertEqual(root.children.count, 1)
        XCTAssertEqual(root.children[0].mediaType, "multipart/alternative")
        XCTAssertEqual(root.children[0].children.map(\.mediaType), ["text/plain", "text/html"])
        let messageID = root.headers["message-id"] ?? ""
        XCTAssertTrue(messageID.hasPrefix("<") && messageID.hasSuffix("@supersparrow.local>"))
    }

    func testMessageIDDomainFollowsSender() {
        let message = OutgoingMessage(accountID: accountID, to: [], subject: "", html: "", text: "")
        let builder = MIMEBuilder(message: message, from: EmailAddress(address: "ada@example.com"))
        XCTAssertTrue(builder.messageID.hasSuffix("@example.com>"))
        XCTAssertTrue(builder.messageID.hasPrefix("<"))
        XCTAssertNotEqual(MIMEBuilder.makeMessageID(domain: "x.org"), MIMEBuilder.makeMessageID(domain: "x.org"))
    }

    func testLongNonASCIISubjectFoldsIntoShortEncodedWords() throws {
        let subject = String(repeating: "\u{00E9}\u{00E8}\u{00EA} ", count: 40)
        let message = OutgoingMessage(accountID: accountID, to: [], subject: subject, html: "", text: "")
        let output = String(decoding: MIMEBuilder(message: message).build(), as: UTF8.self)

        let subjectLines = output.components(separatedBy: "\r\n").enumerated().compactMap { index, line -> String? in
            line.hasPrefix("Subject:") || line.hasPrefix(" =?UTF-8?B?") ? line : nil
        }
        XCTAssertGreaterThan(subjectLines.count, 1)
        for line in subjectLines {
            XCTAssertLessThanOrEqual(line.count, 78)
            let word = line.hasPrefix("Subject: ") ? String(line.dropFirst("Subject: ".count)) : String(line.dropFirst())
            XCTAssertLessThanOrEqual(word.count, 75, "RFC 2047 limits each encoded word to 75 characters")
        }
        let header = try XCTUnwrap(ParsedPart.parse(output).headers["subject"])
        XCTAssertEqual(decodeEncodedWords(header), subject)
    }

    func testHeaderInjectionIsNeutralized() {
        // The cc spec is what AddressParser yields for a crafted From header once the user replies to it.
        let message = OutgoingMessage(
            accountID: accountID,
            to: [EmailAddress(name: "Evil\r\nBcc: victim@example.com", address: "evil@example.com")],
            cc: [EmailAddress(name: "Mallory", address: "mallory@example.com\r\nBcc: victim@example.net\r\nX-Junk: ")],
            subject: "Hello\r\nX-Injected: yes",
            html: "", text: "",
            attachments: [OutgoingAttachment(filename: "a.txt", mimeType: "text/plain\r\nX-Part: yes", data: Data([1]))]
        )
        let output = String(decoding: MIMEBuilder(message: message).build(), as: UTF8.self)
        let root = ParsedPart.parse(output)

        XCTAssertNil(root.headers["x-injected"])
        XCTAssertNil(root.headers["bcc"])
        XCTAssertNil(root.headers["x-junk"])
        XCTAssertEqual(root.headers["subject"], "Hello X-Injected: yes")
        XCTAssertEqual(root.headers["to"], "\"Evil Bcc: victim@example.com\" <evil@example.com>")
        XCTAssertEqual(root.headers["cc"], "Mallory <mallory@example.com Bcc: victim@example.net X-Junk:>")
        XCTAssertNil(root.children[1].headers["x-part"])
        let smuggledLines = output.components(separatedBy: "\r\n").filter { $0.hasPrefix("Bcc:") || $0.hasPrefix("X-") }
        XCTAssertEqual(smuggledLines, [], "no injected text may start a line of its own")
    }

    func testNonASCIIFilenameUsesRFC2231() {
        let message = OutgoingMessage(
            accountID: accountID, to: [], subject: "", html: "", text: "",
            attachments: [OutgoingAttachment(filename: "r\u{E9}sum\u{E9}.pdf", mimeType: "application/pdf", data: Data([1, 2, 3]))]
        )
        let root = ParsedPart.parse(String(decoding: MIMEBuilder(message: message).build(), as: UTF8.self))
        let attachment = root.children[1]
        XCTAssertEqual(attachment.headers["content-disposition"], "attachment; filename*=UTF-8''r%C3%A9sum%C3%A9.pdf")
        XCTAssertEqual(attachment.headers["content-type"], "application/pdf; name*=UTF-8''r%C3%A9sum%C3%A9.pdf")
    }

    func testAddressFormatting() {
        XCTAssertEqual(MIMEBuilder.formatAddress(EmailAddress(address: "a@b.c")), "a@b.c")
        XCTAssertEqual(MIMEBuilder.formatAddress(EmailAddress(name: "Ada Lovelace", address: "a@b.c")), "Ada Lovelace <a@b.c>")
        XCTAssertEqual(MIMEBuilder.formatAddress(EmailAddress(name: "Lovelace, Ada", address: "a@b.c")), "\"Lovelace, Ada\" <a@b.c>")
        XCTAssertEqual(MIMEBuilder.formatAddress(EmailAddress(name: "Ada \"The\" L", address: "a@b.c")), "\"Ada \\\"The\\\" L\" <a@b.c>")
        XCTAssertEqual(MIMEBuilder.formatAddress(EmailAddress(name: "  ", address: "a@b.c")), "a@b.c")
        XCTAssertEqual(MIMEBuilder.formatAddress(EmailAddress(name: "Ad\u{E9}", address: "a@b.c")), "=?UTF-8?B?QWTDqQ==?= <a@b.c>")
    }

    func testBracketedIDs() {
        XCTAssertEqual(MIMEBuilder.bracketed("abc@x"), "<abc@x>")
        XCTAssertEqual(MIMEBuilder.bracketed("<abc@x>"), "<abc@x>")
        XCTAssertEqual(MIMEBuilder.bracketed(" <abc@x> "), "<abc@x>")
    }

    // MARK: Pictures from the composer (spec §5.20, Images in the body)

    /// What the composer sends for a body holding pictures, built the way it builds it: the exporter's HTML and text,
    /// each picture's part beside a file attachment.
    private func composed(pictures: [(ComposerInlineImage, Data)], file: OutgoingAttachment? = nil) -> OutgoingMessage {
        let body = NSMutableAttributedString(string: "The view:")
        for (image, _) in pictures {
            body.append(NSAttributedString(string: "\u{FFFC}", attributes: [ComposerInlineImage.attributeKey: image.contentID]))
        }
        body.append(NSAttributedString(string: " see you"))
        let export = ComposerHTMLExporter().export(body, images: Dictionary(uniqueKeysWithValues: pictures.map { ($0.0.contentID, $0.0) }))
        return OutgoingMessage(accountID: accountID, to: [EmailAddress(address: "ben@example.com")], subject: "Terrace",
                               html: export.html, text: export.text,
                               attachments: (file.map { [$0] } ?? []) + pictures.map { $0.0.outgoing($0.1) })
    }

    func testAComposerPictureTravelsAsARelatedPartItsImgPointsAt() throws {
        let terrace = ComposerInlineImage(contentID: "0f2c9d3e-1@supersparrow.local", filename: "terrace.png", mimeType: "image/png",
                                          width: 480, height: 300)
        let pier = ComposerInlineImage(contentID: "7aa1c2b4-2@supersparrow.local", filename: "pier.jpg", mimeType: "image/jpeg",
                                       width: 64, height: 48)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x01])
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x02])
        let pdf = OutgoingAttachment(filename: "plan.pdf", mimeType: "application/pdf", data: Data("%PDF-1.4".utf8))
        let message = composed(pictures: [(terrace, png), (pier, jpeg)], file: pdf)

        let root = ParsedPart.parse(String(decoding: MIMEBuilder(message: message).build(), as: UTF8.self))

        XCTAssertEqual(root.mediaType, "multipart/mixed")
        XCTAssertEqual(root.children.map(\.mediaType), ["multipart/alternative", "application/pdf"], "only the file is an attachment")
        let alternative = root.children[0]
        XCTAssertEqual(alternative.children.map(\.mediaType), ["text/plain", "multipart/related"])
        XCTAssertEqual(String(decoding: alternative.children[0].decodedBody, as: UTF8.self),
                       "The view:[image: terrace.png][image: pier.jpg] see you")
        let related = alternative.children[1]
        XCTAssertEqual(related.parameter("type", of: "content-type"), "text/html")
        XCTAssertEqual(related.children.map(\.mediaType), ["text/html", "image/png", "image/jpeg"])
        let html = String(decoding: related.children[0].decodedBody, as: UTF8.self)
        for (image, part, bytes) in [(terrace, related.children[1], png), (pier, related.children[2], jpeg)] {
            XCTAssertTrue(html.contains("<img src=\"cid:\(image.contentID)\""), "the HTML points at \(image.filename)")
            XCTAssertEqual(part.headers["content-id"], "<\(image.contentID)>", "and its part answers to that id")
            XCTAssertTrue(part.headers["content-disposition"]?.hasPrefix("inline;") ?? false)
            XCTAssertEqual(part.parameter("filename", of: "content-disposition"), image.filename)
            XCTAssertEqual(part.decodedBody, bytes)
        }
        XCTAssertTrue(html.contains("width=\"480\" height=\"300\""), "shown at its size on screen")
    }

    func testABodyWhosePictureWasDeletedSendsNoRelatedPart() {
        let message = composed(pictures: [])
        let root = ParsedPart.parse(String(decoding: MIMEBuilder(message: message).build(), as: UTF8.self))
        XCTAssertEqual(root.children[0].children.map(\.mediaType), ["text/plain", "text/html"])
        XCTAssertFalse(String(decoding: root.children[0].children[1].decodedBody, as: UTF8.self).contains("cid:"))
    }
}
