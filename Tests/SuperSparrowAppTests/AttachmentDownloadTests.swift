import AppKit
import SSCore
import SSDesign
import WebKit
import XCTest
@testable import SuperSparrowApp

/// Download on each attachment chip and Download all on a message with two files or more (spec §5.17): the shell's
/// controls and the messages they post, the save itself (a free name, the quarantine kept, one progress for a batch),
/// each file saved once whatever is pressed meanwhile, a batch that ends while its conversation is off screen, the
/// saved toast (§5.30) and File › Download Attachments (⇧⌘D). Files go to a folder of the test's own, never to
/// ~/Downloads; the engine runs over a throwaway store and a provider that serves files from memory, so nothing reaches
/// the network, the Keychain or the user's mail.
@MainActor
final class AttachmentDownloadTests: XCTestCase {
    private var folder: URL!
    private var downloads: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("AttachmentDownloadTests-\(UUID().uuidString)")
        downloads = folder.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // A folder made unwritable by a test must be writable again to be removed.
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: downloads.path)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: The save

    func testACopyTakesAFreeNameAndKeepsTheQuarantine() throws {
        let source = folder.appendingPathComponent("plan.pdf")
        try AttachmentSafety.write(Data("%PDF-1.4".utf8), to: source)
        let first = try XCTUnwrap(AttachmentSaver.copy(source, into: downloads))
        let second = try XCTUnwrap(AttachmentSaver.copy(source, into: downloads))
        XCTAssertEqual(first.lastPathComponent, "plan.pdf")
        XCTAssertEqual(second.lastPathComponent, "plan 2.pdf", "numbered as the Finder numbers a copy")
        XCTAssertTrue(AttachmentSafety.isQuarantined(first))
        XCTAssertTrue(AttachmentSafety.isQuarantined(second))
        XCTAssertEqual(try Data(contentsOf: second), Data("%PDF-1.4".utf8))

        let bare = folder.appendingPathComponent("README")
        try AttachmentSafety.write(Data("hi".utf8), to: bare)
        _ = AttachmentSaver.copy(bare, into: downloads)
        XCTAssertEqual(AttachmentSaver.copy(bare, into: downloads)?.lastPathComponent, "README 2", "no extension, none added")
    }

    /// The session's files are quarantined as they are written; a copy of one that lost its mark is marked again.
    func testACopyOfAnUnmarkedFileIsMarked() throws {
        let source = folder.appendingPathComponent("run.command")
        try Data("#!/bin/sh\n".utf8).write(to: source)
        XCTAssertFalse(AttachmentSafety.isQuarantined(source))
        let copy = try XCTUnwrap(AttachmentSaver.copy(source, into: downloads))
        XCTAssertTrue(AttachmentSafety.isQuarantined(copy))
    }

    func testAFolderThatCannotBeWrittenSavesNothing() throws {
        let source = folder.appendingPathComponent("plan.pdf")
        try AttachmentSafety.write(Data("%PDF-1.4".utf8), to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: downloads.path)
        XCTAssertNil(AttachmentSaver.copy(source, into: downloads))
    }

    /// A copy that cannot be quarantined (a volume that keeps no extended attributes) is removed, not left unmarked
    /// where a retry would only add another; it counts as not written.
    func testACopyThatCannotBeMarkedIsRemoved() throws {
        let source = folder.appendingPathComponent("run.command")
        try Data("#!/bin/sh\n".utf8).write(to: source)
        XCTAssertFalse(AttachmentSafety.isQuarantined(source))
        struct Refused: Error {}
        XCTAssertNil(AttachmentSaver.copy(source, into: downloads, mark: { _ in throw Refused() }))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), [], "the unmarked copy is gone")
        XCTAssertNil(AttachmentSaver.copy(source, into: downloads, mark: { _ in }), "a mark that does not stick is no mark")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), [])
        XCTAssertEqual(AttachmentSaver.copy(source, into: downloads)?.lastPathComponent, "run.command", "the name was not taken")
    }

    /// Download all fetches the files one after another and reports one fraction for all of them, rising, by size; a
    /// file that cannot be fetched is reported and the rest are saved.
    func testABatchSavesWhatArrivesWithOneRisingProgress() async throws {
        let infos = [
            AttachmentInfo(id: "a", filename: "a.pdf", mimeType: "application/pdf", sizeBytes: 1_000, isInline: false),
            AttachmentInfo(id: "b", filename: "b.pdf", mimeType: "application/pdf", sizeBytes: 1_000, isInline: false),
            AttachmentInfo(id: "c", filename: "c.txt", mimeType: "text/plain", sizeBytes: 2_000, isInline: false),
        ]
        let sources = folder.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let fractions = FractionLog()
        var missing: [String] = []
        let outcome = await AttachmentSaver.save(infos, into: downloads, fetch: { info, progress in
            progress(0.5)
            guard info.id != "b" else { return nil }
            let file = sources.appendingPathComponent(info.filename)
            try? AttachmentSafety.write(Data(info.id.utf8), to: file)
            progress(1)
            return file
        }, progress: { fractions.append($0) }, unfetched: { missing.append($0.id) })

        XCTAssertEqual(outcome.requested, 3)
        XCTAssertEqual(outcome.saved.map(\.lastPathComponent), ["a.pdf", "c.txt"])
        XCTAssertEqual(outcome.unfetched, 1)
        XCTAssertEqual(missing, ["b"])
        XCTAssertTrue(outcome.saved.allSatisfy(AttachmentSafety.isQuarantined))
        let seen = fractions.values
        XCTAssertEqual(seen, seen.sorted(), "never backwards")
        XCTAssertEqual(seen.first ?? -1, 0.125, accuracy: 1e-9, "half of the first file, a quarter of the bytes")
        XCTAssertEqual(seen.last ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(outcome.toast(), .saved("Saved 2 of 3 attachments to Downloads"))
    }

    // MARK: Script messages

    /// The two controls post ordinary shell actions; parsing stays total, so a malformed one is dropped.
    func testTheDownloadMessagesParse() throws {
        let message = MessageID(accountID: AccountID("acct"), providerID: "m1")
        let key = RenderPayload.messageKey(for: message)
        let one = ConversationScriptMessage(body: ["kind": "action", "type": "downloadAttachment", "messageID": key, "attachmentID": "att-1"])
        XCTAssertEqual(one, .action(type: "downloadAttachment", messageID: message, attachmentID: "att-1", on: nil, point: nil, value: nil))
        let all = ConversationScriptMessage(body: ["kind": "action", "type": "downloadAllAttachments", "messageID": key,
                                                   "attachmentID": NSNull()])
        XCTAssertEqual(all, .action(type: "downloadAllAttachments", messageID: message, attachmentID: nil, on: nil, point: nil, value: nil))
        XCTAssertNil(ConversationScriptMessage(body: ["kind": "action", "messageID": key]), "no type")
        XCTAssertNil(ConversationScriptMessage(body: "downloadAttachment"))
        // A focused Download control reports itself as the elision mark does, so Space and ↩ press it.
        XCTAssertEqual(ConversationScriptMessage(body: ["kind": "focusMark", "on": true]), .focusMark(true))
    }

    // MARK: The reader

    func testTheReaderDrawsDownloadAndDownloadAllAndSavesThroughThem() throws {
        let fixture = try ReaderFixture(folder: folder)
        let reader = fixture.reader
        reader.downloadsFolder = downloads
        var outcomes: [AttachmentSaveOutcome] = []
        reader.onAction = { action in
            if case .attachmentsSaved(let outcome) = action { outcomes.append(outcome) }
        }
        let webView = fixture.webView

        // Two files and an inline image: the count line names the two, and each chip carries its button.
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-atts-head').length", in: webView) as? Int, 1)
        XCTAssertEqual(evaluate("document.querySelector('.ss-atts-count').textContent", in: webView) as? String, "2 attachments")
        XCTAssertEqual(evaluate("document.querySelector('.ss-dlall').textContent", in: webView) as? String, "Download all")
        XCTAssertEqual(evaluate("document.querySelector('.ss-dlall').title", in: webView) as? String, "Download Attachments  \u{21e7}\u{2318}D")
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-chip-dl').length", in: webView) as? Int, 2)
        let label = "document.querySelector('.ss-chip-dl[data-attachment-id=\"\(ReaderFixture.plan.id)\"]').getAttribute('aria-label')"
        XCTAssertEqual(evaluate(label, in: webView) as? String, "Download plan.pdf", "VoiceOver names the file")
        XCTAssertEqual(evaluate("document.querySelector('.ss-chip-dl').title", in: webView) as? String, "Save to Downloads")
        XCTAssertEqual(evaluate("document.querySelector('.ss-chip-dl').tabIndex", in: webView) as? Int, 0, "the first chip's button is a stop")
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-chip-dl')[1].tabIndex", in: webView) as? Int, -1)

        // Download on a chip: the file in Downloads, still quarantined, then the toast's outcome.
        _ = evaluate("document.querySelector('.ss-chip-dl[data-attachment-id=\"\(ReaderFixture.plan.id)\"]').click(); true", in: webView)
        ListTestSupport.spin(until: { outcomes.count == 1 }, timeout: 5)
        let first = try XCTUnwrap(outcomes.first)
        XCTAssertEqual(first.requested, 1)
        XCTAssertEqual(first.saved.map(\.lastPathComponent), ["plan.pdf"])
        XCTAssertEqual(first.toast(), .saved("Saved to Downloads"))
        let saved = downloads.appendingPathComponent("plan.pdf")
        XCTAssertEqual(try Data(contentsOf: saved), ReaderFixture.planBytes)
        XCTAssertTrue(AttachmentSafety.isQuarantined(saved), "the copy keeps the quarantine")

        // Download all: both files, the taken name numbered, one outcome.
        _ = evaluate("document.querySelector('.ss-dlall').click(); true", in: webView)
        ListTestSupport.spin(until: { outcomes.count == 2 }, timeout: 5)
        let all = try XCTUnwrap(outcomes.last)
        XCTAssertEqual(all.requested, 2)
        XCTAssertEqual(all.saved.map(\.lastPathComponent), ["plan 2.pdf", "notes.txt"])
        XCTAssertEqual(all.toast(), .saved("Saved 2 attachments to Downloads"))
        ListTestSupport.spin(until: { self.evaluate("document.querySelector('.ss-atts-head').classList.contains('ss-loading')", in: webView) as? Bool == false },
                             timeout: 5)
        XCTAssertEqual(evaluate("document.querySelector('.ss-dlall').hasAttribute('aria-disabled')", in: webView) as? Bool, false,
                       "Download all is pressable again once it ends")

        // The context menu's Save to Downloads is the button's: the same save and the same toast.
        fixture.reader.downloadAttachment(ReaderFixture.notes, of: fixture.messageID)
        ListTestSupport.spin(until: { outcomes.count == 3 }, timeout: 5)
        XCTAssertEqual(outcomes.last?.saved.map(\.lastPathComponent), ["notes 2.txt"])
        fixture.close()
    }

    /// One file and an inline image: the chip has its Download button, and there is no count line or Download all,
    /// since an inline image is not a file to save.
    func testOneFileHasNoDownloadAll() throws {
        let fixture = try ReaderFixture(folder: folder, attachments: [ReaderFixture.logo, ReaderFixture.plan])
        let webView = fixture.webView
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-chip').length", in: webView) as? Int, 1)
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-chip-dl').length", in: webView) as? Int, 1)
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-atts-head, .ss-dlall').length", in: webView) as? Int, 0)
        fixture.close()
    }

    /// While Download all runs the count line shows one contrail and the link is disabled; a chip's own download
    /// disables its button. The values are the chip's: a fraction, null to sweep, negative to end.
    func testProgressDisablesTheControlThatStartedIt() throws {
        let fixture = try ReaderFixture(folder: folder)
        let webView = fixture.webView
        let key = ConversationShellAssets.jsStringLiteral(RenderPayload.messageKey(for: fixture.messageID))
        _ = evaluate("window.ss.attachmentsProgress(\(key), 0.5); true", in: webView)
        XCTAssertEqual(evaluate("document.querySelector('.ss-atts-head .ss-dl-fill').style.width", in: webView) as? String, "60px")
        XCTAssertEqual(evaluate("getComputedStyle(document.querySelector('.ss-atts-count')).display", in: webView) as? String, "none",
                       "the count gives way to the contrail")
        XCTAssertEqual(evaluate("document.querySelector('.ss-dlall').getAttribute('aria-disabled')", in: webView) as? String, "true")
        XCTAssertEqual(evaluate("document.querySelectorAll('.ss-chip.ss-loading').length", in: webView) as? Int, 0, "the chips do not show the batch")
        _ = evaluate("window.ss.attachmentsProgress(\(key), -1); true", in: webView)
        XCTAssertEqual(evaluate("document.querySelector('.ss-dlall').hasAttribute('aria-disabled')", in: webView) as? Bool, false)

        let plan = ConversationShellAssets.jsStringLiteral(ReaderFixture.plan.id)
        _ = evaluate("window.ss.attachmentProgress(\(key), \(plan), null); true", in: webView)
        let button = "document.querySelector('.ss-chip-dl[data-attachment-id=\"\(ReaderFixture.plan.id)\"]')"
        XCTAssertEqual(evaluate("\(button).getAttribute('aria-disabled')", in: webView) as? String, "true")
        // A press while it downloads posts nothing.
        fixture.reader.downloadsFolder = downloads
        var outcomes = 0
        fixture.reader.onAction = { action in
            if case .attachmentsSaved = action { outcomes += 1 }
        }
        _ = evaluate("\(button).click(); true", in: webView)
        ListTestSupport.spin(for: 0.3)
        XCTAssertEqual(outcomes, 0)
        _ = evaluate("window.ss.attachmentProgress(\(key), \(plan), -1); true", in: webView)
        XCTAssertEqual(evaluate("\(button).hasAttribute('aria-disabled')", in: webView) as? Bool, false)
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: downloads.path)).isEmpty, "nothing was saved")
        fixture.close()
    }

    /// ← → move the stop along the chips' Download buttons as along the chips.
    func testArrowsMoveAlongTheDownloadButtons() throws {
        let fixture = try ReaderFixture(folder: folder)
        let webView = fixture.webView
        let script = """
            (function () {
              var saves = document.querySelectorAll('.ss-chip-dl');
              saves[0].focus();
              saves[0].dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true, cancelable: true }));
              var chips = document.querySelectorAll('.ss-chip');
              return [document.activeElement === saves[1], saves[1].tabIndex, chips[1].tabIndex, saves[0].tabIndex, chips[0].tabIndex];
            })()
            """
        let state = evaluate(script, in: webView) as? [Any]
        XCTAssertEqual(state?.first as? Bool, true, "focus moves to the next file's button")
        XCTAssertEqual(state?.dropFirst().compactMap { $0 as? Int }, [0, 0, -1, -1], "the chip and its button share the stop")
        fixture.close()
    }

    /// Focus on a Download button or on Download all is reported as on an elision mark, so the app passes Space and ↩
    /// to the page (which presses the control) instead of opening Quick Look or the conversation; focus on a chip is not.
    func testAFocusedDownloadControlTakesSpaceAndReturn() throws {
        let fixture = try ReaderFixture(folder: folder)
        defer { fixture.close() }
        let reader = fixture.reader
        reader.attachmentPreview.presentsPanel = false
        let slot = try XCTUnwrap(reader.pool.current)
        let webView = fixture.webView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        reader.view.frame = window.contentLayoutRect
        window.contentView?.addSubview(reader.view)
        XCTAssertTrue(window.makeFirstResponder(webView))
        XCTAssertFalse(slot.markFocused)

        _ = evaluate("document.querySelector('.ss-chip-dl').focus(); true", in: webView)
        XCTAssertTrue(ListTestSupport.spin(until: { slot.markFocused }, timeout: 5), "the shell says a Download button has focus")
        XCTAssertTrue(reader.isMarkFocused)
        XCTAssertFalse(reader.openQuickLookForSelectedMessage(), "Space goes on to the page, which presses the button")

        _ = evaluate("document.querySelector('.ss-chip').focus(); true", in: webView)
        XCTAssertTrue(ListTestSupport.spin(until: { !slot.markFocused }, timeout: 5), "and that it left it for the chip")
        XCTAssertFalse(reader.isMarkFocused)

        _ = evaluate("document.querySelector('.ss-dlall').focus(); true", in: webView)
        XCTAssertTrue(ListTestSupport.spin(until: { slot.markFocused }, timeout: 5), "Download all too")
        XCTAssertFalse(reader.openQuickLookForSelectedMessage())
        _ = evaluate("document.activeElement.blur(); true", in: webView)
        XCTAssertTrue(ListTestSupport.spin(until: { !slot.markFocused }, timeout: 5), "and when focus leaves it")
        XCTAssertTrue(reader.openQuickLookForSelectedMessage(), "Space is Quick Look's again")
    }

    /// A double-click on Download saves the file once, even when it is already on this Mac and saved before the second
    /// click lands: the shell drops the second click, and the app a second request that comes as soon. A later press
    /// is a second save.
    func testADoubleClickSavesAFileOnce() throws {
        let fixture = try ReaderFixture(folder: folder)
        defer { fixture.close() }
        let reader = fixture.reader
        reader.downloadsFolder = downloads
        let webView = fixture.webView
        let messageID = fixture.messageID
        var outcomes: [AttachmentSaveOutcome] = []
        var again = true
        reader.onAction = { [unowned reader] action in
            guard case .attachmentsSaved(let outcome) = action else { return }
            outcomes.append(outcome)
            // The second click of a double-click, landing right after the first saved the file.
            if again {
                again = false
                reader.downloadAttachment(ReaderFixture.plan, of: messageID)
            }
        }
        reader.downloadAttachment(ReaderFixture.plan, of: messageID)
        reader.downloadAttachment(ReaderFixture.plan, of: messageID)
        XCTAssertTrue(ListTestSupport.spin(until: { outcomes.count == 1 }, timeout: 5))
        ListTestSupport.spin(for: 0.3)
        XCTAssertFalse(again, "the second request came")
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path), ["plan.pdf"])

        // The shell posts nothing for a click that is a double-click's second.
        let button = "document.querySelector('.ss-chip-dl[data-attachment-id=\"\(ReaderFixture.notes.id)\"]')"
        let first = "new MouseEvent('click', { bubbles: true, cancelable: true, detail: 1 })"
        let second = "new MouseEvent('click', { bubbles: true, cancelable: true, detail: 2 })"
        _ = evaluate("\(button).dispatchEvent(\(second)); true", in: webView)
        ListTestSupport.spin(for: 0.3)
        XCTAssertEqual(outcomes.count, 1, "a second click alone saves nothing")
        _ = evaluate("\(button).dispatchEvent(\(first)); \(button).dispatchEvent(\(second)); "
                     + "document.querySelector('.ss-dlall').dispatchEvent(\(second)); true", in: webView)
        XCTAssertTrue(ListTestSupport.spin(until: { outcomes.count == 2 }, timeout: 5))
        ListTestSupport.spin(for: 0.3)
        XCTAssertEqual(outcomes.count, 2, "one save for the double-click, none for Download all's second click")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path).sorted(), ["notes.txt", "plan.pdf"])

        // Past a double-click, a press is a second save.
        ListTestSupport.spin(for: NSEvent.doubleClickInterval + 0.1)
        reader.downloadAttachment(ReaderFixture.plan, of: messageID)
        XCTAssertTrue(ListTestSupport.spin(until: { outcomes.count == 3 }, timeout: 5))
        XCTAssertEqual(outcomes.last?.saved.map(\.lastPathComponent), ["plan 2.pdf"])
    }

    /// While Download all saves a message's files, a chip's Download (or its menu's Save to Downloads) does nothing:
    /// the batch is saving that file.
    func testAChipPressDuringDownloadAllSavesNothingMore() throws {
        let gate = FileGate()
        let fixture = try ReaderFixture(folder: folder, gate: gate)
        defer { fixture.close() }
        let reader = fixture.reader
        reader.downloadsFolder = downloads
        var outcomes: [AttachmentSaveOutcome] = []
        reader.onAction = { action in
            if case .attachmentsSaved(let outcome) = action { outcomes.append(outcome) }
        }
        reader.downloadAllAttachments(of: fixture.messageID)
        ListTestSupport.spin(for: 0.05)
        reader.downloadAttachment(ReaderFixture.plan, of: fixture.messageID)
        gate.open()
        XCTAssertTrue(ListTestSupport.spin(until: { !outcomes.isEmpty }, timeout: 5))
        ListTestSupport.spin(for: 0.3)
        XCTAssertEqual(outcomes.count, 1)
        XCTAssertEqual(outcomes.first?.saved.map(\.lastPathComponent), ["plan.pdf", "notes.txt"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path).sorted(), ["notes.txt", "plan.pdf"])
    }

    /// Download all leaves a file whose own Download is under way to it and saves the rest: every file once.
    func testDownloadAllLeavesAFileBeingDownloadedToItsChip() throws {
        let gate = FileGate()
        let fixture = try ReaderFixture(folder: folder, gate: gate)
        defer { fixture.close() }
        let reader = fixture.reader
        reader.downloadsFolder = downloads
        var outcomes: [AttachmentSaveOutcome] = []
        reader.onAction = { action in
            if case .attachmentsSaved(let outcome) = action { outcomes.append(outcome) }
        }
        reader.downloadAttachment(ReaderFixture.plan, of: fixture.messageID)
        ListTestSupport.spin(for: 0.05)
        reader.downloadAllAttachments(of: fixture.messageID)
        gate.open()
        XCTAssertTrue(ListTestSupport.spin(until: { outcomes.count == 2 }, timeout: 5))
        ListTestSupport.spin(for: 0.3)
        XCTAssertEqual(outcomes.count, 2)
        XCTAssertEqual(outcomes.map(\.requested), [1, 1])
        XCTAssertEqual(Set(outcomes.flatMap(\.saved).map(\.lastPathComponent)), ["plan.pdf", "notes.txt"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: downloads.path).sorted(), ["notes.txt", "plan.pdf"])
    }

    /// A Download all that ends while another conversation is on screen ends in its own page all the same: coming back
    /// is a swap with no render, and it shows the count and a pressable Download all again, with the file that could not
    /// be fetched marked.
    func testDownloadAllThatEndsElsewhereEndsInItsPage() throws {
        let gate = FileGate()
        let fixture = try ReaderFixture(folder: folder, served: [ReaderFixture.plan], gate: gate)
        defer { fixture.close() }
        let reader = fixture.reader
        reader.downloadsFolder = downloads
        var outcomes: [AttachmentSaveOutcome] = []
        reader.onAction = { action in
            if case .attachmentsSaved(let outcome) = action { outcomes.append(outcome) }
        }
        let page = try XCTUnwrap(reader.pool.current)
        let webView = fixture.webView
        _ = evaluate("document.querySelector('.ss-dlall').click(); true", in: webView)
        XCTAssertTrue(ListTestSupport.spin(until: {
            self.evaluate("document.querySelector('.ss-dlall').getAttribute('aria-disabled')", in: webView) as? String == "true"
        }, timeout: 5), "the download shows")

        XCTAssertTrue(fixture.show(fixture.otherConversation))
        XCTAssertFalse(reader.pool.current === page)
        XCTAssertTrue(reader.pool.slot(rendering: fixture.conversation) === page, "kept warm in the pool")
        gate.open()
        XCTAssertTrue(ListTestSupport.spin(until: { !outcomes.isEmpty }, timeout: 5))
        XCTAssertEqual(outcomes.first?.saved.map(\.lastPathComponent), ["plan.pdf"])
        XCTAssertEqual(outcomes.first?.unfetched, 1)

        XCTAssertTrue(fixture.show(fixture.conversation))
        XCTAssertTrue(reader.pool.current === page, "the same page, swapped back in")
        XCTAssertTrue(ListTestSupport.spin(until: {
            self.evaluate("document.querySelector('.ss-dlall').hasAttribute('aria-disabled')", in: webView) as? Bool == false
        }, timeout: 5), "Download all is pressable again")
        XCTAssertEqual(evaluate("document.querySelector('.ss-atts-head').classList.contains('ss-loading')", in: webView) as? Bool, false,
                       "the count is back")
        let failed = "document.querySelector('.ss-chip[data-attachment-id=\"\(ReaderFixture.notes.id)\"]').classList.contains('ss-failed')"
        XCTAssertEqual(evaluate(failed, in: webView) as? Bool, true, "the file that could not be fetched says so")
    }

    // MARK: The main window

    func testTheSavedToastOffersShowInFinder() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let saved = [downloads.appendingPathComponent("plan.pdf"), downloads.appendingPathComponent("notes.txt")]
        harness.controller.handle(.attachmentsSaved(AttachmentSaveOutcome(requested: 2, saved: saved, unfetched: 0)))
        // The long words where they fit beside Show in Finder, else shorter ones, so the count is never cut off.
        func fits(_ words: String) -> Bool {
            harness.toasts.fits(words, symbol: Quire.Icon.download, actionTitle: "Show in Finder", keycap: nil)
        }
        let long = "Saved 2 attachments to Downloads"
        XCTAssertEqual(harness.toastMessage, fits(long) ? long : "Saved 2 to Downloads")
        XCTAssertTrue(fits("Saved 2 to Downloads"), "the short words fit the default list")
        XCTAssertTrue(fits("Saved 2 of 3"), "and so do the shortest")
        XCTAssertEqual(harness.toasts.visibleKind, .notice, "a notice: nothing to undo")
        let slip = try XCTUnwrap(harness.controller.listPane.toastView.slip)
        XCTAssertEqual(slip.actionButton?.title, "Show in Finder")
        XCTAssertNil(slip.actionButton?.keycap, "no keycap: Z is not this toast's")
        XCTAssertEqual(slip.symbolName, Quire.Icon.download)
        XCTAssertEqual(slip.announcement, (harness.toastMessage ?? "") + ". Show in Finder.")

        harness.controller.handle(.attachmentsSaved(AttachmentSaveOutcome(requested: 1, saved: [], unfetched: 0)))
        XCTAssertEqual(harness.toastMessage, "Couldn\u{2019}t save to Downloads")
        XCTAssertEqual(harness.toasts.visibleKind, .error)

        harness.toasts.dismiss()
        harness.controller.handle(.attachmentsSaved(AttachmentSaveOutcome(requested: 2, saved: [], unfetched: 2)))
        XCTAssertFalse(harness.toasts.isVisible, "the chips say what could not be fetched")
    }

    /// File › Download Attachments is ⇧⌘D, answers from the list, and needs the target message to have a file of its
    /// own (an inline image is not one).
    func testFileDownloadAttachmentsIsCommandShiftDAndNeedsFiles() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0,
                                                   windowNumber: 0, context: nil, characters: "D", charactersIgnoringModifiers: "d",
                                                   isARepeat: false, keyCode: 2))
        let item = try XCTUnwrap(MainMenuBar.exactItem(for: event, in: bar))
        XCTAssertEqual(item.title, "Download Attachments")
        XCTAssertEqual(item.menu?.title, "File")
        XCTAssertEqual(item.action, #selector(MainWindowController.downloadAttachments(_:)))
        XCTAssertFalse(harness.controller.validateMenuItem(item), "nothing selected")

        let shown = try XCTUnwrap(harness.list.conversations.first { $0.hasAttachments })
        harness.controller.window?.makeFirstResponder(harness.list.tableView)
        harness.list.selectedConversationID = shown.id
        harness.list.onSelectionChange?(shown.id)
        harness.spin { harness.reader.currentConversationID == shown.id && !harness.reader.currentMessages.isEmpty }
        let target = try XCTUnwrap(harness.reader.selectedMessageID ?? harness.reader.currentMessages.last?.id)
        let inline = AttachmentInfo(id: "cid", filename: "logo.png", mimeType: "image/png", sizeBytes: 10, contentID: "logo", isInline: true)
        try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: "<p>Hi</p>", text: "Hi", attachments: [inline]),
                                                          renderedHTML: "<p>Hi</p>", plainText: "Hi"), for: target)
        XCTAssertFalse(harness.controller.validateMenuItem(item), "an inline image is not a file to save")
        let file = AttachmentInfo(id: "a1", filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 2_048, isInline: false)
        try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: "<p>Hi</p>", text: "Hi", attachments: [inline, file]),
                                                          renderedHTML: "<p>Hi</p>", plainText: "Hi"), for: target)
        XCTAssertTrue(harness.controller.validateMenuItem(item), "offered from the list, the reader not in the chain")
    }

    // MARK: Helpers

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

