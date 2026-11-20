import AppKit
import SSCore
import SSDesign
import WebKit
import XCTest
@testable import SuperSparrowApp

/// What dragging attachments looks like (spec §5.17 Dragging out, §5.18, §5.20): the file card under the pointer, on the
/// reader's desk; a reader whose chip is dragged (the chip dims); the composer's and the quick reply's drop treatment.
/// Light and Dark at 2x, written as PNGs to `SS_RENDER_DIR` (the temporary folder when unset). Opt-in, because it writes
/// files: `SS_UI_TESTS=1 SS_RENDER_DIR=<dir> swift test --filter AttachmentDragRenderTests`.
@MainActor
final class AttachmentDragRenderTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["SS_UI_TESTS"] == "1" else {
            throw XCTSkip("set SS_UI_TESTS=1 to render the drag card and the drop targets")
        }
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentDragRenderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        MainActor.assumeIsolated { ComposeDraftStore.shared.useDirectory(folder.appendingPathComponent("drafts", isDirectory: true)) }
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
        }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    private var renderDirectory: URL {
        let path = ProcessInfo.processInfo.environment["SS_RENDER_DIR"] ?? NSTemporaryDirectory()
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private let modes: [(QuireMode, String)] = [(.light, "light"), (.dark, "dark")]

    /// Cards for a PDF, a long name, a picture and an archive, each drawn as the drag draws it (its shadow in its own
    /// margin), on the reader's desk.
    func testTheDragCard() throws {
        let infos = [
            AttachmentInfo(id: "a", filename: "Contoso rollout plan.pdf", mimeType: "application/pdf", sizeBytes: 240_000, isInline: false),
            AttachmentInfo(id: "b", filename: "Quarterly report for the board, final version, with appendices.docx",
                           mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", sizeBytes: 2_400_000, isInline: false),
            AttachmentInfo(id: "c", filename: "terrace.jpg", mimeType: "image/jpeg", sizeBytes: 3_100_000, isInline: false),
            AttachmentInfo(id: "d", filename: "assets.zip", mimeType: "application/zip", sizeBytes: 48_000_000, isInline: false),
        ]
        for (mode, name) in modes {
            let images = infos.map { AttachmentDragCard.content(for: $0) }.map { content in
                (AttachmentDragCard.bitmap(content, size: AttachmentDragCard.imageSize(for: content), mode: mode, scale: 2), content)
            }
            let width = images.map { AttachmentDragCard.imageSize(for: $0.1).width }.max() ?? 0
            let height = images.map { AttachmentDragCard.imageSize(for: $0.1).height }.reduce(0, +)
            let board = try compose(size: NSSize(width: width + 32, height: height + 16), background: .qCanvas, mode: mode) {
                var y: CGFloat = 8
                for (rep, content) in images {
                    let size = AttachmentDragCard.imageSize(for: content)
                    rep?.draw(in: NSRect(x: 16, y: y, width: size.width, height: size.height), from: .zero, operation: .sourceOver,
                              fraction: 1, respectFlipped: true, hints: nil)
                    y += size.height
                }
            }
            try write(board, "drag-card-\(name)@2x.png")
        }
    }

    /// The composer while an attachment hovers over it: the dashed `focus` outline inset in the body, “Drop to attach”.
    func testTheComposerDropTarget() throws {
        let client = try MainWindowHarness.scratchClient(in: folder)
        let account = ListTestSupport.accountA
        let composer = ComposeWindowController.present(client: client, account: account, accounts: [account], mode: .new)
        let window = try XCTUnwrap(composer.window)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        let content = try XCTUnwrap(window.contentView as? ComposeContentView)
        for (mode, name) in modes {
            window.appearance = mode.appearance
            content.showsDropOutline = true
            window.layoutIfNeeded()
            let rep = try render(content, mode: mode)
            content.showsDropOutline = false
            try write(rep, "composer-drop-\(name)@2x.png")
        }
        composer.closeWithoutSaving()
    }

    /// The quick reply while an attachment hovers over it, at rest and focused: the field's edge becomes the dashed outline
    /// and “Drop to reply with attachment” takes its place.
    func testTheQuickReplyDropTarget() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        let id = try XCTUnwrap(harness.list.conversations.first?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { !harness.reader.currentMessages.isEmpty }
        let bar = harness.reader.quickReplyBar
        for (mode, name) in modes {
            window.appearance = mode.appearance
            var reps: [NSBitmapImageRep] = []
            for focused in [false, true] {
                if focused { bar.focus() } else { window.makeFirstResponder(nil) }
                // The bar grows to its tool row with motion; drawn once it has.
                Quire.Motion.finishAll()
                ListTestSupport.spin(until: { false }, timeout: 0.8)
                XCTAssertEqual(bar.isFocused, focused)
                window.layoutIfNeeded()
                bar.layoutSubtreeIfNeeded()
                reps.append(try render(bar, mode: mode))
                bar.showsDropTarget = true
                bar.display()
                reps.append(try render(bar, mode: mode))
                bar.showsDropTarget = false
            }
            try write(try stack(reps), "quick-reply-drop-\(name)@2x.png")
        }
    }

    /// The drop treatment with the real card under the pointer, composited where the drag holds it: the quick reply with
    /// the pointer at the middle, a quarter and four fifths of its field, and a reply composer whose body holds seven
    /// paragraphs, the pointer at its middle. The words stay clear of the card, and the body's text never runs through them.
    func testTheDropWordsKeepClearOfTheCard() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        let id = try XCTUnwrap(harness.list.conversations.first?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { !harness.reader.currentMessages.isEmpty }
        let reader = harness.reader
        let webView = try XCTUnwrap(reader.pool.current?.webView as? ReaderWebView)
        let plan = AttachmentInfo(id: "att-plan", filename: "Contoso rollout plan.pdf", mimeType: "application/pdf", sizeBytes: 240_000, isInline: false)
        let message = MessageID(accountID: id.accountID, providerID: "msg-render")
        let drags = reader.attachmentDrags
        drags.attachments = { _ in [plan] }
        drags.beginSession = { _, _, _, _ in true }
        // Pressed on the name, 60 pt into the chip, as a person takes it.
        let pointer = NSPoint(x: 80, y: 320)
        let press = ConversationScriptMessage.AttachmentPress(
            messageID: message, items: [.init(attachmentID: plan.id, rect: CGRect(x: 20, y: 300, width: 220, height: 44))], point: pointer)
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: webView.convert(pointer, to: nil), modifierFlags: [],
                                                     timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                     context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        XCTAssertTrue(drags.startDrag(press, event: event, in: webView))
        defer { drags.dragEnded() }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("AttachmentDragRenderTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([AttachmentFilePromise(reference: MailAttachmentReference(message: message, info: plan),
                                                       fulfiller: AttachmentPromiseFulfiller(fetch: { _, _ in Data() }))])
        let drag = FakeDraggingInfo(pasteboard: pasteboard, source: drags, mask: .copy)
        let content = AttachmentDragCard.content(for: plan)
        let margin = AttachmentDragCard.margin

        let bar = reader.quickReplyBar
        let paragraphs = (1...7).map { "Paragraph \($0): here is a long line about the rollout plan and the support rota that wraps across the body's width." }
        let draft = ComposeDraft(id: UUID(), mode: .new, account: harness.controller.accounts[0], to: [EmailAddress(name: "Ada Ritchie", address: "ada@example.com")],
                                 cc: [], bcc: [], subject: "Re: Project update 2 and the quarterly planning document",
                                 body: NSAttributedString(string: paragraphs.joined(separator: "\n\n")), attachments: [], quoted: nil, threading: nil)
        let composer = ComposeWindowController.present(client: harness.environment.engine, accounts: harness.controller.accounts, draft: draft)
        defer { composer.closeWithoutSaving() }
        let composerWindow = try XCTUnwrap(composer.window)
        composerWindow.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        let body = try XCTUnwrap(composerWindow.contentView as? ComposeContentView)

        for (mode, name) in modes {
            window.appearance = mode.appearance
            composerWindow.appearance = mode.appearance
            window.makeFirstResponder(nil)
            Quire.Motion.finishAll()
            ListTestSupport.spin(until: { false }, timeout: 0.6)
            window.layoutIfNeeded()
            let card = AttachmentDragCard.bitmap(content, size: AttachmentDragCard.imageSize(for: content), mode: mode, scale: 2)
            let cardSize = AttachmentDragCard.imageSize(for: content)
            var reps: [NSBitmapImageRep] = []
            for fraction in [0.5, 0.25, 0.8] {
                let field = bar.dropTreatment.frame
                drag.draggingLocation = bar.convert(NSPoint(x: field.minX + field.width * fraction, y: field.midY), to: nil)
                XCTAssertEqual(bar.draggingEntered(drag), .copy)
                bar.display()
                let obstruction = try XCTUnwrap(bar.dropTreatment.obstruction)
                XCTAssertFalse(bar.dropTreatment.placedLabel.frame.intersects(obstruction), "\(fraction)")
                let rep = try render(bar, mode: mode)
                let origin = bar.convert(NSPoint(x: obstruction.minX - margin.left, y: obstruction.minY - margin.top), from: bar.dropTreatment)
                reps.append(try compose(size: rep.size, background: .clear, mode: mode) {
                    rep.draw(in: NSRect(origin: .zero, size: rep.size), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
                    card?.draw(in: NSRect(origin: origin, size: cardSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                })
                bar.draggingExited(drag)
            }
            try write(try stack(reps), "quick-reply-drop-card-\(name)@2x.png")

            composerWindow.layoutIfNeeded()
            let overlay = body.dropOverlay
            drag.draggingLocation = body.convert(NSPoint(x: overlay.frame.midX, y: overlay.frame.midY), to: nil)
            XCTAssertEqual(body.draggingEntered(drag), .copy)
            body.display()
            let obstruction = try XCTUnwrap(overlay.obstruction)
            XCTAssertFalse(overlay.placedLabel.frame.intersects(obstruction))
            let rep = try render(body, mode: mode)
            let origin = body.convert(NSPoint(x: obstruction.minX - margin.left, y: obstruction.minY - margin.top), from: overlay)
            let composite = try compose(size: rep.size, background: .clear, mode: mode) {
                rep.draw(in: NSRect(origin: .zero, size: rep.size), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
                card?.draw(in: NSRect(origin: origin, size: cardSize), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
            body.draggingExited(drag)
            try write(composite, "composer-drop-text-\(name)@2x.png")
        }
    }

    /// A reader whose first chip is being dragged: the chip left behind dims, its neighbour stays.
    func testTheDraggedChipInTheReader() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let window = try XCTUnwrap(harness.controller.window)
        window.setContentSize(NSSize(width: 1280, height: 800))
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        let html = "<p>The plan and the notes are attached.</p>"
        let plan = AttachmentInfo(id: "att-plan", filename: "Contoso rollout plan.pdf", mimeType: "application/pdf", sizeBytes: 240_000, isInline: false)
        let notes = AttachmentInfo(id: "att-notes", filename: "notes.txt", mimeType: "text/plain", sizeBytes: 1_300, isInline: false)
        for part in 0..<3 {
            try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: html, text: nil, attachments: [plan, notes]),
                                                              renderedHTML: html, plainText: ""),
                                                   for: MessageID(accountID: id.accountID, providerID: "msg-2-\(part)"))
        }
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        let reader = harness.reader
        XCTAssertTrue(ListTestSupport.spin(until: {
            guard let slot = reader.pool.current else { return false }
            return slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == id
        }, timeout: 10))
        let webView = try XCTUnwrap(reader.pool.current?.webView)
        let last = MessageID(accountID: id.accountID, providerID: "msg-2-2")
        let key = ConversationShellAssets.jsStringLiteral(RenderPayload.messageKey(for: last))
        for (mode, name) in modes {
            window.appearance = mode.appearance
            ListTestSupport.spin(until: { false }, timeout: 0.4)
            _ = evaluate("window.ss.attachmentDrag(\(key), ['att-plan'], true); document.querySelector('.ss-atts').scrollIntoView({block: 'center'}); true", in: webView)
            let image = try snapshot(webView)
            _ = evaluate("window.ss.attachmentDrag(\(key), ['att-plan'], false); true", in: webView)
            try write(image, "reader-dragging-chip-\(name)@2x.png")
        }
    }

    // MARK: Helpers

    private func render(_ view: NSView, mode: QuireMode) throws -> NSBitmapImageRep {
        let size = view.bounds.size
        let device = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let rep = device.retagging(with: .sRGB) ?? device
        rep.size = size
        mode.performAsCurrent { view.cacheDisplay(in: view.bounds, to: rep) }
        return rep
    }

    private func compose(size: NSSize, background: NSColor, mode: QuireMode, draw: () -> Void) throws -> NSBitmapImageRep {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let cg = try XCTUnwrap(CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cg.scaleBy(x: 2, y: 2)
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        mode.performAsCurrent {
            background.setFill()
            NSRect(origin: .zero, size: size).fill()
            draw()
        }
        NSGraphicsContext.restoreGraphicsState()
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(cg.makeImage()))
        rep.size = size
        return rep
    }

    private func stack(_ reps: [NSBitmapImageRep]) throws -> NSBitmapImageRep {
        let width = reps.map { CGFloat($0.pixelsWide) / 2 }.max() ?? 0
        let height = reps.map { CGFloat($0.pixelsHigh) / 2 }.reduce(0, +)
        return try compose(size: NSSize(width: width, height: height), background: .gray, mode: .light) {
            var y: CGFloat = 0
            for rep in reps {
                let size = NSSize(width: CGFloat(rep.pixelsWide) / 2, height: CGFloat(rep.pixelsHigh) / 2)
                rep.draw(in: NSRect(origin: NSPoint(x: 0, y: y), size: size), from: .zero, operation: .copy, fraction: 1,
                         respectFlipped: true, hints: nil)
                y += size.height
            }
        }
    }

    private func snapshot(_ webView: WKWebView) throws -> NSBitmapImageRep {
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = NSNumber(value: Double(webView.bounds.width))
        var image: NSImage?
        var done = false
        webView.takeSnapshot(with: configuration) { snapshot, _ in
            image = snapshot
            done = true
        }
        ListTestSupport.spin(until: { done }, timeout: 5)
        let picture = try XCTUnwrap(image)
        let size = picture.size
        return try compose(size: size, background: .clear, mode: .light) {
            picture.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func write(_ rep: NSBitmapImageRep, _ name: String) throws {
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        let url = renderDirectory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: renderDirectory, withIntermediateDirectories: true)
        try data.write(to: url)
        print("wrote \(url.path)")
    }

    private func evaluate(_ script: String, in webView: WKWebView) -> Any? {
        var result: Any?
        var done = false
        webView.evaluateJavaScript(script) { value, error in
            result = error == nil ? value : nil
            done = true
        }
        ListTestSupport.spin(until: { done }, timeout: 5)
        return result
    }
}
