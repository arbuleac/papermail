import AppKit
import XCTest
@testable import SSCore

final class ReaderShortcutsTests: XCTestCase {
    private typealias S = ReaderShortcuts

    func testModifierBitsMatchAppKit() {
        XCTAssertEqual(S.capsLock, NSEvent.ModifierFlags.capsLock.rawValue)
        XCTAssertEqual(S.shift, NSEvent.ModifierFlags.shift.rawValue)
        XCTAssertEqual(S.control, NSEvent.ModifierFlags.control.rawValue)
        XCTAssertEqual(S.option, NSEvent.ModifierFlags.option.rawValue)
        XCTAssertEqual(S.command, NSEvent.ModifierFlags.command.rawValue)
        XCTAssertEqual(S.numericPad, NSEvent.ModifierFlags.numericPad.rawValue)
        XCTAssertEqual(S.function, NSEvent.ModifierFlags.function.rawValue)
        XCTAssertEqual(S.chordMask & NSEvent.ModifierFlags.deviceIndependentFlagsMask.rawValue, S.chordMask)
    }

    func testSendChordIgnoresCapsLockAndTheKeypadBit() {
        XCTAssertTrue(S.isSend(keyCode: 36, rawModifierFlags: S.command))
        XCTAssertTrue(S.isSend(keyCode: 36, rawModifierFlags: S.command | S.capsLock), "Caps Lock on")
        XCTAssertTrue(S.isSend(keyCode: 76, rawModifierFlags: S.command | S.numericPad), "keypad Enter")
        XCTAssertTrue(S.isSend(keyCode: 76, rawModifierFlags: S.command | S.numericPad | S.capsLock | S.function))
    }

    func testSendChordIsExactlyCommandOnReturn() {
        XCTAssertFalse(S.isSend(keyCode: 36, rawModifierFlags: 0), "plain Return inserts a newline")
        XCTAssertFalse(S.isSend(keyCode: 36, rawModifierFlags: S.command | S.shift))
        XCTAssertFalse(S.isSend(keyCode: 36, rawModifierFlags: S.option))
        XCTAssertFalse(S.isSend(keyCode: 49, rawModifierFlags: S.command), "Cmd+Space is not a send")
    }

    /// ⇧⌘↩ sends and archives whatever Send does (spec §5.23, §6); it is never ⌘↩, nor ⌘↩ it.
    func testSendAndArchiveChordIsShiftCommandOnReturn() {
        XCTAssertTrue(S.isSendAndArchive(keyCode: 36, rawModifierFlags: S.command | S.shift))
        XCTAssertTrue(S.isSendAndArchive(keyCode: 76, rawModifierFlags: S.command | S.shift | S.numericPad | S.capsLock), "keypad Enter, Caps Lock on")
        XCTAssertFalse(S.isSendAndArchive(keyCode: 36, rawModifierFlags: S.command), "⌘↩ is Send")
        XCTAssertFalse(S.isSendAndArchive(keyCode: 36, rawModifierFlags: S.shift), "⇧↩ is a line break")
        XCTAssertFalse(S.isSendAndArchive(keyCode: 36, rawModifierFlags: S.command | S.shift | S.option))
        XCTAssertFalse(S.isSendAndArchive(keyCode: 49, rawModifierFlags: S.command | S.shift))
    }

    func testPlainSpaceIgnoresCapsLock() {
        XCTAssertTrue(S.isPlainSpace(charactersIgnoringModifiers: " ", rawModifierFlags: 0))
        XCTAssertTrue(S.isPlainSpace(charactersIgnoringModifiers: " ", rawModifierFlags: S.capsLock))
        XCTAssertFalse(S.isPlainSpace(charactersIgnoringModifiers: " ", rawModifierFlags: S.shift))
        XCTAssertFalse(S.isPlainSpace(charactersIgnoringModifiers: " ", rawModifierFlags: S.command))
        XCTAssertFalse(S.isPlainSpace(charactersIgnoringModifiers: "j", rawModifierFlags: 0))
        XCTAssertFalse(S.isPlainSpace(charactersIgnoringModifiers: nil, rawModifierFlags: 0))
    }

    func testSpaceWithNothingToPreviewIsLeftToTheWebView() {
        let inline = AttachmentInfo(id: "cid-1", filename: "logo.png", mimeType: "image/png", sizeBytes: 10, contentID: "logo", isInline: true)
        let file = AttachmentInfo(id: "att-1", filename: "plan.pdf", mimeType: "application/pdf", sizeBytes: 10, isInline: false)
        XCTAssertEqual(S.spaceOutcome(previewVisible: false, attachments: []), .passThrough)
        XCTAssertEqual(S.spaceOutcome(previewVisible: false, attachments: [inline]), .passThrough, "an inline image is not an attachment to open")
        XCTAssertEqual(S.spaceOutcome(previewVisible: false, attachments: [inline, file]), .preview(file))
        XCTAssertEqual(S.spaceOutcome(previewVisible: true, attachments: []), .closePreview, "an open panel closes even with nothing selected")
        XCTAssertEqual(S.spaceOutcome(previewVisible: true, attachments: [file]), .closePreview)
    }
}
