import AppKit
import PaperCore
import XCTest
@testable import PaperApp

/// Esc closes a composer holding nothing worth keeping and leaves one holding the user's work (spec §6.1, §5.20).
/// Drafts go to a temporary folder and the windows are a throwaway store's.
@MainActor
final class ComposerEscapeTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperComposerKeys-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated { ComposeDraftStore.shared.useDirectory(folder) }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private var composers: [ComposeWindowController] { ComposeWindowRegistry.shared.openControllers }

    private var keptDrafts: [URL] {
        ComposeDraftStore.shared.waitForWrites()
        return (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    /// A reply composer for the selection, as Message › Reply opens one.
    private func replyInComposer(_ harness: MainWindowHarness, all: Bool) {
        let action = all ? #selector(MainWindowController.replyAllToSelection(_:)) : #selector(MainWindowController.replyToSelection(_:))
        NSApp.sendAction(action, to: harness.controller, from: nil)
    }

    // MARK: Esc

    func testEscClosesAnUntouchedReplyComposerAndKeepsNoDraft() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.selectFirst(1)
        for escape in ["body", "window"] {
            replyInComposer(harness, all: false)
            let composer = try XCTUnwrap(composers.last)
            if escape == "body" {
                composer.bodyEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            } else {
                composer.window?.cancelOperation(nil)
            }
            XCTAssertTrue(composers.isEmpty, "Esc in the \(escape) closes a reply nobody wrote in")
        }
        XCTAssertTrue(keptDrafts.isEmpty, "and keeps no draft")
    }

    func testEscLeavesAComposerHoldingTheUsersWorkOpen() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.selectFirst(1)
        replyInComposer(harness, all: false)
        let composer = try XCTUnwrap(composers.last)
        let editor = composer.bodyEditor
        editor.insertText("Sounds good", replacementRange: NSRange(location: 0, length: 0))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        composer.window?.cancelOperation(nil)
        XCTAssertEqual(composers.count, 1, "Esc never throws the user's words away")
        XCTAssertTrue(composer.bodyText.hasPrefix("Sounds good"))
    }

    /// An address typed but not yet a token is the user's work: Esc in its field (no suggestion open) or anywhere
    /// else in the composer leaves the window open with the address still there.
    func testEscLeavesAComposerWithAnAddressBeingTypedOpen() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        harness.controller.composeNew()
        let composer = try XCTUnwrap(composers.last)
        let window = try XCTUnwrap(composer.window)
        let to = try XCTUnwrap(Self.addressFields(in: window.contentView).first)
        to.input.stringValue = "pat@fabrikam"
        let escape = #selector(NSResponder.cancelOperation(_:))
        XCTAssertTrue(to.control(to.input, textView: NSTextView(), doCommandBy: escape))
        composer.bodyEditor.doCommand(by: escape)
        window.cancelOperation(nil)
        XCTAssertEqual(composers.count, 1, "Esc never throws a typed address away")
        XCTAssertEqual(to.pendingText, "pat@fabrikam")
    }

    /// The Settings signature field is the composer's text view outside a composer: Esc there is NSTextView's own
    /// and raises nothing.
    func testEscInTheSignatureFieldIsTheTextViewsOwn() {
        let editor = SignatureEditorView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        defer { window.close() }
        XCTAssertFalse(editor.textView.responds(to: #selector(NSResponder.cancelOperation(_:))),
                       "the text view has no Esc of its own to call into")
        editor.textView.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
    }

    private static func addressFields(in view: NSView?) -> [AddressTokenField] {
        guard let view else { return [] }
        if let field = view as? AddressTokenField { return [field] }
        return view.subviews.flatMap { addressFields(in: $0) }
    }
}
