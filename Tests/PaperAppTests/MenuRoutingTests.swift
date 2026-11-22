import AppKit
import PaperCore
import XCTest
@testable import PaperApp

/// Menu items reach real actions wherever the spec expects them (§5.35): the reader's commands from anywhere
/// in the main window, the composer's Format items from anywhere in the composer but another field.
@MainActor
final class MenuRoutingTests: XCTestCase {
    private func item(_ action: Selector) -> NSMenuItem {
        NSMenuItem(title: "", action: action, keyEquivalent: "")
    }

    func testReaderCommandsAnswerFromTheList() throws {
        let harness = try MainWindowHarness()
        let commands: [Selector] = [#selector(MainWindowController.nextMessage(_:)), #selector(MainWindowController.previousMessage(_:)),
                                    #selector(MainWindowController.toggleQuotedText(_:)), #selector(MainWindowController.loadImages(_:)),
                                    #selector(MainWindowController.toggleOriginalColors(_:)), #selector(MainWindowController.saveAttachments(_:))]
        for command in commands {
            XCTAssertTrue(harness.controller.responds(to: command))
            XCTAssertFalse(harness.controller.validateMenuItem(item(command)), "nothing selected: \(command)")
        }
        // Focus on the list, one conversation shown: the reader's commands work although the reader is not in
        // the responder chain.
        let table = harness.list.tableView
        harness.controller.window?.makeFirstResponder(table)
        let withAttachment = try XCTUnwrap(harness.list.conversations.first { $0.hasAttachments })
        harness.list.selectedConversationID = withAttachment.id
        harness.list.onSelectionChange?(withAttachment.id)
        harness.spin { harness.controller.validateMenuItem(self.item(#selector(MainWindowController.nextMessage(_:)))) }
        XCTAssertTrue(harness.controller.validateMenuItem(item(#selector(MainWindowController.nextMessage(_:)))))
        XCTAssertTrue(harness.controller.validateMenuItem(item(#selector(MainWindowController.loadImages(_:)))))
        // No body is stored, so there are no files to save.
        let save = item(#selector(MainWindowController.saveAttachments(_:)))
        XCTAssertFalse(harness.controller.validateMenuItem(save))
        // With the target message's files stored, Save Attachments… is offered; inline parts do not count.
        let target = try XCTUnwrap(harness.reader.selectedMessageID ?? harness.reader.currentMessages.last?.id)
        let inline = AttachmentInfo(id: "cid", filename: "logo.png", mimeType: "image/png", sizeBytes: 10, contentID: "logo", isInline: true)
        try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: "<p>Hi</p>", text: "Hi", attachments: [inline]),
                                                          renderedHTML: "<p>Hi</p>", plainText: "Hi"), for: target)
        XCTAssertFalse(harness.controller.validateMenuItem(save))
        let file = AttachmentInfo(id: "a1", filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 2_048, isInline: false)
        try harness.environment.store.saveBody(StoredBody(body: MessageBody(html: "<p>Hi</p>", text: "Hi", attachments: [inline, file]),
                                                          renderedHTML: "<p>Hi</p>", plainText: "Hi"), for: target)
        XCTAssertTrue(harness.controller.validateMenuItem(save))
        harness.close()
    }

    func testFormatItemsReachTheBodyFromOutsideItButNotFromAnotherField() throws {
        let harness = try MainWindowHarness()
        let account = ListTestSupport.accountA
        let composer = ComposeWindowController(client: harness.environment.engine, account: account,
                                               accounts: [ListTestSupport.accountA, ListTestSupport.accountB], mode: .new)
        let window = try XCTUnwrap(composer.window)
        let bold = item(#selector(ComposeWindowController.toggleBold(_:)))
        // Typing in another field (the subject's field editor): disabled, so ⌘B never bolds the body.
        let subject = try XCTUnwrap(Self.descendants(of: window.contentView).first { $0 is NSTextField && ($0 as? NSTextField)?.isEditable == true })
        window.makeFirstResponder(subject)
        XCTAssertFalse(composer.validateMenuItem(bold))
        // Focus outside any text (a button, a chip; here the window itself): the item acts on the body, as the
        // format row does.
        window.makeFirstResponder(nil)
        XCTAssertTrue(composer.validateMenuItem(bold))
        composer.toggleBold(nil)
        let body = try XCTUnwrap(window.firstResponder as? ComposeTextView, "the body takes focus")
        XCTAssertTrue(body.formatState.bold)
        XCTAssertTrue(composer.validateMenuItem(item(#selector(ComposeWindowController.toggleFormatRow(_:)))))
        composer.close()
        harness.close()
    }

    private static func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