/// Fractions as the batch reports them, from any thread.
private final class FractionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [Double] = []
    func append(_ value: Double) { lock.withLock { list.append(value) } }
    var values: [Double] { lock.withLock { list } }
}

/// A reader showing one conversation whose latest message carries two files and an inline image, over an engine whose
/// provider serves the files from memory; a second conversation, with no files, is there to move to and back.
@MainActor
private final class ReaderFixture {
    static let plan = AttachmentInfo(id: "att-plan", filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 4_000, isInline: false)
    static let notes = AttachmentInfo(id: "att-notes", filename: "notes.txt", mimeType: "text/plain", sizeBytes: 12, isInline: false)
    static let logo = AttachmentInfo(id: "att-logo", filename: "logo.png", mimeType: "image/png", sizeBytes: 10, contentID: "logo", isInline: true)
    static let planBytes = Data(repeating: 7, count: 4_000)
    static let notesBytes = Data("Notes, line 1".utf8)

    let reader: ConversationViewController
    let conversation: ConversationID
    let otherConversation: ConversationID
    let messageID: MessageID
    let webView: WKWebView

    /// - Parameters:
    ///   - served: the files the provider has (both, when nil); any other fails, as a file the server no longer has would.
    ///   - gate: holds every file back until it opens.
    init(folder: URL, attachments: [AttachmentInfo]? = nil, served: [AttachmentInfo]? = nil, gate: FileGate? = nil) throws {
        let account = ListTestSupport.accountA
        conversation = ConversationID(accountID: account.id, providerID: "thread-plan")
        otherConversation = ConversationID(accountID: account.id, providerID: "thread-other")
        messageID = MessageID(accountID: account.id, providerID: "msg-plan")
        let otherMessage = MessageID(accountID: account.id, providerID: "msg-other")
        let store = InMemoryMailStore()
        try store.upsertAccount(account)
        try store.upsertMessages([MessageMetadata(
            id: messageID, conversationID: conversation, subject: "The plan", snippet: "Attached.",
            from: EmailAddress(name: "Ada Lovelace", address: "ada@example.com"), to: [EmailAddress(address: account.email)],
            date: Date(), roles: [.inbox], isRead: true, isStarred: false, hasAttachments: true
        ), MessageMetadata(
            id: otherMessage, conversationID: otherConversation, subject: "Lunch", snippet: "Noon?",
            from: EmailAddress(name: "Ben Carter", address: "ben@example.com"), to: [EmailAddress(address: account.email)],
            date: Date().addingTimeInterval(-60), roles: [.inbox], isRead: true, isStarred: false, hasAttachments: false
        )])
        try store.saveBody(StoredBody(body: MessageBody(html: "<p>Attached.</p>", text: "Attached.", attachments: attachments ?? [Self.plan, Self.logo, Self.notes]),
                                      renderedHTML: "<p>Attached.</p>", plainText: "Attached."), for: messageID)
        try store.saveBody(StoredBody(body: MessageBody(html: "<p>Noon?</p>", text: "Noon?", attachments: []),
                                      renderedHTML: "<p>Noon?</p>", plainText: "Noon?"), for: otherMessage)
        let bytes = [Self.plan.id: Self.planBytes, Self.notes.id: Self.notesBytes]
        let servedIDs = Set((served ?? [Self.plan, Self.notes]).map(\.id))
        let provider = ServedAttachmentProvider(accountID: account.id, files: bytes.filter { servedIDs.contains($0.key) }, gate: gate)
        let engine = MailEngine(store: store, tokenStore: InMemoryTokenStore(), tokenProvider: DemoTokenProvider(),
                                authenticator: DemoAuthenticator(), sanitizer: HTMLSanitizer(), providerFactory: { _ in provider },
                                attachmentCacheDirectory: folder.appendingPathComponent("attachments", isDirectory: true))
        reader = ConversationViewController(client: engine)
        _ = reader.view
        reader.show(conversation)
        let slot = try XCTUnwrap(reader.pool.current)
        let shown = conversation
        ListTestSupport.spin(until: { slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == shown },
                             timeout: 10)
        webView = slot.webView
    }

