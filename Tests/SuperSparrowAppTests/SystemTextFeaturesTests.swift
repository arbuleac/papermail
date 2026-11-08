import AppKit
import SSCore
import XCTest
@testable import SuperSparrowApp

/// What the Mac gives every text view stays switched on wherever mail is written (roadmap Q1.8, README "What the Mac
/// provides"): spelling checked as you type with grammar off, the user's own text replacement and autocorrection,
/// Writing Tools, the text system's Edit submenus, the Edit menu AppKit completes with Writing Tools, AutoFill, Start
/// Dictation and Emoji & Symbols, and the Services menu both ways. Using Writing Tools or dictation needs a person; these
/// tests lock in what offers them. Drafts go to a temporary folder and nothing reaches the network.
@MainActor
final class SystemTextFeaturesTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SystemTextFeatures-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated {
            // `NSApp` stays nil until something asks for the shared application; the menu tests read it first.
            _ = NSApplication.shared
            ComposeDraftStore.shared.useDirectory(folder)
        }
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

    // MARK: Where mail is written

    func testTheComposerBodyKeepsTheMacsWritingAids() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let (composer, window) = try newComposer(harness)
        defer { composer.closeWithoutSaving() }
        let body = try XCTUnwrap(Self.descendants(of: window.contentView).compactMap { $0 as? ComposeTextView }.first)
        assertWritingAids(body, "the composer's body")
        XCTAssertTrue(body.isRichText, "Writing Tools may hand back bold, italic and lists")
        XCTAssertTrue(body.allowedWritingToolsResultOptions.isEmpty || body.allowedWritingToolsResultOptions.contains(.richText),
                      "the body takes Writing Tools' rich results: \(body.allowedWritingToolsResultOptions.rawValue)")
    }

    func testTheSignatureFieldIsTheComposersEditorWithTheSameAids() {
        let editor = SignatureEditorView(frame: NSRect(x: 0, y: 0, width: 360, height: 60))
        assertWritingAids(editor.textView, "the Settings signature field")
        XCTAssertTrue(editor.textView.isRichText)
    }

    func testTheQuickReplyChecksSpellingAsTheComposerDoes() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let text = try XCTUnwrap(Self.descendants(of: harness.reader.quickReplyBar).compactMap { $0 as? NSTextView }.first)
        assertWritingAids(text, "the quick reply")
    }

    /// Subject and recipients are edited in the window's one field editor, which AppKit sets up: the user's own text
    /// replacement and autocorrection settings, spelling checked on request (Check Document Now), Writing Tools (its
    /// limited, in-panel form) and Services stay there. The editor is shared, so a setting a recipients field changes on
    /// it would reach the subject too.
    func testSubjectAndRecipientsKeepTextReplacementWritingToolsAndServices() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let (composer, window) = try newComposer(harness)
        defer { composer.closeWithoutSaving() }
        let fields = Self.descendants(of: window.contentView).compactMap { $0 as? NSTextField }.filter(\.isEditable)
        let recipients = fields.filter { $0 is TokenInputField }
        let subject = fields.filter { !($0 is TokenInputField) }
        XCTAssertEqual(recipients.count, 3, "To, Cc and Bcc")
        XCTAssertEqual(subject.count, 1, "Subject")
        for field in recipients + subject {
            let name = field is TokenInputField ? "a recipients field" : "the subject"
            if #available(macOS 15.2, *) { XCTAssertTrue(field.allowsWritingTools, name) }
            XCTAssertTrue(window.makeFirstResponder(field), name)
            let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, name)
            XCTAssertEqual(editor.isAutomaticTextReplacementEnabled, NSSpellChecker.isAutomaticTextReplacementEnabled,
                           "\(name) follows the user's Text Replacement setting")
            XCTAssertEqual(editor.isAutomaticSpellingCorrectionEnabled, NSSpellChecker.isAutomaticSpellingCorrectionEnabled,
                           "\(name) follows the user's Correct Spelling Automatically setting")
            let checkNow = NSMenuItem(title: "Check Document Now", action: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";")
            XCTAssertTrue(editor.validateMenuItem(checkNow), "\(name) is checked on request")
            XCTAssertNotEqual(editor.writingToolsBehavior, .none, name)
            editor.insertText("Plans", replacementRange: editor.selectedRange())
            editor.selectAll(nil)
            let legacy = ComposeTextView.legacyStringType
            XCTAssertTrue(editor.validRequestor(forSendType: legacy, returnType: legacy) as AnyObject? === editor, name)
            let board = NSPasteboard(name: NSPasteboard.Name("SystemTextFeatures-\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            XCTAssertTrue(editor.writeSelection(to: board, types: [legacy]), name)
            XCTAssertEqual(board.string(forType: .string), "Plans", name)
            editor.string = ""
        }
    }

    // MARK: Services

    func testTheServicesMenuIsTheAppMenusServicesItem() throws {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        let appMenu = try XCTUnwrap(bar.items.first?.submenu)
        let services = try XCTUnwrap(appMenu.items.first { $0.title == "Services" }?.submenu)
        XCTAssertTrue(NSApp.servicesMenu === services, "AppKit fills this menu with the services for the selection")
    }

    /// Services that only take the selection (New Note With Selection, Search With Google) and services that hand text
    /// back (Convert Text to Full Width) are both offered in the body; what comes back is plain text in the writing
    /// style, as a paste is. AppKit asks with the legacy pasteboard names, as it does every NSTextView. No service runs
    /// here: the exchange is played on a private pasteboard.
    func testTheComposerBodyGivesItsSelectionToServicesAndTakesTextBack() throws {
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let (composer, window) = try newComposer(harness)
        defer { composer.closeWithoutSaving() }
        let body = try XCTUnwrap(Self.descendants(of: window.contentView).compactMap { $0 as? ComposeTextView }.first)
        XCTAssertTrue(window.makeFirstResponder(body))
        body.insertText("Lunch on Friday", replacementRange: NSRange(location: 0, length: 0))
        body.setSelectedRange(NSRange(location: 9, length: 6))

        let legacy = ComposeTextView.legacyStringType
        XCTAssertTrue(body.validRequestor(forSendType: legacy, returnType: nil) as AnyObject? === body, "services that take the selection")
        XCTAssertTrue(body.validRequestor(forSendType: legacy, returnType: legacy) as AnyObject? === body, "services that hand text back")
        XCTAssertTrue(body.validRequestor(forSendType: nil, returnType: legacy) as AnyObject? === body, "services that insert text")
        let legacyRTF = NSPasteboard.PasteboardType("NeXT Rich Text Format v1.0 pasteboard type")
        XCTAssertNil(body.validRequestor(forSendType: nil, returnType: legacyRTF), "no styled text comes back, as no styled paste does")

        let board = NSPasteboard(name: NSPasteboard.Name("SystemTextFeatures-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        XCTAssertTrue(body.writeSelection(to: board, types: [legacy]))
        XCTAssertEqual(board.string(forType: .string), "Friday")
        board.clearContents()
        board.setString("FRIDAY", forType: .string)
        XCTAssertTrue(body.readSelection(from: board))
        XCTAssertEqual(body.string, "Lunch on FRIDAY")
        MainWindowHarness.assertWritingStyle(body.attributedString())
    }

    // MARK: The Edit menu

    /// Spelling and Grammar, Substitutions (Text Replacement among them), Transformations and Speech, as every Mac app
    /// has them, each answered by the focused text view.
    func testTheEditMenuCarriesTheTextSystemsSubmenus() throws {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        let edit = try XCTUnwrap(bar.items.first { $0.title == "Edit" }?.submenu)
        let expected: [(String, [String])] = [
            ("Spelling and Grammar", ["showGuessPanel:", "checkSpelling:", "toggleContinuousSpellChecking:", "toggleGrammarChecking:",
                                      "toggleAutomaticSpellingCorrection:"]),
            ("Substitutions", ["orderFrontSubstitutionsPanel:", "toggleSmartInsertDelete:", "toggleAutomaticQuoteSubstitution:",
                               "toggleAutomaticDashSubstitution:", "toggleAutomaticLinkDetection:", "toggleAutomaticDataDetection:",
                               "toggleAutomaticTextReplacement:"]),
            ("Transformations", ["uppercaseWord:", "lowercaseWord:", "capitalizeWord:"]),
            ("Speech", ["startSpeaking:", "stopSpeaking:"]),
        ]
        let harness = try MainWindowHarness()
        defer { harness.close() }
        let (composer, window) = try newComposer(harness)
        defer { composer.closeWithoutSaving() }
        let body = try XCTUnwrap(Self.descendants(of: window.contentView).compactMap { $0 as? ComposeTextView }.first)
        body.insertText("Lunch on Friday", replacementRange: NSRange(location: 0, length: 0))
        body.setSelectedRange(NSRange(location: 9, length: 6))
        for (title, actions) in expected {
            let submenu = try XCTUnwrap(edit.items.first { $0.title == title }?.submenu, title)
            let items = submenu.items.filter { !$0.isSeparatorItem }
            XCTAssertEqual(items.compactMap { $0.action.map(NSStringFromSelector) }, actions, title)
            for item in items {
                XCTAssertNil(item.target, "\(item.title) goes to the focused text view")
                XCTAssertTrue(body.responds(to: item.action), "\(item.title): the body answers it")
                // Stop Speaking applies only while speaking.
                if item.action != #selector(NSTextView.stopSpeaking(_:)) {
                    XCTAssertTrue(body.validateMenuItem(item), "\(item.title) is enabled in the body")
                }
            }
        }
        // The checkmarks say what the body does.
        func state(_ title: String, in submenu: String) throws -> NSControl.StateValue {
            let item = try XCTUnwrap(edit.items.first { $0.title == submenu }?.submenu?.items.first { $0.title == title }, title)
            _ = body.validateMenuItem(item)
            return item.state
        }
        XCTAssertEqual(try state("Check Spelling While Typing", in: "Spelling and Grammar"), .on)
        XCTAssertEqual(try state("Check Grammar With Spelling", in: "Spelling and Grammar"), .off)
        XCTAssertEqual(try state("Text Replacement", in: "Substitutions"), body.isAutomaticTextReplacementEnabled ? .on : .off)
        XCTAssertEqual(try state("Smart Links", in: "Substitutions"), .on, "typed addresses become links (spec §5.20)")
    }

    /// AppKit adds Writing Tools, AutoFill, Start Dictation… and Emoji & Symbols to the app's Edit menu as the app
    /// finishes launching (seen on macOS 27.0.1). It finds the menu by its title and by Cut, Copy and Paste, so both stay.
    func testTheEditMenuKeepsWhatAppKitLooksForWhenItAddsDictationAndEmoji() throws {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        let editItem = try XCTUnwrap(bar.items.first { $0.title == "Edit" })
        let edit = try XCTUnwrap(editItem.submenu)
        XCTAssertEqual(edit.title, "Edit")
        let actions = Set(edit.items.compactMap(\.action))
        for action in [#selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:))] {
            XCTAssertTrue(actions.contains(action), NSStringFromSelector(action))
        }
        XCTAssertFalse(edit.items.contains { [NSSelectorFromString("startDictation:"),
                                              #selector(NSApplication.orderFrontCharacterPalette(_:))].contains($0.action) },
                       "AppKit adds these itself; a copy here would show them twice")
    }

    /// fn-D and fn-E (the Globe key) start dictation and open Emoji & Symbols through the hidden items AppKit adds, also
    /// while typing, and never reach Archive's single-key E.
    func testGlobeKeysReachTheItemsAppKitAddsToEdit() throws {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu, NSApp.servicesMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        let edit = try XCTUnwrap(bar.items.first { $0.title == "Edit" }?.submenu)
        // As AppKit adds them on macOS 27.0.1: beside the visible item, a hidden fn alternate.
        func appKitItem(_ title: String, _ action: Selector, key: String) -> NSMenuItem {
            let item = SystemKeyMenuItem(title: title, action: action, keyEquivalent: key)
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
            return item
        }
        let dictation = appKitItem("Start Dictation…", NSSelectorFromString("startDictation:"), key: "d")
        let emoji = appKitItem("Emoji & Symbols", #selector(NSApplication.orderFrontCharacterPalette(_:)), key: "e")
        edit.addItem(.separator())
        edit.addItem(dictation)
        edit.addItem(emoji)
        func key(_ character: String, _ code: UInt16, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                           context: nil, characters: character, charactersIgnoringModifiers: character,
                                           isARepeat: false, keyCode: code))
        }
        XCTAssertTrue(MainMenuBar.exactItem(for: try key("d", 2, .function), in: bar) === dictation)
        XCTAssertTrue(MainMenuBar.exactItem(for: try key("e", 14, .function), in: bar) === emoji)
        XCTAssertEqual(MainMenuBar.exactItem(for: try key("e", 14, []), in: bar)?.action,
                       #selector(MainWindowController.archiveSelection(_:)), "plain E is still Archive")
        XCTAssertTrue(NSApp.responds(to: NSSelectorFromString("startDictation:")))
        XCTAssertTrue(NSApp.validateUserInterfaceItem(dictation), "dictation is offered")
        XCTAssertTrue(NSApp.validateUserInterfaceItem(emoji), "the character viewer is offered")
    }

    // MARK: Helpers

    /// Spelling as you type, grammar off (the composer's choice), the user's own text replacement and autocorrection
    /// settings untouched, and Writing Tools not turned off.
    private func assertWritingAids(_ text: NSTextView, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(text.isEditable, name, file: file, line: line)
        XCTAssertTrue(text.isContinuousSpellCheckingEnabled, "\(name) checks spelling as you type", file: file, line: line)
        XCTAssertFalse(text.isGrammarCheckingEnabled, "\(name) leaves grammar off", file: file, line: line)
        XCTAssertEqual(text.isAutomaticTextReplacementEnabled, NSSpellChecker.isAutomaticTextReplacementEnabled,
                       "\(name) follows the user's Text Replacement setting", file: file, line: line)
        XCTAssertEqual(text.isAutomaticSpellingCorrectionEnabled, NSSpellChecker.isAutomaticSpellingCorrectionEnabled,
                       "\(name) follows the user's Correct Spelling Automatically setting", file: file, line: line)
        XCTAssertNotEqual(text.writingToolsBehavior, .none, "\(name) offers Writing Tools", file: file, line: line)
        XCTAssertTrue(text.responds(to: NSSelectorFromString("showWritingTools:")), name, file: file, line: line)
    }

    private func newComposer(_ harness: MainWindowHarness) throws -> (ComposeWindowController, NSWindow) {
        let composer = ComposeWindowController(client: harness.environment.engine, account: ListTestSupport.accountA,
                                               accounts: [ListTestSupport.accountA, ListTestSupport.accountB], mode: .new)
        let window = try XCTUnwrap(composer.window)
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        return (composer, window)
    }

    private static func descendants(of view: NSView?) -> [NSView] {
        guard let view else { return [] }
        return view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}

/// A stand-in for an item AppKit adds to Edit: AppKit keeps an fn-only shortcut on its own items and drops it from any
/// other, so the stand-in reports it.
private final class SystemKeyMenuItem: NSMenuItem {
    override var keyEquivalentModifierMask: NSEvent.ModifierFlags {
        get { .function }
        set {}
    }
}
