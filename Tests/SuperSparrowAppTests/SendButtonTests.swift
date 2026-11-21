import AppKit
import SSCore
@testable import SSDesign
import XCTest
@testable import SuperSparrowApp

/// Send as a split button (spec §5.20, §5.23, §5.18): the composer's bar is Send, Attach and Format on one centre line and
/// the status, with no loose keycap and no Write control; Send's two segments do what Send and Send Options did; the
/// drop-down shows, beside each choice, the key that does it in either default, the same keys the Message menu holds; a key
/// pressed while the drop-down is open sends as its row says and never changes the choice; and the quick reply's Send is
/// the same button. Drafts go to a temporary folder, settings to throwaway defaults, the windows are a throwaway store's.
@MainActor
final class SendButtonTests: XCTestCase {
    private var folder: URL!
    private var suites: [String] = []
    private var savedUndoWindow: TimeInterval = 5

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SuperSparrowSendButton-\(UUID().uuidString)")
        self.folder = folder
        MainActor.assumeIsolated {
            ComposeDraftStore.shared.useDirectory(folder)
            savedUndoWindow = ComposeWindowController.undoWindow
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            ComposeWindowController.undoWindow = savedUndoWindow
            for panel in ComposeWindowRegistry.shared.livePanels { panel.orderOut(nil); ComposeWindowRegistry.shared.unregister(panel) }
            for composer in ComposeWindowRegistry.shared.openControllers { composer.closeWithoutSaving() }
            ComposeDraftStore.shared.waitForWrites()
            ComposeDraftStore.shared.useDemoDirectory(false)
            for suite in suites { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            suites = []
        }
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    // MARK: Helpers

    /// A window over a throwaway store whose settings choose `action`.
    private func harness(_ action: SendAction = .sendAndArchive) throws -> (harness: MainWindowHarness, settings: AppSettings) {
        let suite = "SuperSparrowAppTests.SendButton.\(UUID().uuidString)"
        suites.append(suite)
        let settings = AppSettings(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        settings.sendAction = action
        return (try MainWindowHarness(settings: settings), settings)
    }

    /// A new message to Ben with a subject and a line, so Send can send.
    private func composer(_ harness: MainWindowHarness) throws -> ComposeWindowController {
        let link = MailtoLink(to: [EmailAddress(name: "Ben Carter", address: "ben@contoso.test")], subject: "Lunch?", body: "Noon")
        let composer = try XCTUnwrap(harness.controller.openMailLink(link))
        composer.window?.contentView?.layoutSubtreeIfNeeded()
        return composer
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    /// The Message menu's item for `action`, from the app's own menu bar.
    private func messageItem(_ action: Selector) throws -> NSMenuItem {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
        let message = try XCTUnwrap(bar.items.first { $0.submenu?.title == "Message" }?.submenu)
        return try XCTUnwrap(message.items.first { $0.action == action })
    }

    private func key(_ item: NSMenuItem) -> String {
        item.keyEquivalent.isEmpty ? "" : "\(item.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask).rawValue)\(item.keyEquivalent)"
    }

    /// A key-down of ⌘↩ (or ⇧⌘↩), made the application's current event as the open menu's tracking makes it.
    private func makeCurrent(shift: Bool, in window: NSWindow?) throws -> NSEvent {
        let flags: NSEvent.ModifierFlags = shift ? [.command, .shift] : .command
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                   windowNumber: window?.windowNumber ?? 0, context: nil, characters: "\r",
                                                   charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        NSApp.postEvent(event, atStart: true)
        let current = NSApp.nextEvent(matching: .keyDown, until: .distantPast, inMode: .default, dequeue: true)
        XCTAssertNotNil(current)
        XCTAssertEqual(NSApp.currentEvent?.type, .keyDown)
        return try XCTUnwrap(current)
    }

    // MARK: The bar

    /// Send, then Attach and Format, then the status: nothing else in the bar, no loose “⌘↩”, no Write control; every control
    /// centred on the bar's middle; Attach and Format tell their keys.
    func testTheBarIsSendAttachFormatAndTheStatusOnOneCentreLine() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let composer = try composer(harness)
        let bar = composer.content.bottomBar
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.subviews.map(ObjectIdentifier.init), [bar.send, bar.attachButton, bar.formatButton, bar.statusView].map(ObjectIdentifier.init))
        XCTAssertFalse(descendants(of: bar).contains { ($0 as? QuireButton)?.title == "Write" || $0.accessibilityLabel() == "Write with Help Me Write" },
                       "Help me write has no control in the bar: it is in the body's text")
        XCTAssertTrue(descendants(of: bar).allSatisfy { !($0 is QuireKeycap) }, "no loose keycap: ⌘↩ is on Send's face")
        XCTAssertEqual(bar.sendButton.keycap, "⌘↩")

        let middle = bar.bounds.midY
        let send = bar.convert(bar.send.faceRect, from: bar.send)
        let attach = bar.convert(bar.attachButton.faceRect, from: bar.attachButton)
        let format = bar.convert(bar.formatButton.faceRect, from: bar.formatButton)
        for face in [send, attach, format] { XCTAssertEqual(face.midY, middle, accuracy: 0.5, "one centre line") }
        XCTAssertEqual(send.height, attach.height, "the split button is as tall as the icon buttons")
        XCTAssertEqual(send.minX, Quire.Layout.Composer.barPadX)
        XCTAssertEqual(attach.minX - send.maxX, Quire.Layout.Composer.barGroupGap)
        XCTAssertEqual(format.minX - attach.maxX, Quire.Layout.Composer.barIconGap)
        XCTAssertEqual(bar.attachButton.toolTip, "Attach Files…  ⇧⌘A")
        XCTAssertEqual(bar.formatButton.toolTip, "Show Format Row  ⇧⌘T")
        XCTAssertEqual(bar.sendOptionsButton.toolTip, "Send Options")
        XCTAssertEqual(bar.sendButton.accessibilityHelp(), "⌘Return", "VoiceOver hears the key the face shows")
        XCTAssertEqual(bar.sendOptionsButton.accessibilityLabel(), "Send Options")
        XCTAssertEqual(bar.sendOptionsButton.accessibilityRole(), .menuButton)
    }

    /// Send's segments do what Send and its drop-down did: the action sends, the chevron hangs the options; the Tab loop
    /// meets them in that order, then Attach.
    func testTheSegmentsDoWhatSendAndSendOptionsDid() throws {
        ComposeWindowController.undoWindow = 0
        let (harness, _) = try harness()
        defer { harness.close() }
        let composer = try composer(harness)
        let bar = composer.content.bottomBar
        XCTAssertTrue(bar.sendButton.target === composer)
        XCTAssertEqual(bar.sendButton.action, #selector(ComposeWindowController.send(_:)))
        XCTAssertTrue(bar.sendOptionsButton.target === composer)
        XCTAssertEqual(bar.sendOptionsButton.action, NSSelectorFromString("showSendOptions:"))
        XCTAssertTrue(bar.sendButton.nextKeyView === bar.sendOptionsButton)
        XCTAssertTrue(bar.sendOptionsButton.nextKeyView === bar.attachButton)

        bar.sendButton.performClick(nil)
        XCTAssertTrue(ListTestSupport.spin(until: { (try? harness.environment.store.pendingSends().isEmpty) == false }, timeout: 5),
                      "a click on the action sends")
    }

    // MARK: The drop-down's keys

    /// The keys beside the choices are the keys that do them now, the Message menu's own: with Send and Archive chosen,
    /// ⌘↩ beside it and none beside Send (no key only sends then); with Send chosen, ⌘↩ beside Send and ⇧⌘↩ beside Send and
    /// Archive. Send Later's heading names ⇧⌘L. In the quick reply the same.
    func testTheDropDownShowsTheKeyThatDoesEachChoiceInEitherDefault() throws {
        let send = try messageItem(#selector(ComposeWindowController.send(_:)))
        let both = try messageItem(#selector(ComposeWindowController.sendAndArchive(_:)))
        let later = try messageItem(#selector(ComposeWindowController.sendLater(_:)))
        XCTAssertEqual(SendActionMenu.laterKey, "⇧⌘L")
        XCTAssertEqual(later.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertEqual(later.keyEquivalent, "l")

        for chosen in SendAction.allCases {
            let (harness, _) = try harness(chosen)
            defer { harness.close() }
            let composer = try composer(harness)
            let thread = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
            harness.list.selectedConversationID = thread
            harness.list.onSelectionChange?(thread)
            harness.spin { harness.reader.currentConversationID == thread }
            for menu in [composer.sendOptionsMenu(), harness.reader.quickReplyBar.sendOptionsMenu()] {
                let rows = Array(menu.items.prefix(2))
                XCTAssertEqual(rows.map(\.title), ["Send and Archive", "Send"])
                let checked = try XCTUnwrap(rows.first { $0.state == .on })
                XCTAssertEqual(checked.title, chosen.title)
                XCTAssertEqual(key(checked), key(send), "the checked choice: ⌘↩, Message › Send's key")
                let other = try XCTUnwrap(rows.first { $0.state == .off })
                switch chosen {
                case .sendAndArchive:
                    XCTAssertEqual(key(other), "", "Send has no key while Send and Archive is chosen")
                case .send:
                    XCTAssertEqual(key(other), key(both), "⇧⌘↩, Message › Send and Archive's key")
                }
                let heading = try XCTUnwrap(menu.items.first(where: \.isSectionHeader))
                XCTAssertEqual(heading.title, "Send Later  ⇧⌘L")
                XCTAssertTrue(menu.items.filter { !rows.contains($0) }.allSatisfy { $0.keyEquivalent.isEmpty })
            }
        }
    }

    /// The menu answers its keys while it is open: ⇧⌘↩ there takes Send and Archive's row, and sends and archives as the
    /// row says, rather than making it the default; ⌘↩ takes the checked row and sends as Send does. A click, or Return on a
    /// highlighted row, still only chooses.
    func testAKeyPressedInTheOpenDropDownSendsAsItsRowSaysAndChoosesNothing() throws {
        ComposeWindowController.undoWindow = 0
        let (harness, settings) = try harness(.send)
        defer { harness.close() }
        let composer = try composer(harness)
        let menu = composer.sendOptionsMenu()
        let event = try makeCurrent(shift: true, in: composer.window)
        XCTAssertTrue(SendActionMenu.isKeyEquivalent(event, of: menu.items[0]), "Send and Archive's row answers ⇧⌘↩")
        XCTAssertFalse(SendActionMenu.isKeyEquivalent(event, of: menu.items[1]))
        XCTAssertTrue(menu.performKeyEquivalent(with: event), "the open menu's row takes its key")
        XCTAssertEqual(settings.sendAction, .send, "the choice stays")
        XCTAssertTrue(ListTestSupport.spin(until: { (try? harness.environment.store.pendingSends().isEmpty) == false }, timeout: 5),
                      "it sent")

        // A click (or Return, which carries no ⌘) only chooses.
        let plain = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                   context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                                                   keyCode: 36))
        XCTAssertFalse(SendActionMenu.isKeyEquivalent(plain, of: menu.items[1]))
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: .command, timestamp: 0,
                                                     windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
        XCTAssertFalse(SendActionMenu.isKeyEquivalent(click, of: menu.items[1]), "a ⌘-click is a click")
        let keyUp = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0,
                                                   context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                                                   keyCode: 36))
        XCTAssertTrue(SendActionMenu.isKeyEquivalent(keyUp, of: menu.items[1]), "the key-up that ends the menu's tracking counts too")
    }

    // MARK: The quick reply

    /// The quick reply's Send is the composer's button, small: the same words and keycap, no glyph; trailing in the tool row,
    /// centred on it like its tools; its key hides with the reader's keycaps in a narrow reader.
    func testTheQuickReplysSendIsTheSameButton() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let composer = try composer(harness)
        let thread = try XCTUnwrap(harness.list.conversations.first { $0.id.providerID == "thread-2" }?.id)
        harness.list.selectedConversationID = thread
        harness.list.onSelectionChange?(thread)
        harness.spin { harness.reader.currentConversationID == thread }
        XCTAssertTrue(harness.reader.focusQuickReply(all: false))
        let bar = harness.reader.quickReplyBar
        bar.text = "Thanks"
        bar.layoutSubtreeIfNeeded()
        let split = bar.sendSplitButton
        let big = composer.content.bottomBar.send
        XCTAssertEqual(split.size, .small)
        XCTAssertEqual(big.size, .regular)
        XCTAssertEqual(split.actionSegment.title, big.actionSegment.title)
        XCTAssertNil(split.actionSegment.symbolName, "the tool row is tight and the rest glyph is the plane already")
        XCTAssertEqual(big.actionSegment.symbolName, Quire.Icon.send)
        XCTAssertEqual(split.actionSegment.keycap, "⌘↩")
        XCTAssertEqual(split.actionSegment.accessibilityHelp(), "⌘Return")
        XCTAssertEqual(split.menuSegment.accessibilityLabel(), "Send Options")
        XCTAssertFalse(split.isHidden)
        XCTAssertTrue(bar.sendControlsEnabled.send)
        XCTAssertFalse(descendants(of: bar).contains { $0 is QuireKeycap && !$0.isHidden && $0.accessibilityLabel() == "⌘↩" },
                       "no loose ⌘↩ beside it")
        let face = bar.convert(split.faceRect, from: split)
        let attach = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? QuireIconButton }.first { $0.accessibilityLabel() == "Attach" })
        XCTAssertEqual(face.midY, bar.convert(attach.faceRect, from: attach).midY, accuracy: 0.5, "on the tools' centre line")
    }
}