    /// Shows `id` and waits until its page is the one on screen, landed.
    @discardableResult
    func show(_ id: ConversationID) -> Bool {
        reader.show(id)
        return ListTestSupport.spin(until: {
            guard let slot = self.reader.pool.current else { return false }
            return slot.isReady && slot.pendingRender == nil && !slot.renderInFlight && slot.renderedID == id
        }, timeout: 10)
    }

    func close() {
        reader.show(nil)
    }
}

/// Holds files back until the test lets them through, so it can act while a download is under way.
private final class FileGate: @unchecked Sendable {
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

/// Serves each file whole, once its gate (if any) opens; an id it does not know fails, as a file the server no longer
/// has would.
private final class ServedAttachmentProvider: MailProvider, @unchecked Sendable {
    let accountID: AccountID
    let kind: ProviderKind = .gmail
    private let files: [String: Data]
    private let gate: FileGate?

    init(accountID: AccountID, files: [String: Data], gate: FileGate? = nil) {
        self.accountID = accountID
        self.files = files
        self.gate = gate
    }

    func attachment(messageID providerID: String, attachmentID: String) async throws -> Data {
        await gate?.wait()
        guard let data = files[attachmentID] else { throw ProviderError.notFound }
        return data
    }

    func profile() async throws -> AccountProfile { AccountProfile(email: "alex@contoso.test", displayName: "Alex") }
    func bootstrap(page: String?, limit: Int) async throws -> BootstrapPage {
        BootstrapPage(messages: [], nextPage: nil, changeCursor: "c")
    }
    func changes(since cursor: String, limit: Int) async throws -> ChangesPage {
        ChangesPage(upserts: [], deletedIDs: [], cursor: cursor, hasMore: false)
    }
    func metadata(for providerIDs: [String]) async throws -> [MessageMetadata] { [] }
    func body(for providerID: String) async throws -> MessageBody { throw ProviderError.notFound }
    func apply(_ change: MetadataChange, to providerIDs: [String]) async throws {}
    func send(_ message: OutgoingMessage) async throws -> SendReceipt { throw ProviderError.notFound }
    func search(_ text: String, limit: Int) async throws -> [String] { [] }
}
