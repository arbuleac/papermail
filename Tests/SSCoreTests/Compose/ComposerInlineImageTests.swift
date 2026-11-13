import AppKit
import XCTest
@testable import SSCore

/// Pictures in the composer's body (spec §5.20, Images in the body): how a picture is written into the HTML and the
/// plain text, what it is sent as, which formats are kept or encoded again, what a paste or drop puts in the text, and
/// how a kept draft's record names its pictures.
final class ComposerInlineImageTests: XCTestCase {
    private let regular = NSFont.systemFont(ofSize: 13)
    private let sunset = ComposerInlineImage(contentID: "sunset-1@supersparrow.local", filename: "sunset.png", mimeType: "image/png",
                                             width: 480, height: 300)
    private let pier = ComposerInlineImage(contentID: "pier-2@supersparrow.local", filename: "pier & dock.jpg", mimeType: "image/jpeg",
                                           width: 64, height: 48)

    private func text(_ string: String, _ extra: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: regular].merging(extra) { _, new in new })
    }

    private func picture(_ image: ComposerInlineImage, _ extra: [NSAttributedString.Key: Any] = [:]) -> NSAttributedString {
        text("\u{FFFC}", [ComposerInlineImage.attributeKey: image.contentID].merging(extra) { _, new in new })
    }

    private func body(_ parts: NSAttributedString...) -> NSAttributedString {
        let result = NSMutableAttributedString()
        parts.forEach(result.append)
        return result
    }

    private var both: [String: ComposerInlineImage] { [sunset.contentID: sunset, pier.contentID: pier] }

    // MARK: The value

    func testThePictureIsAnImgPointingAtItsPartAndAPlaceholderInPlainText() {
        XCTAssertEqual(sunset.html, "<img src=\"cid:sunset-1@supersparrow.local\" alt=\"sunset.png\" width=\"480\" height=\"300\""
                                    + " style=\"max-width: 100%; height: auto;\">")
        XCTAssertTrue(pier.html.contains("alt=\"pier &amp; dock.jpg\""), "the name is escaped")
        XCTAssertEqual(sunset.plainText, "[image: sunset.png]")
        let part = sunset.outgoing(Data([1, 2, 3]))
        XCTAssertEqual(part, OutgoingAttachment(filename: "sunset.png", mimeType: "image/png", data: Data([1, 2, 3]),
                                                contentID: "sunset-1@supersparrow.local"))
        XCTAssertEqual(ComposerInlineImage(contentID: "x", filename: "x.png", mimeType: "image/png", width: 0, height: -3).width, 1,
                       "never zero, which some clients read as hidden")
    }

    func testContentIDsAreFreshAddressSpecs() {
        let first = ComposerInlineImage.makeContentID()
        let second = ComposerInlineImage.makeContentID()
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasSuffix("@supersparrow.local"))
        XCTAssertNotNil(URL(string: "cid:" + first), "it needs no escaping in a cid: URL")
        XCTAssertFalse(first.contains("<") || first.contains(">") || first.contains(" "))
    }

    // MARK: Export

    func testExportedPicturesStandWhereTheyWereInTheTextAndThePlainText() {
        let output = ComposerHTMLExporter().export(body(text("Look:"), picture(sunset), text(" nice\n"), picture(pier), picture(sunset)),
                                                   images: both)
        XCTAssertEqual(output.html, "<div><p>Look:" + sunset.html + " nice</p><p>" + pier.html + sunset.html + "</p></div>")
        XCTAssertEqual(output.text, "Look:[image: sunset.png] nice\n[image: pier & dock.jpg][image: sunset.png]")
    }

    func testAPictureWithoutItsPartIsLeftOutSoTheHTMLNeverPointsAtNothing() {
        let output = ComposerHTMLExporter().export(body(text("A"), picture(sunset), text("B")), images: [pier.contentID: pier])
        XCTAssertEqual(output.html, "<div><p>AB</p></div>")
        XCTAssertEqual(output.text, "AB")
        // Nor is an attachment character that is no picture of the composer's.
        XCTAssertEqual(ComposerHTMLExporter().export(body(text("A\u{FFFC}B"))).html, "<div><p>AB</p></div>")
    }

    func testAPictureOnItsOwnLineInAListAndInALink() {
        let link: [NSAttributedString.Key: Any] = [.link: URL(string: "https://example.com/album")!]
        let item: [NSAttributedString.Key: Any] = [ComposerBlock.attributeKey: ComposerBlock.bulletItem.rawValue]
        let output = ComposerHTMLExporter().export(body(
            picture(sunset), text("\n"),
            text("Pier ", item), picture(pier, item), text("\n", item),
            text("Album ", link), picture(sunset, link)
        ), images: both)
        XCTAssertEqual(output.html, "<div><p>" + sunset.html + "</p><ul><li>Pier " + pier.html + "</li></ul>"
                                    + "<p><a href=\"https://example.com/album\">Album " + sunset.html + "</a></p></div>")
        XCTAssertEqual(output.text, "[image: sunset.png]\n- Pier [image: pier & dock.jpg]\nAlbum [image: sunset.png] <https://example.com/album>")
    }

    func testAPicturesPlaceholderDoesNotTurnARightToLeftParagraphAround() {
        let output = ComposerHTMLExporter().export(body(picture(sunset), text(" שלום עולם")), images: both)
        XCTAssertTrue(output.html.hasPrefix("<div><p dir=\"rtl\">"), output.html)
    }

    // MARK: Formats

    func testPNGJPEGAndGIFGoAsTheyCameAndOtherFormatsAreEncodedAgain() {
        XCTAssertEqual(ComposerImageFormat.kept("public.png"), .png)
        XCTAssertEqual(ComposerImageFormat.kept("public.jpeg"), .jpeg)
        XCTAssertEqual(ComposerImageFormat.kept("com.compuserve.gif"), .gif)
        XCTAssertNil(ComposerImageFormat.kept("public.tiff"))
        XCTAssertEqual(ComposerImageFormat.sent(as: "public.png"), .png)
        XCTAssertEqual(ComposerImageFormat.sent(as: "com.compuserve.gif"), .gif)
        // Photos in formats many clients do not show become JPEGs.
        for photo in ["public.heic", "public.heif", "public.avif", "org.webmproject.webp", "com.canon.cr2-raw-image", "public.jpeg-xl"] {
            XCTAssertEqual(ComposerImageFormat.sent(as: photo), .jpeg, photo)
        }
        // Anything else, losslessly.
        for other in ["public.tiff", "com.microsoft.bmp", "public.svg-image", "com.example.unknown"] {
            XCTAssertEqual(ComposerImageFormat.sent(as: other), .png, other)
        }
        XCTAssertEqual(ComposerImageFormat(mimeType: "IMAGE/JPEG"), .jpeg)
        XCTAssertNil(ComposerImageFormat(mimeType: "application/pdf"))
        XCTAssertEqual([ComposerImageFormat.png, .jpeg, .gif].map(\.mimeType), ["image/png", "image/jpeg", "image/gif"])
    }

    func testThePictureReadFromAPasteIsTheOneSentUnchangedFirst() {
        XCTAssertEqual(ComposerImageFormat.preferredType(among: ["public.tiff", "public.png"]), "public.png", "a screenshot's PNG over its TIFF")
        XCTAssertEqual(ComposerImageFormat.preferredType(among: ["public.tiff", "com.compuserve.gif", "public.jpeg"]), "public.jpeg")
        XCTAssertEqual(ComposerImageFormat.preferredType(among: ["public.utf8-plain-text", "public.tiff", "public.heic"]), "public.tiff",
                       "else the source's own first")
        XCTAssertNil(ComposerImageFormat.preferredType(among: ["com.adobe.pdf", "public.utf8-plain-text"]), "a PDF is a document")
    }

    func testAPicturesNameIsItsFilesWithTheExtensionItIsSentWith() {
        XCTAssertEqual(ComposerImageFormat.png.filename(from: nil), "image.png")
        XCTAssertEqual(ComposerImageFormat.jpeg.filename(from: "  "), "image.jpg")
        XCTAssertEqual(ComposerImageFormat.jpeg.filename(from: "IMG_0412.HEIC"), "IMG_0412.jpg")
        XCTAssertEqual(ComposerImageFormat.jpeg.filename(from: "photo.JPG"), "photo.JPG", "kept as it is when the format is kept")
        XCTAssertEqual(ComposerImageFormat.png.filename(from: "scan.tiff"), "scan.png")
        XCTAssertEqual(ComposerImageFormat.png.filename(from: "notes"), "notes.png")
    }

    // MARK: What a paste or drop puts in the text

    func testWhatAPasteOrDropPutsInTheText() {
        typealias Content = ComposerPasteContent
        XCTAssertEqual(Content.classify(hasFragment: true, fileTypes: [], imageTypes: ["public.png"], text: "x"), .fragment)
        XCTAssertEqual(Content.classify(hasFragment: false, fileTypes: ["public.png", "public.jpeg"], imageTypes: ["public.tiff"], text: "a.png"),
                       .imageFiles, "a Finder copy: the files, not their icon or their names")
        XCTAssertEqual(Content.classify(hasFragment: false, fileTypes: ["public.png", "com.adobe.pdf"], imageTypes: [], text: nil), .files)
        XCTAssertEqual(Content.classify(hasFragment: false, fileTypes: ["public.folder"], imageTypes: [], text: nil), .files)
        XCTAssertEqual(Content.classify(hasFragment: false, fileTypes: [""], imageTypes: [], text: nil), .files, "a file of no known type")
        XCTAssertEqual(Content.classify(hasFragment: false, fileTypes: [], imageTypes: ["public.png"], text: nil), .image, "a screenshot")
        XCTAssertEqual(Content.classify(hasFragment: false, fileTypes: [], imageTypes: ["public.tiff"], text: "https://example.com/a.jpg"),
                       .image, "a browser's Copy Image")
        XCTAssertEqual(Content.classify(hasFragment: false, fileTypes: [], imageTypes: ["public.tiff"], text: "Q3 numbers\t12\t14"),
                       .text, "a spreadsheet's cells with a picture of them")
        XCTAssertEqual(Content.classify(hasFragment: false, fileTypes: [], imageTypes: [], text: "Hello"), .text)
        XCTAssertEqual(Content.classify(hasFragment: false, fileTypes: [], imageTypes: [], text: nil), .text)
    }

    func testOnlyALoneAddressIsTakenForAPicturesName() {
        XCTAssertTrue(ComposerPasteContent.isOnlyAnAddress(" https://example.com/a.png\n"))
        XCTAssertTrue(ComposerPasteContent.isOnlyAnAddress("file:///Users/alex/Desktop/a.png"))
        XCTAssertTrue(ComposerPasteContent.isOnlyAnAddress("data:image/png;base64,iVBORw0KGgo="))
        XCTAssertFalse(ComposerPasteContent.isOnlyAnAddress("see https://example.com/a.png"))
        XCTAssertFalse(ComposerPasteContent.isOnlyAnAddress("mailto:ben@example.com"))
        XCTAssertFalse(ComposerPasteContent.isOnlyAnAddress("Lisbon"))
        XCTAssertFalse(ComposerPasteContent.isWriting(nil))
        XCTAssertFalse(ComposerPasteContent.isWriting(" \n"))
        XCTAssertTrue(ComposerPasteContent.isWriting("Lisbon"))
    }

    // MARK: Kept drafts

    func testAKeptDraftsRecordNamesItsPicturesAndAnOlderRecordHasNone() throws {
        let account = AccountID("acct")
        let image = ComposeDraftRecord.Image(contentID: sunset.contentID, filename: "sunset.png", mimeType: "image/png", sizeBytes: 3,
                                             storedFile: ComposeDraftRecord.Image.storedFile(for: sunset.contentID))
        XCTAssertEqual(image.storedFile, "image-sunset-1_supersparrow_local", "a file name of its own, from the content id")
        let record = ComposeDraftRecord(id: UUID(), kind: .new, originalMessageID: nil, accountID: account, to: [], cc: [], bcc: [],
                                        subject: "View", attachments: [], quoted: nil, threading: nil, editedAt: Date(timeIntervalSince1970: 0),
                                        images: [image])
        let decoded = try ComposeDraftRecord.decode(record.encoded())
        XCTAssertEqual(decoded.images, [image])

        // A record written before pictures could be pasted has no `images` key.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: record.encoded()) as? [String: Any])
        json["images"] = nil
        let older = try ComposeDraftRecord.decode(JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(older.images)
        XCTAssertEqual(older.subject, "View")
    }

    func testADraftsPreviewLeavesPicturesOut() {
        XCTAssertEqual(ComposeDraftRecord.preview(of: "The view:\n\u{FFFC}\nSee you"), "The view: See you")
        XCTAssertEqual(ComposeDraftRecord.preview(of: "\u{FFFC}"), "")
        XCTAssertEqual(ComposeDraftRecord.preview(of: "a\u{FFFC}b"), "a b")
    }
}
