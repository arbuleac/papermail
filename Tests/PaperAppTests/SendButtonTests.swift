import AppKit
import PaperCore
@testable import PaperDesign
import XCTest
@testable import PaperApp

/// Send as a split button (spec §5.20, §5.23, §5.18): the composer's bar is Send, Attach and Format on one centre line and
/// the status, with no keycap and no Write control; Send's two segments do what Send and Send Options did; the drop-down
/// shows, beside each choice, the key that does it in either default, the same keys the Message menu holds; a key pressed
/// while the drop-down is open sends as its row says and never changes the choice; and the quick reply's Send is the same
/// button, the paper plane on it too, which gives way before Send would reach under the tools. Drafts go to a temporary
/// folder, settings to throwaway defaults, the windows are a throwaway store's.
@MainActor
final class SendButtonTests: XCTestCase {
    private var folder: URL!
    private var suites: [String] = []
    private var savedUndoWindow: TimeInterval = 5

    override func setUp() {
        super.setUp()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PaperSendButton-\(UUID().uuidString)")
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
        let suite = "PaperAppTests.SendButton.\(UUID().uuidString)"
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
        let bar = MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["Paper"])))
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

    /// Send, then Attach and Format, then the status: nothing else in the bar, no keycap on Send or beside it, no Write
    /// control; every control centred on the bar's middle; Attach and Format tell their keys.
    func testTheBarIsSendAttachFormatAndTheStatusOnOneCentreLine() throws {
        let (harness, _) = try harness()
        defer { harness.close() }
        let composer = try composer(harness)
        let bar = composer.content.bottomBar
        bar.layoutSubtreeIfNeeded()
        XCTAssertEqual(bar.subviews.map(ObjectIdentifier.init), [bar.send, bar.attachButton, bar.formatButton, bar.statusView].map(ObjectIdentifier.init))
        XCTAssertFalse(descendants(of: bar).contains { ($0 as? QuireButton)?.title == "Write" || $0.accessibilityLabel() == "Write with Help Me Write" },
                       "Help me write has no control in the bar: it is in the body's text")
        XCTAssertTrue(descendants(of: bar).allSatisfy { !($0 is QuireKeycap) }, "no keycap in the bar")

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
        XCTAssertEqual(bar.sendButton.accessibilityHelp(), "⌘Return", "VoiceOver hears Send's key as its help")
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

    /// The quick reply's Send is the composer's button, small: the same words and paper plane; trailing in the tool row,
    /// centred on it like its tools.
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
        XCTAssertEqual(split.actionSegment.symbolName, Quire.Icon.send, "the composer's paper plane")
        XCTAssertEqual(big.actionSegment.symbolName, Quire.Icon.send)
        XCTAssertEqual(split.actionSegment.accessibilityHelp(), "⌘Return")
        XCTAssertEqual(split.menuSegment.accessibilityLabel(), "Send Options")
        XCTAssertFalse(split.isHidden)
        XCTAssertTrue(bar.sendControlsEnabled.send)
        XCTAssertFalse(descendants(of: bar).contains { $0 is QuireKeycap && !$0.isHidden && $0.accessibilityLabel() == "⌘↩" },
                       "no ⌘↩ beside it")
        let face = bar.convert(split.faceRect, from: split)
        let attach = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? QuireIconButton }.first { $0.accessibilityLabel() == "Attach" })
        XCTAssertEqual(face.midY, bar.convert(attach.faceRect, from: attach).midY, accuracy: 0.5, "on the tools' centre line")
    }

    /// Neither Send carries a keycap (§5.36: none on an accent fill): the composer's and the quick reply's faces are their
    /// paper plane and “Send”, padded on both sides, and nothing else; the key is in the tooltip and VoiceOver's help.
    func testNeitherSendShowsAKeycapAndBothCarryThePlane() throws {
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
        let composerBar = composer.content.bottomBar
        composerBar.layoutSubtreeIfNeeded()
        // A new message only sends, whatever the choice; the reply does what the choice says (§5.23).
        for (name, split, tip) in [("composer", composerBar.send, "Send  ⌘↩"), ("quick reply", bar.sendSplitButton, "Send and Archive  ⌘↩")] {
            XCTAssertFalse(split.isHidden, name)
            XCTAssertTrue(descendants(of: split).allSatisfy { !($0 is QuireKeycap) }, "\(name): no keycap on Send")
            let action = split.actionSegment
            XCTAssertEqual(action.symbolName, Quire.Icon.send, "\(name): the paper plane")
            let glyph = QuireDraw.symbolSize(Quire.Icon.send, size: .custom(split.size.glyph)).width
            let rest = ceil(2 * split.size.padX + glyph + Quire.Layout.Button.glyphGap
                + QuireDraw.width(QuireDraw.line("Send", split.size.strongRole, .black)))
            // The composer's face keeps the gerund's width (“Sending…”), its plane and label centred in it.
            XCTAssertEqual(action.intrinsicContentSize.width, max(rest, action.actionWidth(symbolName: Quire.Icon.send)), name)
            XCTAssertEqual(action.actionWidth(symbolName: Quire.Icon.send), action.intrinsicContentSize.width, name)
            if action.loadingTitle == nil { XCTAssertEqual(action.intrinsicContentSize.width, rest, "\(name): plane, label, padding only") }
            XCTAssertEqual(action.toolTip, tip, "\(name): the tooltip names the key")
            XCTAssertEqual(action.accessibilityHelp(), "⌘Return", name)
        }
        XCTAssertEqual(composerBar.send.size, .regular)
        XCTAssertEqual(bar.sendSplitButton.size, .small)
    }

    /// In the narrowest reader the quick reply's Send keeps its plane and the tools' group gap; where a row is too tight
    /// for the plane (narrower than any reader), the plane gives way first and Send still clears the tools.
    func testTheQuickReplysPlaneGivesWayBeforeSendReachesUnderTheTools() throws {
        let m = Quire.Layout.QuickReply.self
        func layOut(width: CGFloat) throws -> (bar: QuickReplyView, window: NSWindow, send: NSRect, tools: NSRect) {
            let bar = QuickReplyView(frame: NSRect(x: 0, y: 0, width: width, height: 60))
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: width, height: 400), styleMask: [.borderless],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            let content = try XCTUnwrap(window.contentView)
            content.addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
            window.layoutIfNeeded()
            bar.focus()
            // Held open as while its menu shows, so the tool row shows whether or not the offscreen field took focus.
            bar.isHeldOpen = true
            bar.text = "Thanks"
            window.layoutIfNeeded()
            bar.layoutSubtreeIfNeeded()
            let split = bar.sendSplitButton
            XCTAssertFalse(split.isHidden, "\(width): the tool row shows")
            let composer = try XCTUnwrap(descendants(of: bar).compactMap { $0 as? QuireIconButton }
                .first { $0.accessibilityLabel() == "Open in Composer" })
            XCTAssertFalse(composer.isHidden)
            return (bar, window, bar.convert(split.faceRect, from: split), bar.convert(composer.faceRect, from: composer))
        }
        for width in [Quire.Layout.Window.readerMinWidth, Quire.Layout.Window.readerNarrow - 1, Quire.Layout.Window.readerKeycapsMin - 1,
                      Quire.Layout.Window.readerKeycapsMin, 800] {
            let laid = try layOut(width: width)
            defer { laid.window.close() }
            XCTAssertEqual(laid.bar.sendSplitButton.actionSegment.symbolName, Quire.Icon.send, "\(width) pt reader: the plane shows")
            XCTAssertGreaterThanOrEqual(laid.send.minX - laid.tools.maxX, m.toolGroupGap, "\(width) pt reader: Send clears the tools")
            XCTAssertEqual(laid.send.maxX, laid.bar.restGeometry.field.maxX - m.sendInset, accuracy: 0.5)
        }
        // A row just too tight for the plane: it gives way, and Send without it still keeps the gap.
        let widest = try layOut(width: Quire.Layout.Window.readerMinWidth)
        let action = widest.bar.sendSplitButton.actionSegment
        let plane = action.actionWidth(symbolName: Quire.Icon.send) - action.actionWidth(symbolName: nil)
        let spare = widest.send.minX - widest.tools.maxX - m.toolGroupGap
        widest.window.close()
        let tight = try layOut(width: Quire.Layout.Window.readerMinWidth - spare - plane / 2)
        defer { tight.window.close() }
        XCTAssertNil(tight.bar.sendSplitButton.actionSegment.symbolName, "the plane gives way first")
        XCTAssertGreaterThanOrEqual(tight.send.minX - tight.tools.maxX, m.toolGroupGap, "Send never reaches under the tools")
    }
}
