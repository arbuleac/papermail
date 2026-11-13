import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// Pictures in the composer's body (spec §5.20, Images in the body; roadmap Q3.3): pasted or dropped where the caret or
/// the pointer is, drawn no wider than the text on a line grown to hold them, sent as `cid:` parts their `<img>` points
/// at, kept in drafts across a relaunch, undone like text, copied inside the body as pictures, read by name by
/// VoiceOver; files that are not all pictures attach instead, and text beside a picture of itself pastes as text.
/// Pasteboards are private ones, never the user's clipboard; drafts go to a temporary folder; nothing reaches the network.
@MainActor
final class ComposerInlineImageTests: XCTestCase {
    private var folder: URL!
    private var files: URL!
    private var boards: [NSPasteboard] = []

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowInlineImages-\(UUID().uuidString)")
        self.folder = folder
        files = folder.appendingPathComponent("files", isDirectory: true)
        try? FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        MainActor.assumeIsolated { ComposeDraftStore.shared.useDirectory(folder.appendingPathComponent("drafts", isDirectory: true)) }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for panel in ComposeWindowRegistry.shared.livePanels { panel.orderOut(nil); ComposeWindowRegistry.shared.unregister(panel) }
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
            boards.forEach { $0.releaseGlobally() }
            boards = []
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Helpers

    private var composers: [ComposeWindowController] { ComposeWindowRegistry.shared.openControllers }

    private let ben = EmailAddress(name: "Ben Carter", address: "ben@example.com")

    private func newMessage(_ harness: MainWindowHarness) throws -> ComposeWindowController {
        harness.controller.composeNew()
        let composer = try XCTUnwrap(composers.last)
        composer.window?.makeFirstResponder(composer.bodyEditor)
        return composer
    }

    /// A new message to Ben with a subject, ready to send (an empty subject asks first), the caret in the body.
    private func messageToBen(_ harness: MainWindowHarness) throws -> ComposeWindowController {
        let accounts = harness.controller.accounts
        let composer = ComposeWindowController.presentNew(client: harness.environment.engine, account: accounts[0], accounts: accounts, to: ben)
        try giveSubject(to: composer)
        composer.window?.makeFirstResponder(composer.bodyEditor)
        return composer
    }

    private func giveSubject(to composer: ComposeWindowController) throws {
        let row = try XCTUnwrap(Self.views(in: composer.window?.contentView).compactMap { $0 as? ComposeFieldRow }.first { $0.title == "Subject" })
        let field = try XCTUnwrap(row.control as? NSTextField)
        field.stringValue = "The view"
    }

    private static func views(in view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return [view] + view.subviews.flatMap { views(in: $0) }
    }

