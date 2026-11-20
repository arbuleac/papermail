import AppKit
import SSCore
import SSDesign
import UniformTypeIdentifiers
import WebKit
import XCTest
@testable import SuperSparrowApp

/// Dragging attachments out of a reader (spec §5.17, Dragging out) and dropping them on a composer or the quick reply
/// (§5.18, §5.20): what the pasteboard carries, how a promise is kept (the bytes, the name, the quarantine, a fetch that
/// fails), the shell's press message, the gesture in a real reader page, the drop targets and the drag card. Files go to
/// folders of the test's own; the engine runs over a throwaway store and a provider that serves files from memory, so
/// nothing reaches the network, the Keychain or the user's mail.
@MainActor
final class AttachmentDragTests: XCTestCase {
    private var folder: URL!
    private var drops: URL!

    nonisolated static let plan = AttachmentInfo(id: "att-plan", filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 4_000, isInline: false)
    nonisolated static let notes = AttachmentInfo(id: "att-notes", filename: "notes.txt", mimeType: "text/plain", sizeBytes: 13, isInline: false)
    nonisolated static let planBytes = Data(repeating: 7, count: 4_000)
    nonisolated static let notesBytes = Data("Notes, line 1".utf8)
    nonisolated static let message = MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-plan")

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentDragTests-\(UUID().uuidString)")
        drops = folder.appendingPathComponent("Drops", isDirectory: true)
        try FileManager.default.createDirectory(at: drops, withIntermediateDirectories: true)
        MainActor.assumeIsolated { ComposeDraftStore.shared.useDirectory(folder.appendingPathComponent("drafts", isDirectory: true)) }
    }

    override func tearDownWithError() throws {
        MainActor.assumeIsolated {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: drops.path)
        try? FileManager.default.removeItem(at: folder)
    }

    private func reference(_ info: AttachmentInfo = AttachmentDragTests.plan) -> MailAttachmentReference {
        MailAttachmentReference(message: Self.message, info: info)
    }

    private func board() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("AttachmentDragTests-\(UUID().uuidString)"))
    }

    // MARK: The pasteboard

    /// Each dragged file is a promise the Finder reads, of the file's own type and under its name, and carries the app's
    /// reference, which reads back as it was written.
    func testThePromiseCarriesTheFileTypeTheNameAndTheReference() throws {
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        let fulfiller = AttachmentPromiseFulfiller(fetch: { _, _ in Data() })
        let plan = AttachmentFilePromise(reference: reference(), fulfiller: fulfiller)
        let notes = AttachmentFilePromise(reference: reference(Self.notes), fulfiller: fulfiller)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([plan, notes]))

        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        XCTAssertTrue(types.isSuperset(of: NSFilePromiseReceiver.readableDraggedTypes), "a promise the Finder and other apps take")
        XCTAssertTrue(types.contains(AttachmentPasteboard.referenceType.rawValue), "and the app's own reference")
        XCTAssertFalse(types.contains(NSPasteboard.PasteboardType.fileURL.rawValue), "no file exists yet")
        XCTAssertEqual(pasteboard.pasteboardItems?.count, 2, "one item per file")
        XCTAssertEqual(plan.fileType, UTType.pdf.identifier)
        XCTAssertEqual(notes.fileType, UTType.plainText.identifier)
        XCTAssertEqual(plan.filePromiseProvider(plan, fileNameForType: plan.fileType), "plan.pdf")

        XCTAssertEqual(AttachmentPasteboard.references(on: pasteboard), [reference(), reference(Self.notes)], "a round trip, in order")
        XCTAssertEqual(AttachmentPasteboard.dropItems(on: pasteboard), [.mail(reference()), .mail(reference(Self.notes))])
        XCTAssertTrue(AttachmentPasteboard.carriesReference(pasteboard))
        XCTAssertEqual(NSFilePromiseReceiver.readableDraggedTypes.count, 3)
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver]
        XCTAssertEqual(receivers?.flatMap(\.fileTypes), [UTType.pdf.identifier, UTType.plainText.identifier], "what a receiver sees")
    }

    /// A name with a path in it promises the file under a name the file system takes.
    func testThePromisedNameIsMadeSafe() {
        let info = AttachmentInfo(id: "x", filename: "Q3/plan:v2.pdf", mimeType: "application/pdf", sizeBytes: 1, isInline: false)
        let promise = AttachmentFilePromise(reference: reference(info), fulfiller: AttachmentPromiseFulfiller(fetch: { _, _ in Data() }))
        XCTAssertEqual(promise.filePromiseProvider(promise, fileNameForType: promise.fileType), "Q3_plan_v2.pdf")
    }

    func testTheFileTypeComesFromTheMIMETypeOrTheName() {
        XCTAssertEqual(AttachmentFilePromise.fileType(filename: "plan.pdf", mimeType: "application/pdf"), .pdf)
        XCTAssertEqual(AttachmentFilePromise.fileType(filename: "photo", mimeType: "image/png"), .png, "no extension: the MIME type")
        XCTAssertEqual(AttachmentFilePromise.fileType(filename: "scan.jpg", mimeType: "application/octet-stream"), .jpeg,
                       "a generic MIME type: the name")
        XCTAssertEqual(AttachmentFilePromise.fileType(filename: "a.zip", mimeType: "application/zip"), .zip)
        XCTAssertEqual(AttachmentFilePromise.fileType(filename: "", mimeType: ""), .data, "nothing to go on: data")
        let odd = AttachmentFilePromise.fileType(filename: "x.qqqweird", mimeType: "application/octet-stream")
        XCTAssertTrue(odd.conforms(to: .data), "a promise is always data, or AppKit throws")
    }

    func testSafeFileNames() {
        XCTAssertEqual(AttachmentSafety.safeFilename("a/b:c.pdf"), "a_b_c.pdf")
        XCTAssertEqual(AttachmentSafety.safeFilename("  plan.pdf \n"), "plan.pdf")
        XCTAssertEqual(AttachmentSafety.safeFilename("in\u{0}voice\u{7}.pdf"), "invoice.pdf", "control characters go")
        XCTAssertEqual(AttachmentSafety.safeFilename(""), "Attachment")
        XCTAssertEqual(AttachmentSafety.safeFilename(".."), "Attachment")
        let long = String(repeating: "é", count: 200) + ".pdf"
        let cut = AttachmentSafety.safeFilename(long)
        XCTAssertLessThanOrEqual(cut.utf8.count, 255)
        XCTAssertTrue(cut.hasSuffix(".pdf"), "cut before the extension")
        XCTAssertEqual(AttachmentSafety.numberedName("plan.pdf", 2), "plan 2.pdf")
        XCTAssertEqual(AttachmentSafety.numberedName("README", 3), "README 3")
    }

    /// Only files and the app's own attachments attach; text is no attachment.
    func testOnlyFilesAndTheAppsAttachmentsDrop() throws {
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("hello", forType: .string)
        XCTAssertEqual(AttachmentPasteboard.dropItems(on: pasteboard), [])
        XCTAssertFalse(AttachmentPasteboard.carriesAttachments(pasteboard))
        let file = folder.appendingPathComponent("brief.txt")
        try Data("brief".utf8).write(to: file)
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        XCTAssertEqual(AttachmentPasteboard.dropItems(on: pasteboard), [.file(file)])
        XCTAssertTrue(AttachmentPasteboard.carriesAttachments(pasteboard))
        XCTAssertFalse(AttachmentPasteboard.carriesReference(pasteboard))
    }

    // MARK: Keeping a promise

    /// The Finder's URL gets the bytes, fetched off the main thread, quarantined, and nothing else is left in the folder.
    func testAPromiseWritesTheBytesQuarantinedUnderItsName() async throws {
        let threads = ThreadLog()
        let events = EventLog()
        let fulfiller = AttachmentPromiseFulfiller(fetch: { _, progress in
            threads.record(pthread_main_np() != 0)
            progress(0.5)
            return AttachmentDragTests.planBytes
        }, events: { events.append($0) })
        let written = try await Task.detached { try await fulfiller.fulfil(MailAttachmentReference(message: AttachmentDragTests.message,
                                                                                                    info: AttachmentDragTests.plan),
                                                                            at: self.dropsURL.appendingPathComponent("plan.pdf")) }.value
        XCTAssertEqual(written.lastPathComponent, "plan.pdf")
        XCTAssertEqual(try Data(contentsOf: written), Self.planBytes)
        XCTAssertTrue(AttachmentSafety.isQuarantined(URL(fileURLWithPath: written.path)), "marked as every attachment file is")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: drops.path), ["plan.pdf"], "no partial file left")
        XCTAssertEqual(threads.values, [false], "fetched off the main thread")
        XCTAssertEqual(events.kinds, ["began", "progress 0.5", "ended"])
    }

    /// A file of that name is there already: the promise never replaces it, and takes the Finder's next name.
    func testAPromiseNeverReplacesAFileThere() async throws {
        let existing = drops.appendingPathComponent("plan.pdf")
        try Data("mine".utf8).write(to: existing)
        let fulfiller = AttachmentPromiseFulfiller(fetch: { _, _ in AttachmentDragTests.planBytes })
        let written = try await fulfiller.fulfil(reference(), at: existing)
        XCTAssertEqual(written.lastPathComponent, "plan 2.pdf")
        XCTAssertEqual(try Data(contentsOf: existing), Data("mine".utf8), "the user's file is untouched")
        XCTAssertEqual(try Data(contentsOf: written), Self.planBytes)
    }

    /// Offline, or a file the server no longer has: the promise fails cleanly, says why, and leaves nothing behind.
    func testAFetchThatFailsKeepsNoPromiseAndSaysWhy() async throws {
        let events = EventLog()
        let fulfiller = AttachmentPromiseFulfiller(fetch: { _, _ in throw URLError(.notConnectedToInternet) }, events: { events.append($0) })
        do {
            try await fulfiller.fulfil(reference(), at: drops.appendingPathComponent("plan.pdf"))
            XCTFail("an unfetched file is no promise kept")
        } catch let failure as AttachmentDragFailure {
            XCTAssertEqual(failure, .unfetched)
        }
        XCTAssertEqual(events.kinds, ["began", "ended unfetched"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: drops.path), [])
    }

    /// A copy that cannot be quarantined (a volume that keeps no extended attributes) is never left, as a save does.
    func testAFileThatCannotBeMarkedIsNotLeft() async throws {
        struct Refused: Error {}
        var fulfiller = AttachmentPromiseFulfiller(fetch: { _, _ in AttachmentDragTests.planBytes })
        fulfiller.mark = { _ in throw Refused() }
        do {
            try await fulfiller.fulfil(reference(), at: drops.appendingPathComponent("plan.pdf"))
            XCTFail("an unmarked file is no file")
        } catch let failure as AttachmentDragFailure {
            XCTAssertEqual(failure, .unwritten)
        }
        fulfiller.mark = { _ in }
        await XCTAssertThrowsAsync(try await fulfiller.fulfil(self.reference(), at: self.drops.appendingPathComponent("plan.pdf")),
                                   "a mark that does not stick is no mark")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: drops.path), [])
    }

    /// A folder that cannot be written: the drop fails as unwritten.
    func testAFolderThatCannotBeWrittenKeepsNoPromise() async throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: drops.path)
        let fulfiller = AttachmentPromiseFulfiller(fetch: { _, _ in AttachmentDragTests.planBytes })
        do {
            try await fulfiller.fulfil(reference(), at: drops.appendingPathComponent("plan.pdf"))
            XCTFail("nothing can be written there")
        } catch let failure as AttachmentDragFailure {
            XCTAssertEqual(failure, .unwritten)
        }
    }

    /// Through the engine: the first drop downloads the file, a second takes it from this Mac's cache without asking the
    /// provider again; offline, the provider's failure fails the promise.
    func testTheEngineFetchesOnceAndThenServesTheCachedFile() async throws {
        let provider = CountingAttachmentProvider(accountID: Self.message.accountID, files: [Self.plan.id: Self.planBytes])
        let engine = try makeEngine(provider)
        let fulfiller = AttachmentPromiseFulfiller.engine(engine) { _ in }
        let first = try await fulfiller.fulfil(reference(), at: drops.appendingPathComponent("plan.pdf"))
        XCTAssertEqual(try Data(contentsOf: first), Self.planBytes)
        XCTAssertEqual(provider.calls, 1, "fetched")
        let second = try await fulfiller.fulfil(reference(), at: drops.appendingPathComponent("plan.pdf"))
        XCTAssertEqual(second.lastPathComponent, "plan 2.pdf")
        XCTAssertEqual(try Data(contentsOf: second), Self.planBytes)
        XCTAssertEqual(provider.calls, 1, "cached: the provider is not asked again")

        provider.offline = true
        do {
            try await fulfiller.fulfil(reference(Self.notes), at: drops.appendingPathComponent("notes.txt"))
            XCTFail("offline, a file this Mac lacks cannot be kept")
        } catch let failure as AttachmentDragFailure {
            XCTAssertEqual(failure, .unfetched)
        }
    }

    /// The promise as AppKit calls it, on the queue it asked for, which is never the main queue; the completion handler ends it.
    func testThePromiseIsKeptOnItsOwnQueue() throws {
        let promise = AttachmentFilePromise(reference: reference(), fulfiller: AttachmentPromiseFulfiller(fetch: { _, _ in AttachmentDragTests.planBytes }))
        let queue = promise.operationQueue(for: promise)
        XCTAssertFalse(queue === OperationQueue.main)
        let destination = drops.appendingPathComponent(promise.filePromiseProvider(promise, fileNameForType: promise.fileType))
        let finished = expectation(description: "the promise ends")
        let provider = UncheckedPromise(promise)
        queue.addOperation {
            provider.promise.filePromiseProvider(provider.promise, writePromiseTo: destination) { error in
                XCTAssertNil(error)
                finished.fulfill()
            }
        }
        wait(for: [finished], timeout: 5)
        XCTAssertEqual(try Data(contentsOf: destination), Self.planBytes)
    }

    /// The window's toast words for a drop that failed.
    func testTheToastSaysWhatFailed() {
        XCTAssertEqual(AttachmentDragFailure.unfetched.toast(filename: "plan.pdf"), "Couldn\u{2019}t download \u{201C}plan.pdf\u{201D}")
        XCTAssertEqual(AttachmentDragFailure.unwritten.toast(filename: "plan.pdf"), "Couldn\u{2019}t save \u{201C}plan.pdf\u{201D}")
        XCTAssertEqual(AttachmentDragFailure.unfetched.toast(filename: "plan.pdf", fits: { _ in false }), "Couldn\u{2019}t download the attachment")
    }

    // MARK: The shell's press

    func testThePressMessageParsesTotally() {
        let key = RenderPayload.messageKey(for: Self.message)
        let item: [String: Any] = ["attachmentID": "att-plan", "x": 20, "y": 300.5, "width": 220, "height": 44]
        let parsed = ConversationScriptMessage(body: ["kind": "attachmentPress", "messageID": key, "items": [item], "x": 40, "y": 320])
        XCTAssertEqual(parsed, .attachmentPress(.init(messageID: Self.message,
                                                      items: [.init(attachmentID: "att-plan", rect: CGRect(x: 20, y: 300.5, width: 220, height: 44))],
                                                      point: CGPoint(x: 40, y: 320))))
        func press(_ changes: [String: Any], item itemChanges: [String: Any] = [:]) -> ConversationScriptMessage? {
            var body: [String: Any] = ["kind": "attachmentPress", "messageID": key, "x": 40, "y": 320]
            body["items"] = [item.merging(itemChanges) { $1 }]
            return ConversationScriptMessage(body: body.merging(changes) { $1 })
        }
        XCTAssertNotNil(press([:]))
        XCTAssertNil(press(["messageID": "nonsense"]), "a message the page cannot name")
        XCTAssertNil(press(["items": []]), "nothing pressed")
        XCTAssertNil(press(["items": "att-plan"]))
        XCTAssertNil(press(["x": "40"]), "a point is two numbers")
        XCTAssertNil(press(["y": Double.nan]))
        XCTAssertNil(press([:], item: ["attachmentID": ""]))
        XCTAssertNil(press([:], item: ["width": -1]), "a rect has a size")
        XCTAssertNil(press([:], item: ["height": Double.infinity]))
        XCTAssertNil(press(["items": Array(repeating: item, count: ConversationScriptMessage.AttachmentPress.maxItems + 1)]))
    }

    // MARK: The gesture in a reader

    /// A press on a chip drags only once the pointer moves past the threshold, and the drag starts in that event: one item,
    /// its card over the chip, its promise for the file. The chip dims while the drag lasts, and the click the press ends
    /// in opens nothing; a later click opens Quick Look as ever.
    func testDraggingAChipPastTheThresholdStartsItsDrag() throws {
        let fixture = try ReaderFixture(folder: folder)
        defer { fixture.close() }
        let reader = fixture.reader
        reader.attachmentPreview.presentsPanel = false
        var opened: [String] = []
        reader.onAction = { if case .openAttachment(_, let info) = $0 { opened.append(info.id) } }
        var started: [NSDraggingItem] = []
        reader.attachmentDrags.beginSession = { _, items, _, _ in
            started = items
            return true
        }
        let webView = fixture.webView
        let chip = try XCTUnwrap(rect(of: ".ss-chip[data-attachment-id=\"\(Self.plan.id)\"]", in: webView))
        let start = NSPoint(x: chip.midX, y: chip.midY)

        XCTAssertTrue(webView.bounds.contains(start), "the chip is on screen: \(chip) in \(webView.frame)")
        send(.leftMouseDown, at: start, to: webView)
        XCTAssertTrue(ListTestSupport.spin(until: { webView.isAttachmentDragArmed }, timeout: 5), "the shell names the pressed chip")
        send(.leftMouseDragged, at: NSPoint(x: start.x + 2, y: start.y), to: webView)
        XCTAssertTrue(started.isEmpty, "inside the threshold the press is still a click")
        let begin = Date()
        send(.leftMouseDragged, at: NSPoint(x: start.x + 6, y: start.y + 2), to: webView)
        XCTAssertLessThan(Date().timeIntervalSince(begin), 0.016, "the drag starts inside a frame of the event")
        XCTAssertEqual(started.count, 1)
        let item = try XCTUnwrap(started.first)
        XCTAssertEqual((item.item as? AttachmentFilePromise)?.reference, MailAttachmentReference(message: fixture.messageID, info: Self.plan))
        let margin = AttachmentDragCard.margin
        XCTAssertEqual(item.draggingFrame.minX, chip.minX - margin.left, accuracy: 0.5, "the card starts over its chip")
        XCTAssertEqual(item.draggingFrame.minY, chip.minY - margin.top, accuracy: 0.5)
        XCTAssertNotNil(reader.attachmentDrags.current)

        XCTAssertTrue(ListTestSupport.spin(until: { self.evaluate("document.querySelector('.ss-chip[data-attachment-id=\"\(Self.plan.id)\"]').parentNode.classList.contains('ss-dragging')", in: webView) as? Bool == true }, timeout: 5), "the chip dims")
        // The press's mouse-up, handed to WebKit as the drag started, opened nothing.
        ListTestSupport.spin(until: { false }, timeout: 0.3)
        XCTAssertEqual(opened, [], "no Quick Look under the drag")
        // Further moves are the session's, not WebKit's or another drag's.
        send(.leftMouseDragged, at: NSPoint(x: start.x + 30, y: start.y + 10), to: webView)
        XCTAssertEqual(started.count, 1)

        reader.attachmentDrags.dragEnded()
        XCTAssertTrue(ListTestSupport.spin(until: { self.evaluate("document.querySelectorAll('.ss-dragging').length", in: webView) as? Int == 0 }, timeout: 5),
                      "the chip comes back")
        _ = evaluate("document.querySelector('.ss-chip[data-attachment-id=\"\(Self.plan.id)\"]').click(); true", in: webView)
        XCTAssertTrue(ListTestSupport.spin(until: { opened == [Self.plan.id] }, timeout: 5), "a click opens Quick Look again")
    }

    /// Download all drags every file of its message, in the chips' order.
    func testDraggingDownloadAllDragsEveryFile() throws {
        let fixture = try ReaderFixture(folder: folder)
        defer { fixture.close() }
        var started: [NSDraggingItem] = []
        fixture.reader.attachmentDrags.beginSession = { _, items, _, _ in
            started = items
            return true
        }
        let webView = fixture.webView
        let link = try XCTUnwrap(rect(of: ".ss-dlall", in: webView))
        let start = NSPoint(x: link.midX, y: link.midY)
        send(.leftMouseDown, at: start, to: webView)
        XCTAssertTrue(ListTestSupport.spin(until: { webView.isAttachmentDragArmed }, timeout: 5))
        send(.leftMouseDragged, at: NSPoint(x: start.x + 8, y: start.y + 8), to: webView)
        XCTAssertEqual(started.compactMap { ($0.item as? AttachmentFilePromise)?.reference.info.id }, [Self.plan.id, Self.notes.id])
        fixture.reader.attachmentDrags.dragEnded()
    }

    /// The shell's word counts only for the press under way, at the point it names: a late word, or one for another place,
    /// never turns a drag of text into a drag of files.
    func testOnlyThePressUnderWayArms() throws {
        let fixture = try ReaderFixture(folder: folder)
        defer { fixture.close() }
        let webView = fixture.webView
        let chip = try XCTUnwrap(rect(of: ".ss-chip", in: webView))
        let press = ConversationScriptMessage.AttachmentPress(messageID: fixture.messageID,
                                                              items: [.init(attachmentID: Self.plan.id, rect: chip)],
                                                              point: CGPoint(x: chip.midX, y: chip.midY))
        webView.armAttachmentDrag(press)
        XCTAssertFalse(webView.isAttachmentDragArmed, "no press under way")
        // A press on the body's text: a late word about the chip does not arm it.
        let body = try XCTUnwrap(rect(of: ".ss-frame", in: webView) ?? rect(of: "iframe", in: webView))
        send(.leftMouseDown, at: NSPoint(x: body.midX, y: body.minY + 4), to: webView)
        webView.armAttachmentDrag(press)
        XCTAssertFalse(webView.isAttachmentDragArmed, "the press is elsewhere")
        send(.leftMouseUp, at: NSPoint(x: body.midX, y: body.minY + 4), to: webView)
    }

    /// The page takes no attachment of the app's own: dropping a chip back on the reader shows nothing and does nothing.
    func testTheReaderRefusesTheAppsOwnAttachments() throws {
        let fixture = try ReaderFixture(folder: folder)
        defer { fixture.close() }
        let drag = mailDrag([reference()])
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(fixture.webView.draggingEntered(drag), [])
        XCTAssertEqual(fixture.webView.draggingUpdated(drag), [])
        XCTAssertFalse(fixture.webView.performDragOperation(drag))
    }

    /// A drop the Finder asked for that could not be fetched marks the chip and tells the window, which shows the toast.
    /// Synchronous on purpose: the page answers on the main queue, which an async test's job would hold back.
    func testAPromiseThatCannotBeFetchedMarksTheChipAndSaysSo() throws {
        let fixture = try ReaderFixture(folder: folder, served: [Self.notes])
        defer { fixture.close() }
        var failures: [(AttachmentDragFailure, String)] = []
        fixture.reader.onAction = { if case let .attachmentDragFailed(failure, name) = $0 { failures.append((failure, name)) } }
        let fulfiller = fixture.reader.attachmentDrags.fulfiller
        let reference = MailAttachmentReference(message: fixture.messageID, info: Self.plan)
        let destination = drops.appendingPathComponent("plan.pdf")
        let outcome = ThreadLog()
        Task.detached {
            do {
                try await fulfiller.fulfil(reference, at: destination)
                outcome.record(true)
            } catch {
                outcome.record(false)
            }
        }
        ListTestSupport.spin(until: { !failures.isEmpty && !outcome.values.isEmpty }, timeout: 5)
        XCTAssertEqual(outcome.values, [false], "the promise fails")
        XCTAssertEqual(failures.first?.0, .unfetched)
        XCTAssertEqual(failures.first?.1, "plan.pdf")
        let failed = "document.querySelector('.ss-chip[data-attachment-id=\"\(Self.plan.id)\"]').classList.contains('ss-failed')"
        XCTAssertTrue(ListTestSupport.spin(until: { self.evaluate(failed, in: fixture.webView) as? Bool == true }, timeout: 5),
                      "Couldn't download · Retry on the chip")
    }

    func testTheMainWindowShowsTheDragFailureToast() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.controller.handle(.attachmentDragFailed(.unfetched, filename: "plan.pdf"))
        XCTAssertEqual(harness.toastMessage, "Couldn\u{2019}t download \u{201C}plan.pdf\u{201D}")
    }

    // MARK: The composer

    /// An attachment dragged from a message joins the strip at once as a loading chip, with the drop outline while it
    /// hovers, and turns ready with the file's bytes once the engine has them.
    func testTheComposerTakesAMailAttachmentAsALoadingChipThenReady() throws {
        let gate = DropGate()
        let provider = CountingAttachmentProvider(accountID: Self.message.accountID, files: [Self.plan.id: Self.planBytes], gate: gate)
        let composer = try makeComposer(provider)
        let content = try XCTUnwrap(composer.window?.contentView as? ComposeContentView)
        let drag = mailDrag([reference()])
        defer { drag.draggingPasteboard.releaseGlobally() }

        XCTAssertEqual(content.draggingEntered(drag), .copy)
        XCTAssertTrue(content.showsDropOutline, "Drop to attach")
        XCTAssertTrue(content.performDragOperation(drag))
        XCTAssertFalse(content.showsDropOutline)
        let chip = try XCTUnwrap(composer.contents.attachments.first)
        XCTAssertEqual(chip.filename, "plan.pdf")
        XCTAssertEqual(chip.state, .loading, "pending until its bytes are in")
        XCTAssertFalse(chip.isSendable)

        gate.open()
        XCTAssertTrue(ListTestSupport.spin(until: { composer.contents.attachments.first?.state == .ready }, timeout: 5))
        let ready = try XCTUnwrap(composer.contents.attachments.first)
        XCTAssertEqual(try ready.loadData(), Self.planBytes)
        XCTAssertEqual(ready.mimeType, "application/pdf")
        XCTAssertEqual(provider.calls, 1)
    }

    /// A file that cannot be fetched leaves the strip again, and the status line says which.
    func testAComposerDropThatCannotBeFetchedIsTakenAwayAndSaysWhy() throws {
        let provider = CountingAttachmentProvider(accountID: Self.message.accountID, files: [:])
        let composer = try makeComposer(provider)
        let content = try XCTUnwrap(composer.window?.contentView as? ComposeContentView)
        let drag = mailDrag([reference()])
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertTrue(content.performDragOperation(drag))
        XCTAssertTrue(ListTestSupport.spin(until: { composer.contents.attachments.isEmpty }, timeout: 5), "the chip goes")
        XCTAssertEqual(composer.status, .droppedAttachmentFailed(name: "plan.pdf"))
        XCTAssertEqual(composer.status?.text, "\u{201C}plan.pdf\u{201D} couldn't be downloaded, so it wasn't attached.")
    }

    /// Files dropped on the composer are ready at once, read at send as ever; text is no drop.
    func testTheComposerTakesFilesAndRefusesText() throws {
        let composer = try makeComposer(CountingAttachmentProvider(accountID: Self.message.accountID, files: [:]))
        let content = try XCTUnwrap(composer.window?.contentView as? ComposeContentView)
        let file = folder.appendingPathComponent("brief.txt")
        try Data("brief".utf8).write(to: file)
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        let drag = FakeDraggingInfo(pasteboard: pasteboard, source: nil, mask: .copy)
        XCTAssertEqual(content.draggingEntered(drag), .copy)
        XCTAssertTrue(content.performDragOperation(drag))
        XCTAssertEqual(composer.contents.attachments.map(\.filename), ["brief.txt"])
        XCTAssertEqual(composer.contents.attachments.first?.state, .ready)

        let text = board()
        defer { text.releaseGlobally() }
        text.clearContents()
        text.setString("hello", forType: .string)
        XCTAssertEqual(content.draggingEntered(FakeDraggingInfo(pasteboard: text, source: nil, mask: .copy)), [])
        XCTAssertFalse(content.showsDropOutline, "no highlight for what does not attach")
    }

    /// The chip menu's Copy puts the file the Finder pastes and the app's reference; pasted on a composer's text the
    /// reference wins, so the attachment is fetched through the engine like a dropped one, never read from the reader's
    /// session copy.
    func testCopyPastesIntoAComposerAsTheAttachment() throws {
        let provider = CountingAttachmentProvider(accountID: Self.message.accountID, files: [Self.plan.id: Self.planBytes])
        let composer = try makeComposer(provider)
        let file = folder.appendingPathComponent("plan.pdf")
        try Self.planBytes.write(to: file)
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([AttachmentPasteboard.copyItem(file: file, reference: reference())]))
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        XCTAssertEqual(urls, [file], "the Finder pastes the file")
        XCTAssertEqual(AttachmentPasteboard.references(on: pasteboard), [reference()])

        let editor = composer.bodyEditor
        editor.pasteboard = pasteboard
        composer.window?.makeFirstResponder(editor)
        editor.paste(nil)
        XCTAssertEqual(composer.contents.attachments.map(\.filename), ["plan.pdf"], "attached, nothing in the text")
        XCTAssertEqual(editor.string, "")
        XCTAssertTrue(ListTestSupport.spin(until: { composer.contents.attachments.first?.state == .ready }, timeout: 5))
        XCTAssertEqual(provider.calls, 1, "through the engine")
    }

    /// Send waits for a dropped attachment still arriving, and does not go once it could not be fetched.
    func testSendWaitsForADroppedAttachmentAndStopsWhenItFails() throws {
        let gate = DropGate()
        let provider = CountingAttachmentProvider(accountID: Self.message.accountID, files: [:], gate: gate)
        let account = ListTestSupport.accountA
        let draft = ComposeDraft(id: UUID(), mode: .new, account: account, to: [EmailAddress(name: "Ben Carter", address: "ben@example.com")],
                                 cc: [], bcc: [], subject: "The plan", body: NSAttributedString(string: "Attached."), attachments: [],
                                 quoted: nil, threading: nil)
        let composer = ComposeWindowController.present(client: try makeEngine(provider), accounts: [account], draft: draft)
        let content = try XCTUnwrap(composer.window?.contentView as? ComposeContentView)
        let drag = mailDrag([reference()])
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertTrue(content.performDragOperation(drag))
        composer.send(nil)
        XCTAssertTrue(composer.sendIsStarting, "the button shows it is sending while the file arrives")
        gate.open()
        XCTAssertTrue(ListTestSupport.spin(until: { !composer.sendIsStarting }, timeout: 5))
        XCTAssertNotNil(composer.window, "nothing sent: the composer stays")
        XCTAssertTrue(ComposeWindowRegistry.shared.openControllers.contains { $0 === composer })
        XCTAssertEqual(composer.status, .droppedAttachmentFailed(name: "plan.pdf"))
    }

    // MARK: The quick reply

    /// A drop on the quick reply moves the reply to a composer, its text and recipients as Open in Composer would give
    /// them, with the files attached; the bar is left empty and disabled, and then takes no drop.
    func testDroppingOnTheQuickReplyMovesTheReplyToAComposerWithTheFiles() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentMessages.count == 3 }
        let bar = harness.reader.quickReplyBar

        // What Open in Composer gives, to compare.
        bar.onOpenInComposer?("", .reply)
        let reference = try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.first)
        let recipients = reference.contents.to.map(\.address)
        reference.closeWithoutSaving()
        XCTAssertFalse(bar.isComposerOpen)

        bar.text = "See attached"
        let file = folder.appendingPathComponent("brief.txt")
        try Data("brief".utf8).write(to: file)
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        let drag = FakeDraggingInfo(pasteboard: pasteboard, source: nil, mask: .copy)
        XCTAssertEqual(bar.draggingEntered(drag), .copy)
        XCTAssertTrue(bar.showsDropTarget, "Drop to reply with attachment")
        XCTAssertTrue(bar.performDragOperation(drag))
        XCTAssertFalse(bar.showsDropTarget)

        let composer = try XCTUnwrap(ComposeWindowRegistry.shared.openControllers.first)
        XCTAssertEqual(composer.bodyText, "See attached", "the text moves with the reply")
        XCTAssertEqual(composer.contents.to.map(\.address), recipients, "the recipients are the reply's")
        XCTAssertEqual(composer.contents.attachments.map(\.filename), ["brief.txt"], "attached, as Attach and choosing it would")
        XCTAssertEqual(bar.text, "")
        XCTAssertTrue(bar.isComposerOpen)
        XCTAssertEqual(bar.draggingEntered(drag), [], "while the composer holds the reply the bar takes no drop")
        XCTAssertFalse(bar.showsDropTarget)
    }

    /// Files dragged over the bar's text are the bar's to take: the text view, registered for files, would type the path.
    func testTheQuickReplyTextHandsFilesToTheBar() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = try XCTUnwrap(harness.list.conversations.first?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { !harness.reader.currentMessages.isEmpty }
        let bar = harness.reader.quickReplyBar
        let textView = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? NSTextView }.first)
        let drag = mailDrag([reference()])
        defer { drag.draggingPasteboard.releaseGlobally() }
        XCTAssertEqual(textView.draggingEntered(drag), .copy)
        XCTAssertTrue(bar.showsDropTarget)
        textView.draggingExited(drag)
        XCTAssertFalse(bar.showsDropTarget)
    }

    // MARK: Elsewhere

    /// The list, the rail and the calendar never see a dragged attachment: none of them registers for anything it carries,
    /// so AppKit gives them no drag to light up for. The quick reply and the page are the only views of the main window
    /// that do, and the page refuses it.
    func testOnlyTheQuickReplyAndThePageSeeADraggedAttachment() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let id = try XCTUnwrap(harness.list.conversations.first?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { !harness.reader.currentMessages.isEmpty }
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([AttachmentFilePromise(reference: reference(), fulfiller: AttachmentPromiseFulfiller(fetch: { _, _ in Data() }))])
        let carried = Set(pasteboard.types ?? [])
        let root = try XCTUnwrap(harness.controller.window?.contentView)
        let takers = descendants(of: root).filter { !Set($0.registeredDraggedTypes).isDisjoint(with: carried) }
        XCTAssertFalse(takers.isEmpty)
        for view in takers {
            XCTAssertTrue(view is QuickReplyView || view is ReaderWebView, "\(type(of: view)) would see a dragged attachment")
        }
    }

    /// The drag starts in the event that crosses the threshold, inside the 16 ms of a frame (docs/ARCHITECTURE.md,
    /// "Performance budgets"): the store's list of files, a card drawn per file, a promise per file and the session asked
    /// for. One file, and Download all over twenty. `SS_PERF=1`.
    func testStartingADragStaysInsideAFrame() throws {
        guard ProcessInfo.processInfo.environment["SS_PERF"] == "1" else { throw XCTSkip("set SS_PERF=1 to time the drag's start") }
        let fixture = try ReaderFixture(folder: folder)
        defer { fixture.close() }
        let drags = fixture.reader.attachmentDrags
        drags.beginSession = { _, _, _, _ in true }
        let window = try XCTUnwrap(fixture.webView.window)
        for count in [1, 20] {
            let infos = (0..<count).map {
                AttachmentInfo(id: "f\($0)", filename: "Quarterly report for the board, part \($0).pdf", mimeType: "application/pdf",
                               sizeBytes: 240_000 + $0, isInline: false)
            }
            drags.attachments = { _ in infos }
            let press = ConversationScriptMessage.AttachmentPress(
                messageID: fixture.messageID,
                items: infos.enumerated().map { .init(attachmentID: $1.id, rect: CGRect(x: 20 + CGFloat($0 % 3) * 220, y: 300, width: 210, height: 44)) },
                point: CGPoint(x: 40, y: 320))
            var samples: [Double] = []
            for _ in 0..<40 {
                let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: NSPoint(x: 60, y: 300), modifierFlags: [],
                                                             timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                             context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
                let start = DispatchTime.now().uptimeNanoseconds
                XCTAssertTrue(drags.startDrag(press, event: event, in: fixture.webView))
                samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
                drags.dragEnded()
            }
            let sorted = samples.dropFirst(5).sorted()
            let median = sorted[sorted.count / 2]
            let p95 = sorted[Int(Double(sorted.count - 1) * 0.95)]
            print(String(format: "drag start, %d file(s): median %.2f ms, p95 %.2f ms", count, median, p95))
            XCTAssertLessThan(p95, 16, "\(count) file(s)")
        }
    }

    // MARK: The card

    func testTheCardIsSizedByItsWordsBetweenTheChipsWidths() {
        let m = Quire.Layout.DragCard.self
        let short = AttachmentDragCard.content(for: Self.notes)
        XCTAssertEqual(short.meta, "Text · 13 B")
        XCTAssertEqual(AttachmentDragCard.cardSize(for: short), NSSize(width: m.minWidth, height: m.height))
        let longInfo = AttachmentInfo(id: "l", filename: String(repeating: "Quarterly report ", count: 6) + ".pdf",
                                      mimeType: "application/pdf", sizeBytes: 2_400_000, isInline: false)
        let long = AttachmentDragCard.content(for: longInfo)
        XCTAssertEqual(long.meta, "PDF · 2.4 MB")
        XCTAssertEqual(AttachmentDragCard.cardSize(for: long).width, m.maxWidth)
        let image = AttachmentDragCard.imageSize(for: long)
        XCTAssertEqual(image.width, m.maxWidth + 2 * m.shadowMarginX)
        XCTAssertEqual(image.height, m.height + m.shadowMarginTop + m.shadowMarginBottom)
    }

    /// The card at 1x and 2x, in Light and Dark: its pixels, `sheet` inside, clear far outside, its shadow below.
    func testTheCardDrawsAtOneAndTwoTimesInLightAndDark() throws {
        let content = AttachmentDragCard.content(for: Self.plan)
        let size = AttachmentDragCard.imageSize(for: content)
        let card = AttachmentDragCard.cardSize(for: content)
        let margin = AttachmentDragCard.margin
        for mode in [QuireMode.light, .dark] {
            let sheet = mode.performAsCurrent { NSColor.qSheet.usingColorSpace(.sRGB) }
            for scale in [CGFloat(1), 2] {
                let rep = try XCTUnwrap(AttachmentDragCard.bitmap(content, size: size, mode: mode, scale: scale))
                XCTAssertEqual(rep.pixelsWide, Int((size.width * scale).rounded(.up)))
                XCTAssertEqual(rep.pixelsHigh, Int((size.height * scale).rounded(.up)))
                // In the trailing pad, at mid-height: the card's surface.
                let inside = try XCTUnwrap(pixel(rep, NSPoint(x: margin.left + card.width - 6, y: margin.top + card.height / 2), scale: scale))
                XCTAssertEqual(inside.redComponent, try XCTUnwrap(sheet).redComponent, accuracy: 0.02, "\(mode) \(scale)x: sheet")
                XCTAssertEqual(inside.alphaComponent, 1, accuracy: 0.01)
                // The image's corner: nothing.
                XCTAssertEqual(try XCTUnwrap(pixel(rep, NSPoint(x: 1, y: 1), scale: scale)).alphaComponent, 0, accuracy: 0.01)
                // Under the card's middle: the e2 shadow.
                let below = try XCTUnwrap(pixel(rep, NSPoint(x: margin.left + card.width / 2, y: margin.top + card.height + 4), scale: scale))
                XCTAssertGreaterThan(below.alphaComponent, 0.02, "\(mode) \(scale)x: the shadow falls below")
            }
        }
    }

    /// The shadow is blurred once and stretched under each card: under the widest card it matches `e2` blurred whole,
    /// along the ends, the corners and the middle, in both modes.
    func testTheStretchedShadowMatchesOneBlurredWhole() throws {
        let info = AttachmentInfo(id: "w", filename: String(repeating: "Quarterly report ", count: 6) + ".pdf", mimeType: "application/pdf",
                                  sizeBytes: 1, isInline: false)
        let content = AttachmentDragCard.content(for: info)
        let size = AttachmentDragCard.imageSize(for: content)
        let card = NSRect(origin: NSPoint(x: AttachmentDragCard.margin.left, y: AttachmentDragCard.margin.top),
                          size: AttachmentDragCard.cardSize(for: content))
        for mode in [QuireMode.light, .dark] {
            let drawn = try XCTUnwrap(AttachmentDragCard.bitmap(content, size: size, mode: mode, scale: 2))
            let whole = try XCTUnwrap(referenceShadow(card: card, size: size, mode: mode))
            for y in [card.maxY + 2, card.maxY + 8, card.maxY + 16, card.minY - 4] {
                for x in [card.minX - 10, card.minX + 4, card.minX + 60, card.midX, card.maxX - 60, card.maxX - 4, card.maxX + 10] {
                    let a = try XCTUnwrap(pixel(drawn, NSPoint(x: x, y: y), scale: 2)).alphaComponent
                    let b = try XCTUnwrap(pixel(whole, NSPoint(x: x, y: y), scale: 2)).alphaComponent
                    XCTAssertEqual(a, b, accuracy: 0.02, "\(mode) at (\(x), \(y))")
                }
            }
        }
    }

    /// `e2` under `card`, blurred whole, as a reference.
    private func referenceShadow(card: NSRect, size: NSSize, mode: QuireMode) throws -> NSBitmapImageRep? {
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let cg = try XCTUnwrap(CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cg.scaleBy(x: 2, y: 2)
        cg.translateBy(x: 0, y: size.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        mode.performAsCurrent {
            NSGraphicsContext.saveGraphicsState()
            for layer in Quire.Elevation.e2.layers(for: mode) {
                let shadow = NSShadow()
                shadow.shadowColor = layer.color
                shadow.shadowBlurRadius = layer.blur
                shadow.shadowOffset = NSSize(width: layer.x, height: -layer.y)
                shadow.set()
                QuireDraw.fill(card, radius: Quire.Layout.DragCard.radius, .qSheet)
            }
            NSGraphicsContext.restoreGraphicsState()
            QuireDraw.fill(card, radius: Quire.Layout.DragCard.radius, .qSheet)
        }
        NSGraphicsContext.restoreGraphicsState()
        return cg.makeImage().map(NSBitmapImageRep.init(cgImage:))
    }

    // MARK: Helpers

    private var dropsURL: URL { drops }

    private func mailDrag(_ references: [MailAttachmentReference]) -> FakeDraggingInfo {
        let pasteboard = board()
        pasteboard.clearContents()
        let fulfiller = AttachmentPromiseFulfiller(fetch: { _, _ in Data() })
        pasteboard.writeObjects(references.map { AttachmentFilePromise(reference: $0, fulfiller: fulfiller) })
        return FakeDraggingInfo(pasteboard: pasteboard, source: nil, mask: .copy)
    }

    private func makeEngine(_ provider: CountingAttachmentProvider) throws -> MailEngine {
        let store = InMemoryMailStore()
        try store.upsertAccount(ListTestSupport.accountA)
        return MailEngine(store: store, tokenStore: InMemoryTokenStore(), tokenProvider: DemoTokenProvider(),
                          authenticator: DemoAuthenticator(), sanitizer: HTMLSanitizer(), providerFactory: { _ in provider },
                          attachmentCacheDirectory: folder.appendingPathComponent("attachments-\(UUID().uuidString)", isDirectory: true))
    }

    private func makeComposer(_ provider: CountingAttachmentProvider) throws -> ComposeWindowController {
        let engine = try makeEngine(provider)
        let account = ListTestSupport.accountA
        return ComposeWindowController.present(client: engine, account: account, accounts: [account], mode: .new)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    /// The element's box in the web view's coordinates (the page's, at magnification 1).
    private func rect(of selector: String, in webView: WKWebView) -> NSRect? {
        let script = "(function () { var n = document.querySelector('\(selector.replacingOccurrences(of: "'", with: "\\'"))'); if (!n) { return null; } var r = n.getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; })()"
        guard let box = evaluate(script, in: webView) as? [NSNumber], box.count == 4 else { return nil }
        return NSRect(x: box[0].doubleValue, y: box[1].doubleValue, width: box[2].doubleValue, height: box[3].doubleValue)
    }

    /// Hands `webView` a mouse event at `point` (its own coordinates), as the window would.
    private func send(_ type: NSEvent.EventType, at point: NSPoint, to webView: ReaderWebView) {
        guard let window = webView.window else { return XCTFail("the reader is in a window") }
        let location = webView.convert(point, to: nil)
        guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                             pressure: type == .leftMouseUp ? 0 : 1) else { return XCTFail("an event") }
        switch type {
        case .leftMouseDown: webView.mouseDown(with: event)
        case .leftMouseDragged: webView.mouseDragged(with: event)
        default: webView.mouseUp(with: event)
        }
    }

    /// The stored sRGB values at `point` (points from the top left), unconverted: `colorAt` labels a CGImage's pixels with
    /// a colour space of its own choosing, and converting from it would move them.
    private func pixel(_ rep: NSBitmapImageRep, _ point: NSPoint, scale: CGFloat) -> NSColor? {
        var raw = [Int](repeating: 0, count: 4)
        rep.getPixel(&raw, atX: Int(point.x * scale), y: Int(point.y * scale))
        let alpha = CGFloat(raw[3]) / 255
        // Premultiplied: undo it, so a colour reads as itself wherever it is opaque.
        let channel = { (value: Int) in alpha > 0 ? min(1, CGFloat(value) / 255 / alpha) : 0 }
        return NSColor(srgbRed: channel(raw[0]), green: channel(raw[1]), blue: channel(raw[2]), alpha: alpha)
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

    /// A reader in a window showing one conversation whose message carries two files, over an engine whose provider serves
    /// them from memory.
    @MainActor
    private final class ReaderFixture {
        let reader: ConversationViewController
        let messageID: MessageID
        let webView: ReaderWebView
        let window: NSWindow

        init(folder: URL, served: [AttachmentInfo]? = nil) throws {
            let account = ListTestSupport.accountA
            let conversation = ConversationID(accountID: account.id, providerID: "thread-plan")
            messageID = AttachmentDragTests.message
            let store = InMemoryMailStore()
            try store.upsertAccount(account)
            try store.upsertMessages([MessageMetadata(
                id: messageID, conversationID: conversation, subject: "The plan", snippet: "Attached.",
                from: EmailAddress(name: "Ada Lovelace", address: "ada@example.com"), to: [EmailAddress(address: account.email)],
                date: Date(), roles: [.inbox], isRead: true, isStarred: false, hasAttachments: true
            )])
            try store.saveBody(StoredBody(body: MessageBody(html: "<p>Attached, with the notes.</p>", text: "Attached.",
                                                            attachments: [AttachmentDragTests.plan, AttachmentDragTests.notes]),
                                          renderedHTML: "<p>Attached, with the notes.</p>", plainText: "Attached."), for: messageID)
            let bytes = [AttachmentDragTests.plan.id: AttachmentDragTests.planBytes, AttachmentDragTests.notes.id: AttachmentDragTests.notesBytes]
            let servedIDs = Set((served ?? [AttachmentDragTests.plan, AttachmentDragTests.notes]).map(\.id))
            let provider = CountingAttachmentProvider(accountID: account.id, files: bytes.filter { servedIDs.contains($0.key) })
            let engine = MailEngine(store: store, tokenStore: InMemoryTokenStore(), tokenProvider: DemoTokenProvider(),
                                    authenticator: DemoAuthenticator(), sanitizer: HTMLSanitizer(), providerFactory: { _ in provider },
                                    attachmentCacheDirectory: folder.appendingPathComponent("attachments-\(UUID().uuidString)", isDirectory: true))
            reader = ConversationViewController(client: engine)
            window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: 900, height: 700), styleMask: [.titled],
                              backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = reader
            window.setContentSize(NSSize(width: 900, height: 700))
            window.layoutIfNeeded()
            reader.show(conversation)
            let slot = try XCTUnwrap(reader.pool.current)
            ListTestSupport.spin(until: { slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == conversation },
                                 timeout: 10)
            webView = try XCTUnwrap(slot.webView as? ReaderWebView)
            window.layoutIfNeeded()
            window.makeFirstResponder(webView)
            // The page lays out again at the view's size before anything is measured in it.
            ListTestSupport.spin(until: { false }, timeout: 0.2)
        }

        func close() {
            reader.show(nil)
            window.close()
        }
    }
}

/// Serves each file whole, counting what it is asked for; offline, everything fails as a lost connection does.
final class CountingAttachmentProvider: MailProvider, @unchecked Sendable {
    let accountID: AccountID
    let kind: ProviderKind = .gmail
    private let files: [String: Data]
    private let gate: DropGate?
    private let lock = NSLock()
    private var count = 0
    private var isOffline = false

    init(accountID: AccountID, files: [String: Data], gate: DropGate? = nil) {
        self.accountID = accountID
        self.files = files
        self.gate = gate
    }

    var calls: Int { lock.withLock { count } }
    var offline: Bool {
        get { lock.withLock { isOffline } }
        set { lock.withLock { isOffline = newValue } }
    }

    func attachment(messageID providerID: String, attachmentID: String) async throws -> Data {
        lock.withLock { count += 1 }
        await gate?.wait()
        if offline { throw URLError(.notConnectedToInternet) }
        guard let data = files[attachmentID] else { throw ProviderError.notFound }
        return data
    }

    func profile() async throws -> AccountProfile { AccountProfile(email: "alex@contoso.test", displayName: "Alex") }
    func bootstrap(page: String?, limit: Int) async throws -> BootstrapPage { BootstrapPage(messages: [], nextPage: nil, changeCursor: "c") }
    func changes(since cursor: String, limit: Int) async throws -> ChangesPage { ChangesPage(upserts: [], deletedIDs: [], cursor: cursor, hasMore: false) }
    func metadata(for providerIDs: [String]) async throws -> [MessageMetadata] { [] }
    func body(for providerID: String) async throws -> MessageBody { throw ProviderError.notFound }
    func apply(_ change: MetadataChange, to providerIDs: [String]) async throws {}
    func send(_ message: OutgoingMessage) async throws -> SendReceipt { throw ProviderError.notFound }
    func search(_ text: String, limit: Int) async throws -> [String] { [] }
}

/// Holds files back until the test lets them through.
final class DropGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }

    func open() {
        let released = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters = [] }
            return waiters
        }
        for waiter in released { waiter.resume() }
    }
}

private struct UncheckedPromise: @unchecked Sendable {
    let promise: AttachmentFilePromise
    init(_ promise: AttachmentFilePromise) { self.promise = promise }
}

private final class ThreadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Bool] = []
    func record(_ value: Bool) { lock.withLock { list.append(value) } }
    var values: [Bool] { lock.withLock { list } }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func append(_ event: AttachmentPromiseFulfiller.Event) {
        let kind: String
        switch event {
        case .began: kind = "began"
        case let .progress(_, fraction): kind = "progress \(fraction)"
        case let .ended(_, failure): kind = failure.map { "ended \($0)" } ?? "ended"
        }
        lock.withLock { list.append(kind) }
    }
    var kinds: [String] { lock.withLock { list } }
}

/// `XCTAssertThrowsError` for an async expression.
func XCTAssertThrowsAsync<T>(_ expression: @autoclosure () async throws -> T, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expression()
        XCTFail("expected an error. " + message, file: file, line: line)
    } catch {}
}
