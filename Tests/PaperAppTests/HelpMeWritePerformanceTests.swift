import AppKit
import PaperCore
import XCTest
@testable import PaperApp

/// Help me write's budgets in docs/ARCHITECTURE.md (spec §5.56): ⌘J to the write under way within 16 ms (the field in
/// pencil, the pencil after it; the conversation is read off the main thread after), each streamed update of the field
/// within 4 ms, at most one a frame, however long the reply grows, and the marks in the text placed in under 1 ms a
/// keystroke on a 2,000-word body. Only with `PAPER_PERF=1`:
///
///     PAPER_PERF=1 swift test -c release -Xswiftc -enable-testing --filter HelpMeWritePerformanceTests
@MainActor
final class HelpMeWritePerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["PAPER_PERF"] == "1" else {
            throw XCTSkip("set PAPER_PERF=1 to run the Help me write benchmark")
        }
    }

    func testCommandJStartsWithinAFrameAndEachUpdateTakesUnder4ms() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.settings.aiProvider = .claudeAPI
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        harness.environment.helpMeWrite.demoScript?.holdsAfter = 0
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentMessages.count == 3 }
        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        let field = harness.reader.quickReplyBar.writingTextView
        field.insertText("tue 10 ok", replacementRange: NSRange(location: 0, length: 0))

        var opens: [Double] = []
        for _ in 0..<15 {
            harness.reader.endHelpMeWrite()
            harness.controller.window?.makeFirstResponder(field)
            let start = DispatchTime.now().uptimeNanoseconds
            harness.reader.helpMeWrite(nil)
            harness.reader.view.layoutSubtreeIfNeeded()
            opens.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertTrue(harness.reader.isWritingReply)
        }
        harness.reader.endHelpMeWrite()

        // A reply streamed two words at a time to 2,400 characters, each update timed as the session makes it.
        let words = Array(repeating: "Tuesday at ten works for me, and I will bring the draft budget along.", count: 35)
            .joined(separator: " ").split(separator: " ").map(String.init)
        let edit = WriteStreamEdit(textView: field, range: NSRange(location: 0, length: (field.string as NSString).length),
                                   attributes: field.typingAttributes)
        var written = ""
        var updates: [Double] = []
        for pair in stride(from: 0, to: words.count, by: 2) {
            written += words[pair..<min(pair + 2, words.count)].joined(separator: " ") + " "
            let start = DispatchTime.now().uptimeNanoseconds
            edit.show(written)
            harness.reader.quickReplyBar.textDidChangeByWriting()
            updates.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        edit.rollback()
        XCTAssertEqual(field.string, "tue 10 ok")

        let open = opens.sorted()[opens.count / 2]
        let median = updates.sorted()[updates.count / 2]
        let p95 = updates.sorted()[Int(Double(updates.count) * 0.95)]
        print(String(format: "Help me write budget: ⌘J to the write under way %.2f ms (median of %d); an update %.2f ms median, %.2f ms p95 over %d updates to %d characters",
                     open, opens.count, median, p95, updates.count, written.count))
        XCTAssertLessThan(open, 16)
        XCTAssertLessThan(p95, 4)
    }

    /// The ghost, the pill and the rest placed again as each key lands, on a reply composer's body of 2,000 words: the
    /// caret's line is laid out, never the whole body (`ai.place`).
    func testTheMarksArePlacedInUnder1msAKeystrokeOnALongBody() throws {
        try placeMarks(in: .reply(MessageID(accountID: ListTestSupport.accountA.id, providerID: "msg-2-2"), all: false))
    }

    /// The same on a new message, whose body has a session since 1.21 as every composer's does: its marks cost what a
    /// reply's do, though what ⌘J does there is read from the body on every key (notes, or nothing to write from).
    func testTheMarksArePlacedInUnder1msAKeystrokeOnALongNewMessage() throws {
        try placeMarks(in: .new)
    }

    private func placeMarks(in mode: ComposeMode) throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.settings.aiProvider = .claudeAPI
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        let accounts = harness.controller.accounts
        let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                       mode: mode)
        defer { composer.closeWithoutSaving() }
        let editor = composer.bodyEditor
        composer.window?.makeFirstResponder(editor)
        let session = try XCTUnwrap(composer.bodyWriteSession)
        session.assumesKeyWindow = true
        let paragraph = Array(repeating: "Tuesday at ten works for me and I will bring the draft budget along.", count: 20).joined(separator: " ")
        let body = Array(repeating: paragraph, count: 10).joined(separator: "\n\n")
        editor.insertText(body, replacementRange: NSRange(location: 0, length: 0))
        XCTAssertGreaterThanOrEqual(WriteSession.wordCount(in: body), 2_000)
        editor.layoutManager?.ensureLayout(for: editor.textContainer!)
        session.showNotesGhostNow()

        var places: [Double] = []
        for index in 0..<60 {
            // A key at the end of the fifth paragraph, then the marks placed for it, as the session does.
            let at = (paragraph.count + 2) * 5 - 2 + index
            editor.insertText("x", replacementRange: NSRange(location: at, length: 0))
            session.showNotesGhostNow()
            let start = DispatchTime.now().uptimeNanoseconds
            session.selectionDidChange()
            session.showNotesGhostNow()
            places.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000 / 2)
        }
        XCTAssertNotNil(session.layer.state.ghost, "the ghost was placed each time")
        let median = places.sorted()[places.count / 2]
        let p95 = places.sorted()[Int(Double(places.count) * 0.95)]
        print(String(format: "Help me write marks (\(mode == .new ? "new message" : "reply")): placed in %.3f ms median, %.3f ms p95 on %d words",
                     median, p95, WriteSession.wordCount(in: editor.string)))
        XCTAssertLessThan(median, 1)
    }

    /// ⌘J on an empty new message has nothing to write from: it opens the prompt line within a frame and sends nothing.
    /// The body's session is there by the time the window is (it is made as the window comes forward, from this Mac's
    /// facts alone).
    func testCommandJOnAnEmptyNewMessageOpensTheLineWithinAFrame() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.settings.aiProvider = .claudeAPI
        harness.settings.setAIConsent(true, for: .claudeAPI, demo: false)
        let accounts = harness.controller.accounts
        var opens: [Double] = []
        for _ in 0..<15 {
            let composer = ComposeWindowController.present(client: harness.environment.engine, account: accounts[0], accounts: accounts,
                                                           mode: .new)
            composer.window?.makeFirstResponder(composer.bodyEditor)
            let session = try XCTUnwrap(composer.bodyWriteSession)
            let start = DispatchTime.now().uptimeNanoseconds
            composer.helpMeWrite(nil)
            composer.window?.contentView?.layoutSubtreeIfNeeded()
            opens.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
            XCTAssertTrue(session.isPromptShown)
            composer.closeWithoutSaving()
        }
        XCTAssertEqual(harness.environment.helpMeWrite.demoScript?.requests.count, 0, "nothing was sent")
        let open = opens.sorted()[opens.count / 2]
        print(String(format: "Help me write on a new message: ⌘J to the prompt line %.2f ms (median of %d)", open, opens.count))
        XCTAssertLessThan(open, 16)
    }
}