    private func board() -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("ComposerInlineImage-\(UUID().uuidString)"))
        board.clearContents()
        boards.append(board)
        return board
    }

    /// A pasteboard holding `data` as `type`, and `text` beside it when given, as one item.
    private func board(_ data: Data, as type: NSPasteboard.PasteboardType, text: String? = nil) -> NSPasteboard {
        let board = board()
        let item = NSPasteboardItem()
        item.setData(data, forType: type)
        if let text { item.setString(text, forType: .string) }
        board.writeObjects([item])
        return board
    }

    /// A solid PNG of `width` × `height` pixels at `dpi` (72 is a point per pixel, 144 a Retina screenshot's).
    private static func png(width: Int, height: Int, dpi: Double = 72) -> Data {
        bitmap(width: width, height: height, dpi: dpi).representation(using: .png, properties: [:]) ?? Data()
    }

    private static func bitmap(width: Int, height: Int, dpi: Double = 72) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: Double(width) * 72 / dpi, height: Double(height) * 72 / dpi)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(srgbRed: 0.2, green: 0.5, blue: 0.7, alpha: 1).setFill()
        NSRect(origin: .zero, size: rep.size).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func file(_ name: String, _ data: Data) throws -> URL {
        let url = files.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func type(_ text: String, in composer: ComposeWindowController) {
        let editor = composer.bodyEditor
        editor.insertText(text, replacementRange: editor.selectedRange())
        ListTestSupport.spin(for: 0.02)
    }

    private func pictures(_ composer: ComposeWindowController) -> [ComposeImageAttachment] {
        ComposeInlineImages.pictures(in: composer.contents.body)
    }

    private func queuedSend(_ harness: MainWindowHarness) throws -> OutgoingMessage {
        XCTAssertTrue(ListTestSupport.spin(until: { (try? harness.environment.store.pendingSends().isEmpty) == false }, timeout: 5))
        return try XCTUnwrap(try harness.environment.store.pendingSends().last).message
    }

    /// The point, in window coordinates, over the left half of the character at `index`, where a drop inserts before it.
    private func windowPoint(atCharacter index: Int, in editor: ComposeTextView) throws -> NSPoint {
        let layout = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        layout.ensureLayout(for: container)
        let glyph = layout.glyphIndexForCharacter(at: index)
        let rect = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
            .offsetBy(dx: editor.textContainerOrigin.x, dy: editor.textContainerOrigin.y)
        return editor.convert(NSPoint(x: rect.minX + 1, y: rect.midY), to: nil)
    }

    private func fileDrag(_ urls: [URL]) -> FakeDraggingInfo {
        let board = board()
        board.writeObjects(urls.map { $0 as NSURL })
        return FakeDraggingInfo(pasteboard: board, source: nil, mask: [.copy, .generic])
    }

    // MARK: Pasting

    func testAPastedScreenshotGoesInAtTheCaretAndIsSentAsACidPartItsImgPointsAt() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try messageToBen(harness)
        type("Look at this:", in: composer)
        let editor = composer.bodyEditor
        let caret = editor.selectedRange().location
        let bytes = Self.png(width: 300, height: 120)
        editor.pasteboard = board(bytes, as: .png)
        editor.paste(nil)

        let body = composer.contents.body
        XCTAssertEqual((body.string as NSString).character(at: caret), 0xFFFC, "the picture is where the caret was")
        let picture = try XCTUnwrap(body.attribute(.attachment, at: caret, effectiveRange: nil) as? ComposeImageAttachment)
        XCTAssertEqual(body.attribute(ComposerInlineImage.attributeKey, at: caret, effectiveRange: nil) as? String, picture.inlineImage.contentID)
        XCTAssertEqual(editor.selectedRange(), NSRange(location: caret + 1, length: 0), "the caret after it")
        XCTAssertEqual(picture.data, bytes, "a PNG goes as it came")
        XCTAssertEqual(picture.inlineImage.filename, "image.png")
        XCTAssertEqual(picture.inlineImage.mimeType, "image/png")
        XCTAssertEqual([picture.inlineImage.width, picture.inlineImage.height], [300, 120])
        XCTAssertNil(editor.typingAttributes[ComposerInlineImage.attributeKey], "typing after it writes text, not the picture's mark")
        XCTAssertNotNil(editor.typingAttributes[.baselineOffset], "and in the writing style it interrupted")

        type(" Nice?", in: composer)
        composer.send(nil)
        let message = try queuedSend(harness)
        let part = try XCTUnwrap(message.attachments.first { $0.contentID != nil })
        XCTAssertEqual(part.contentID, picture.inlineImage.contentID)
        XCTAssertEqual(part.data, bytes)
        XCTAssertEqual(part.mimeType, "image/png")
        XCTAssertEqual(part.filename, "image.png")
        XCTAssertTrue(message.html.hasPrefix("<div><p>Look at this:<img src=\"cid:\(part.contentID!)\" alt=\"image.png\" width=\"300\" height=\"120\""),
                      message.html)
        XCTAssertTrue(message.text.hasPrefix("Look at this:[image: image.png] Nice?"), message.text)
    }

    func testARetinaScreenshotIsSentAtItsSizeOnScreenAndATIFFAsAPNG() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        let editor = composer.bodyEditor
        editor.pasteboard = board(Self.png(width: 400, height: 200, dpi: 144), as: .png)
        editor.paste(nil)
        let retina = try XCTUnwrap(pictures(composer).first)
        XCTAssertEqual([retina.inlineImage.width, retina.inlineImage.height], [200, 100], "points, not pixels")

        let tiff = try XCTUnwrap(Self.bitmap(width: 64, height: 32).tiffRepresentation)
        editor.pasteboard = board(tiff, as: .tiff)
        editor.paste(nil)
        let converted = try XCTUnwrap(pictures(composer).last)
        XCTAssertEqual(converted.inlineImage.mimeType, "image/png", "a TIFF becomes a PNG, which every client shows")
        XCTAssertEqual(converted.inlineImage.filename, "image.png")
        XCTAssertEqual(converted.data.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual([converted.inlineImage.width, converted.inlineImage.height], [64, 32])
        XCTAssertNotEqual(converted.inlineImage.contentID, retina.inlineImage.contentID, "every paste is a part of its own")
    }

    func testTextBesideAPictureOfItselfPastesAsTextAndABrowsersPictureBesideItsAddressPastesAsThePicture() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        let editor = composer.bodyEditor
        let tiff = try XCTUnwrap(Self.bitmap(width: 40, height: 20).tiffRepresentation)
        // A word processor's or a spreadsheet's copy: the words, and a picture of them.
        XCTAssertFalse(editor.readPicturesOrFiles(from: board(tiff, as: .tiff, text: "Quarterly numbers"), actionName: nil))
        XCTAssertTrue(pictures(composer).isEmpty)
        // A browser's Copy Image: the picture, and its address as text, which names it.
        XCTAssertTrue(editor.readPicturesOrFiles(from: board(Self.png(width: 40, height: 20), as: .png,
                                                             text: "https://example.com/photos/sunset.jpg?w=40"), actionName: nil))
        XCTAssertEqual(pictures(composer).map(\.inlineImage.filename), ["sunset.png"], "named from its address, with its own format")
        // Text alone is text: the caller pastes it plain.
        XCTAssertFalse(editor.readPicturesOrFiles(from: { let b = board(); b.setString("Hello", forType: .string); return b }(), actionName: nil))
    }

    func testCopiedFilesThatAreAllPicturesPasteIntoTheTextAndOthersAttach() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        let editor = composer.bodyEditor
        let photo = try file("Terrace.png", Self.png(width: 50, height: 50))
        let notes = try file("notes.pdf", Data("%PDF-1.4\n".utf8))
        let finder = board()
        finder.writeObjects([photo as NSURL])
        editor.pasteboard = finder
        editor.paste(nil)
        XCTAssertEqual(pictures(composer).map(\.inlineImage.filename), ["Terrace.png"], "the file's own name")
        XCTAssertTrue(composer.contents.attachments.isEmpty)

        let both = board()
        both.writeObjects([photo as NSURL, notes as NSURL])
        editor.pasteboard = both
        editor.paste(nil)
        XCTAssertEqual(pictures(composer).count, 1, "a mix goes into the text no further")
        XCTAssertEqual(composer.contents.attachments.map(\.filename), ["Terrace.png", "notes.pdf"], "it attaches, as a drop of it would")
    }

    func testAPictureFileTheMacCannotReadAttachesInstead() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        let broken = try file("broken.png", Data("not a picture".utf8))
        let finder = board()
        finder.writeObjects([broken as NSURL])
        composer.bodyEditor.pasteboard = finder
        composer.bodyEditor.paste(nil)
        XCTAssertTrue(pictures(composer).isEmpty)
        XCTAssertEqual(composer.contents.attachments.map(\.filename), ["broken.png"])
    }

    // MARK: Dropping

    func testPicturesDroppedOnTheTextGoInWhereTheyLandAndAMixedDropAttaches() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        type("Before after", in: composer)
        let editor = composer.bodyEditor
        let photo = try file("pier.png", Self.png(width: 40, height: 30))
        let notes = try file("notes.pdf", Data("%PDF-1.4\n".utf8))

        let drop = fileDrag([photo])
        drop.draggingLocation = try windowPoint(atCharacter: 7, in: editor)
        XCTAssertEqual(editor.draggingEntered(drop), .copy)
        XCTAssertTrue(editor.performDragOperation(drop))
        editor.draggingEnded(drop)
        XCTAssertEqual(editor.string, "Before \u{FFFC}after", "the picture goes in where it was dropped")
        XCTAssertEqual(pictures(composer).map(\.inlineImage.filename), ["pier.png"])

        let mixed = fileDrag([photo, notes])
        mixed.draggingLocation = try windowPoint(atCharacter: 0, in: editor)
        XCTAssertEqual(editor.draggingEntered(mixed), .copy, "the composer takes it, with its Drop to attach outline")
        XCTAssertTrue(editor.performDragOperation(mixed))
        editor.draggingEnded(mixed)
        XCTAssertEqual(editor.string, "Before \u{FFFC}after", "nothing more in the text")
        XCTAssertEqual(composer.contents.attachments.map(\.filename), ["pier.png", "notes.pdf"])
    }

    func testAPictureDraggedFromABrowserGoesInWhereItIsDropped() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        type("ab", in: composer)
        let editor = composer.bodyEditor
        let drag = FakeDraggingInfo(pasteboard: board(Self.png(width: 20, height: 20), as: .png, text: "https://example.com/a.png"),
                                    source: nil, mask: [.copy, .generic])
        drag.draggingLocation = try windowPoint(atCharacter: 1, in: editor)
        XCTAssertNotEqual(editor.draggingEntered(drag), [])
        XCTAssertTrue(editor.performDragOperation(drag))
        editor.draggingEnded(drag)
        XCTAssertEqual(editor.string, "a\u{FFFC}b")
    }

    // MARK: Layout

    func testAWidePictureFitsTheTextAndItsLineGrowsToHoldIt() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        type("Above\n", in: composer)
        let editor = composer.bodyEditor
        editor.pasteboard = board(Self.png(width: 2000, height: 1000), as: .png)
        editor.paste(nil)
        type("\nBelow", in: composer)

        let layout = try XCTUnwrap(editor.layoutManager)
        let container = try XCTUnwrap(editor.textContainer)
        layout.ensureLayout(for: container)
        let index = (editor.string as NSString).range(of: "\u{FFFC}").location
        let glyph = layout.glyphIndexForCharacter(at: index)
        let size = layout.attachmentSize(forGlyphAt: glyph)
        let textWidth = container.size.width - 2 * container.lineFragmentPadding
        XCTAssertLessThanOrEqual(size.width, textWidth, "never wider than the text")
        XCTAssertGreaterThan(size.width, textWidth - 2, "scaled down to it, not further")
        XCTAssertEqual(size.height, (size.width / 2).rounded(), accuracy: 1, "its shape kept")

        var lineRect = NSRect.zero
        var previousLine = NSRect.zero
        layout.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layout.numberOfGlyphs)) { rect, _, _, range, stop in
            if NSLocationInRange(glyph, range) {
                lineRect = rect
                stop.pointee = true
            } else {
                previousLine = rect
            }
        }
        XCTAssertGreaterThanOrEqual(lineRect.height, size.height, "the line holds the picture")
        let drawn = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        XCTAssertGreaterThanOrEqual(drawn.minY, previousLine.maxY - 0.5, "it is not drawn over the line above")
        XCTAssertEqual(previousLine.height, ComposeTextView.bodyRole.lineHeight, "lines of text keep the writing style's height")
        XCTAssertGreaterThanOrEqual(editor.intrinsicContentSize.height, lineRect.maxY, "the editor grows with it")
    }

    // MARK: Editing

    func testUndoTakesAPastedPictureOutAndRedoPutsItBack() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        type("Hi", in: composer)
        let editor = composer.bodyEditor
        editor.pasteboard = board(Self.png(width: 20, height: 20), as: .png)
        editor.paste(nil)
        ListTestSupport.spin(for: 0.02)
        let undo = try XCTUnwrap(editor.undoManager)
        XCTAssertEqual(undo.undoActionName, "Paste")
        undo.undo()
        XCTAssertEqual(editor.string, "Hi")
        XCTAssertTrue(pictures(composer).isEmpty, "nothing left to send")
        undo.redo()
        XCTAssertEqual(pictures(composer).count, 1)
    }

    func testCopyingAPictureInsideTheBodyPastesItAsAPictureOfItsOwn() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        type("One ", in: composer)
        let editor = composer.bodyEditor
        let bytes = Self.png(width: 30, height: 30)
        editor.pasteboard = board(bytes, as: .png)
        editor.paste(nil)
        type(" two", in: composer)
        let original = try XCTUnwrap(pictures(composer).first)

        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        let copied = board()
        XCTAssertTrue(editor.writeSelection(to: copied, types: editor.writablePasteboardTypes))
        XCTAssertEqual(copied.string(forType: .string), "One  two", "other apps get the words without the picture's character")
        XCTAssertFalse(copied.types?.contains(.rtfd) ?? false)

        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.pasteboard = copied
        editor.paste(nil)
        let all = pictures(composer)
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(editor.string, "One \u{FFFC} twoOne \u{FFFC} two")
        XCTAssertEqual(all.last?.data, bytes)
        XCTAssertNotEqual(all.last?.inlineImage.contentID, original.inlineImage.contentID)

        // One picture selected alone is offered to other apps as that picture.
        editor.setSelectedRange(NSRange(location: 4, length: 1))
        let single = board()
        XCTAssertTrue(editor.writeSelection(to: single, types: editor.writablePasteboardTypes))
        XCTAssertEqual(single.data(forType: .png), bytes)
    }

    func testVoiceOverReadsAPictureByItsName() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        let editor = composer.bodyEditor
        let photo = try file("Terrace.png", Self.png(width: 20, height: 20))
        let finder = board()
        finder.writeObjects([photo as NSURL])
        editor.pasteboard = finder
        editor.paste(nil)
        let picture = try XCTUnwrap(pictures(composer).first)
        XCTAssertEqual((picture.attachmentCell as? NSCell)?.accessibilityLabel(), "Terrace.png")
        let spoken = try XCTUnwrap(editor.accessibilityAttributedString(for: NSRange(location: 0, length: 1)))
        XCTAssertNotNil(spoken.attribute(NSAttributedString.Key("AXAttachment"), at: 0, effectiveRange: nil),
                        "the text hands VoiceOver the picture as an element of its own")
    }

    func testTheSignatureFieldTakesNoPictures() {
        let field = SignatureEditorView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        let editor = field.textView
        XCTAssertFalse(editor.importsGraphics)
        XCTAssertFalse(editor.allowsImageEditing)
        XCTAssertEqual(editor.readablePasteboardTypes, [.string, ComposeTextView.legacyStringType])
        XCTAssertEqual(editor.acceptableDragTypes, [.string])
        XCTAssertFalse(editor.readSelection(from: board(Self.png(width: 10, height: 10), as: .png)))
        XCTAssertEqual(editor.string, "")
    }

    func testTheComposerBodyTakesPicturesButNeverEditsThem() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let editor = try newMessage(harness).bodyEditor
        XCTAssertTrue(editor.importsGraphics)
        XCTAssertFalse(editor.allowsImageEditing)
        XCTAssertTrue(editor.acceptableDragTypes.contains(.png))
        XCTAssertTrue(editor.acceptableDragTypes.contains(.fileURL))
        XCTAssertFalse(editor.acceptableDragTypes.contains(.rtf), "styled text is never taken")
        XCTAssertFalse(editor.readablePasteboardTypes.contains(NSPasteboard.PasteboardType("com.adobe.pdf")), "a PDF is a document")
    }

    // MARK: Drafts

    func testAKeptDraftKeepsItsPicturesAcrossARelaunch() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        type("The view:\n", in: composer)
        let editor = composer.bodyEditor
        let bytes = Self.png(width: 120, height: 80, dpi: 144)
        editor.pasteboard = board(bytes, as: .png)
        editor.paste(nil)
        type("\nSee you", in: composer)
        let picture = try XCTUnwrap(pictures(composer).first)
        let id = composer.draftID
        XCTAssertTrue(ComposeDraftStore.shared.saveNow(composer.contents))

        // What is on disk: the record names the picture, its bytes are a file of their own, the archive holds no bytes.
        let draftsFolder = folder.appendingPathComponent("drafts", isDirectory: true)
        let draftFolder = draftsFolder.appendingPathComponent(ListTestSupport.accountA.id.rawValue).appendingPathComponent(id.uuidString)
        let record = try ComposeDraftRecord.decode(Data(contentsOf: draftFolder.appendingPathComponent(ComposeDraftRecord.recordFile)))
        let stored = try XCTUnwrap(record.images?.first)
        XCTAssertEqual(record.images?.count, 1)
        XCTAssertEqual(stored.contentID, picture.inlineImage.contentID)
        XCTAssertEqual(try Data(contentsOf: draftFolder.appendingPathComponent(stored.storedFile)), bytes)
        XCTAssertEqual(record.preview, "The view: See you", "a picture is no words in the Drafts row")
        let archive = try Data(contentsOf: draftFolder.appendingPathComponent(ComposeDraftRecord.bodyFile))
        XCTAssertNil(archive.range(of: bytes.prefix(64)), "the archive keeps the picture's place, not its bytes")
        composer.closeWithoutSaving()

        // A relaunch: a store of its own over the same folder.
        let relaunched = ComposeDraftStore(directory: draftsFolder)
        var draft = try XCTUnwrap(relaunched.draft(id: id, accounts: harness.controller.accounts))
        XCTAssertEqual(draft.body.string, "The view:\n\u{FFFC}\nSee you")
        let back = try XCTUnwrap(ComposeInlineImages.pictures(in: draft.body).first)
        XCTAssertEqual(back.inlineImage, picture.inlineImage, "the same part: content id, name, type and size")
        XCTAssertEqual(back.data, bytes)

        // Reopened, it is sent as it would have been.
        draft.to = [ben]
        let reopened = ComposeWindowController.present(client: harness.environment.engine, accounts: harness.controller.accounts, draft: draft)
        try giveSubject(to: reopened)
        XCTAssertEqual(pictures(reopened).first?.inlineImage, picture.inlineImage)
        reopened.send(nil)
        let message = try queuedSend(harness)
        XCTAssertEqual(message.attachments.filter { $0.contentID != nil }.map(\.contentID), [picture.inlineImage.contentID])
        XCTAssertTrue(message.html.contains("<img src=\"cid:\(picture.inlineImage.contentID)\""))
        XCTAssertTrue(message.html.contains("width=\"60\" height=\"40\""), "the Retina picture at its size on screen")
    }

    func testAnUndoneSendReopensWithItsPictures() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try messageToBen(harness)
        type("Here:", in: composer)
        composer.bodyEditor.pasteboard = board(Self.png(width: 40, height: 20), as: .png)
        composer.bodyEditor.paste(nil)
        let picture = try XCTUnwrap(pictures(composer).first)
        composer.send(nil)
        _ = try queuedSend(harness)
        let send = try XCTUnwrap(UndoSendPanel.liveSends.first)
        harness.controller.performUndo(.send(send.id))
        let reopened = try XCTUnwrap(composers.last)
        XCTAssertEqual(reopened.bodyText, "Here:\u{FFFC}")
        XCTAssertEqual(pictures(reopened).first?.inlineImage, picture.inlineImage, "the same picture, ready to send again")
        XCTAssertEqual(pictures(reopened).first?.data, picture.data)
    }

    func testADeletedPicturesBytesLeaveTheDraftWhenItIsSavedAgain() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        type("x", in: composer)
        let editor = composer.bodyEditor
        editor.pasteboard = board(Self.png(width: 10, height: 10), as: .png)
        editor.paste(nil)
        let picture = try XCTUnwrap(pictures(composer).first)
        XCTAssertTrue(ComposeDraftStore.shared.saveNow(composer.contents))
        let draftFolder = folder.appendingPathComponent("drafts").appendingPathComponent(ListTestSupport.accountA.id.rawValue)
            .appendingPathComponent(composer.draftID.uuidString)
        let name = ComposeDraftRecord.Image.storedFile(for: picture.inlineImage.contentID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: draftFolder.appendingPathComponent(name).path))

        editor.setSelectedRange(NSRange(location: 1, length: 1))
        editor.deleteBackward(nil)
        XCTAssertTrue(ComposeDraftStore.shared.saveNow(composer.contents))
        XCTAssertFalse(FileManager.default.fileExists(atPath: draftFolder.appendingPathComponent(name).path))
        let record = try ComposeDraftRecord.decode(Data(contentsOf: draftFolder.appendingPathComponent(ComposeDraftRecord.recordFile)))
        XCTAssertNil(record.images)
    }

    func testABodyHoldingOnlyAPictureIsWorthKeeping() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        composer.bodyEditor.pasteboard = board(Self.png(width: 10, height: 10), as: .png)
        composer.bodyEditor.paste(nil)
        let id = composer.draftID
        composer.window?.performClose(nil)
        ComposeDraftStore.shared.waitForWrites()
        XCTAssertTrue(ComposeDraftStore.shared.contains(id: id), "closing kept it, with no alert")
    }

    func testTheReaderShowsAKeptDraftsPictureByName() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let composer = try newMessage(harness)
        type("Look ", in: composer)
        let photo = try file("pier.jpg", Self.bitmap(width: 10, height: 10).representation(using: .jpeg, properties: [:]) ?? Data())
        let finder = board()
        finder.writeObjects([photo as NSURL])
        composer.bodyEditor.pasteboard = finder
        composer.bodyEditor.paste(nil)
        XCTAssertEqual(pictures(composer).first?.inlineImage.mimeType, "image/jpeg", "a JPEG goes as it came")
        XCTAssertEqual(ComposeInlineImages.readerText(of: composer.contents.body), "Look [image: pier.jpg]")
    }
}
