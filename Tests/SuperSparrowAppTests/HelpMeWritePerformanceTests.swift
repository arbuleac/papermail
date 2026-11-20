import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// Help me write's budgets in docs/ARCHITECTURE.md (spec §5.55): ⌘J to the card on screen within 16 ms (nothing about the
/// conversation is read for it), and each streamed update of the field within 4 ms, at most one a frame, however long the
/// reply grows. Only with `SS_PERF=1`:
///
///     SS_PERF=1 swift test -c release -Xswiftc -enable-testing --filter HelpMeWritePerformanceTests
@MainActor
final class HelpMeWritePerformanceTests: XCTestCase {
    override func setUpWithError() throws {
        guard ProcessInfo.processInfo.environment["SS_PERF"] == "1" else {
            throw XCTSkip("set SS_PERF=1 to run the Help me write benchmark")
        }
    }

    func testCommandJShowsTheCardWithinAFrameAndEachUpdateTakesUnder4ms() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.settings.aiProvider = .claudeAPI
        let id = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = id
        harness.list.onSelectionChange?(id)
        harness.spin { harness.reader.currentMessages.count == 3 }
        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        let field = harness.reader.quickReplyBar.writingTextView
        field.insertText("tue 10 ok", replacementRange: NSRange(location: 0, length: 0))

        var opens: [Double] = []
        for _ in 0..<15 {
            harness.reader.closeWriteCard()
            harness.controller.window?.makeFirstResponder(field)
            let start = DispatchTime.now().uptimeNanoseconds
            harness.reader.helpMeWrite(nil)
            harness.reader.view.layoutSubtreeIfNeeded()
            opens.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        }
        harness.reader.closeWriteCard()

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
        print(String(format: "Help me write budget: ⌘J to the card %.2f ms (median of %d); an update %.2f ms median, %.2f ms p95 over %d updates to %d characters",
                     open, opens.count, median, p95, updates.count, written.count))
        XCTAssertLessThan(open, 16)
        XCTAssertLessThan(p95, 4)
    }
}
