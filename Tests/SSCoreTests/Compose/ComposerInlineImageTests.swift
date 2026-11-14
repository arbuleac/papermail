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

    func testAWidePictureIsGivenAtMost600PixelsSoClientsThatIgnoreStylesShowItAsItWasSeen() {
        let photo = ComposerInlineImage(contentID: "photo@supersparrow.local", filename: "IMG_0412.jpg", mimeType: "image/jpeg",
                                        width: 4032, height: 3024)
        XCTAssertEqual(photo.sentSize.width, 600)
        XCTAssertEqual(photo.sentSize.height, 450, "its shape kept")
        XCTAssertTrue(photo.html.contains("width=\"600\" height=\"450\""), photo.html)
        XCTAssertTrue(photo.html.contains("max-width: 100%"))
        let exact = ComposerInlineImage(contentID: "e", filename: "e.png", mimeType: "image/png", width: 600, height: 7)
        XCTAssertEqual(exact.sentSize.width, 600, "never scaled up")
        XCTAssertEqual(exact.sentSize.height, 7)
        let sliver = ComposerInlineImage(contentID: "s", filename: "s.png", mimeType: "image/png", width: 5000, height: 2)
        XCTAssertEqual(sliver.sentSize.height, 1, "never zero")
        XCTAssertEqual(ComposerInlineImage.plainText(named: "a.png"), "[image: a.png]")
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
        func classify(fileTypes: [String] = [], imageTypes: [String] = [], text: String? = nil, offersURL: Bool = false,
                      fragment: Bool = false) -> ComposerPasteContent {
            ComposerPasteContent.classify(hasFragment: fragment, fileTypes: fileTypes, imageTypes: imageTypes, text: text, offersURL: offersURL)
        }
        XCTAssertEqual(classify(imageTypes: ["public.png"], text: "x", fragment: true), .fragment)
        XCTAssertEqual(classify(fileTypes: ["public.png", "public.jpeg"], imageTypes: ["public.tiff"], text: "a.png"),
                       .imageFiles, "a Finder copy: the files, not their icon or their names")
        XCTAssertEqual(classify(fileTypes: ["public.png", "com.adobe.pdf"]), .files)
        XCTAssertEqual(classify(fileTypes: ["public.folder"]), .files)
        XCTAssertEqual(classify(fileTypes: [""]), .files, "a file of no known type")
        XCTAssertEqual(classify(imageTypes: ["public.png"]), .image, "a screenshot")
        XCTAssertEqual(classify(imageTypes: ["public.tiff"], text: "https://example.com/a.jpg", offersURL: true),
                       .image, "a browser's Copy Image, which offers the address as a URL too")
        XCTAssertEqual(classify(imageTypes: ["public.tiff"], text: "Q3 numbers\t12\t14"),
                       .text, "a spreadsheet's cells with a picture of them")
        XCTAssertEqual(classify(imageTypes: ["public.png"], text: "https://example.com/report"),
                       .text, "a spreadsheet cell holding one link: the link, not a picture of the cell")
        XCTAssertEqual(classify(imageTypes: ["public.tiff"], text: "Quarterly numbers", offersURL: true), .text, "words are words")
        XCTAssertEqual(classify(imageTypes: [], text: "Hello"), .text)
        XCTAssertEqual(classify(), .text)
    }

    func testAPictureCopiedInTheReaderOrFromAWebAppIsThePictureNotItsAddress() {
        func classify(_ text: String, offersURL: Bool) -> ComposerPasteContent {
            ComposerPasteContent.classify(hasFragment: false, fileTypes: [], imageTypes: ["public.tiff"], text: text, offersURL: offersURL)
        }
        // Copy Image on an inline picture of a received message: WebKit offers the TIFF, the address as text and as a URL.
        let reader = "ss-cid://acct/18c2f0a9/image001.png@01DA0C3B.5E8F1A20"
        XCTAssertEqual(classify(reader, offersURL: true), .image)
        XCTAssertEqual(classify(reader, offersURL: false), .image, "the reader's own address names nothing but a picture")
        XCTAssertEqual(classify("ss-attachment://acct/18c2f0a9/2", offersURL: false), .image)
        XCTAssertEqual(classify("blob:https://chat.example.com/4b1d6a8e-2f6c-4f43-9c2b-1a7f0e3d5c9b", offersURL: false), .image,
                       "a web app's picture")
        XCTAssertEqual(classify("data:image/png;base64,iVBORw0KGgo=", offersURL: false), .image)
        XCTAssertEqual(classify("cid:image001.png@01DA0C3B.5E8F1A20", offersURL: false), .image)
    }

    func testOnlyALoneAddressIsTakenForThePicturesOwn() {
        typealias Content = ComposerPasteContent
        XCTAssertTrue(Content.isPicturesAddress(" https://example.com/a.png\n", offersURL: true))
        XCTAssertFalse(Content.isPicturesAddress("https://example.com/a.png", offersURL: false), "a link, without a URL beside it")
        XCTAssertFalse(Content.isPicturesAddress("file:///Users/alex/Desktop/a.png", offersURL: false))
        XCTAssertTrue(Content.isPicturesAddress("file:///Users/alex/Desktop/a.png", offersURL: true))
        XCTAssertTrue(Content.isPicturesAddress("data:image/png;base64,iVBORw0KGgo=", offersURL: false))
        XCTAssertTrue(Content.isPicturesAddress("blob:https://example.com/1234", offersURL: false))
        XCTAssertTrue(Content.isPicturesAddress("SS-CID://acct/1/a@b", offersURL: false), "schemes are compared ignoring case")
        XCTAssertFalse(Content.isPicturesAddress("see https://example.com/a.png", offersURL: true))
        XCTAssertFalse(Content.isPicturesAddress("mailto:ben@example.com", offersURL: false))
        XCTAssertFalse(Content.isPicturesAddress("Lisbon", offersURL: true))
        XCTAssertFalse(Content.isWriting(nil, offersURL: false))
        XCTAssertFalse(Content.isWriting(" \n", offersURL: false))
        XCTAssertTrue(Content.isWriting("Lisbon", offersURL: true))
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
