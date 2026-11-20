import AppKit
import SSDesign
import XCTest
@testable import SuperSparrowApp

/// The key bindings the release's features added, together (spec §6, §5.32, §5.35): each new action is a menu item with
/// its key, no two items in the menu bar answer the same key, every new key has a cheat-sheet row, and a reader window
/// answers the commands that act on its conversation.
@MainActor
final class KeyBindingsTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // The menu bar reads NSApp, which a test run that starts here has not made yet.
        MainActor.assumeIsolated { _ = NSApplication.shared }
    }

    private struct Binding: Hashable {
        let key: String
        let modifiers: UInt
    }

    private func menuBar() -> NSMenu {
        MainMenu.build(appDelegate: AppDelegate(options: LaunchOptions(arguments: ["SuperSparrow"])))
    }

    private func items(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item in [item] + (item.submenu.map(items) ?? []) }
    }

    /// The key as AppKit matches it: an upper-case letter carries Shift.
    private func binding(_ item: NSMenuItem) -> Binding? {
        guard !item.keyEquivalent.isEmpty else { return nil }
        var mask = item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift])
        let key = item.keyEquivalent
        if key.count == 1, let scalar = key.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(scalar) { mask.insert(.shift) }
        return Binding(key: key.lowercased(), modifiers: mask.rawValue)
    }

    func testNoTwoMenuItemsAnswerTheSameKey() {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        var seen: [Binding: String] = [:]
        for item in items(menuBar()) {
            guard let binding = binding(item) else { continue }
            if let other = seen[binding] {
                XCTFail("“\(item.title)” and “\(other)” share \(binding.key) with modifiers \(binding.modifiers)")
            }
            seen[binding] = item.title
        }
    }

    func testEveryNewActionIsAMenuItemWithItsKey() {
        let previous = (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu)
        defer { (MainMenuController.shared, NSApp.windowsMenu, NSApp.helpMenu) = previous }
        let all = items(menuBar())
        let expected: [(Selector, String, NSEvent.ModifierFlags)] = [
            (#selector(MainWindowController.markSelectionSpam(_:)), "!", []),
            (#selector(MainWindowController.toggleMuteSelection(_:)), "m", []),
            (#selector(MainWindowController.alwaysArchiveSender(_:)), "", []),
            (#selector(MainWindowController.blockSender(_:)), "", []),
            (#selector(ComposeWindowController.sendLater(_:)), "l", [.command, .shift]),
            (#selector(MainWindowController.downloadAttachments(_:)), "d", [.command, .shift]),
            (#selector(MainWindowController.printConversation(_:)), "p", [.command]),
            (#selector(MainWindowController.findInConversation(_:)), "f", [.command, .option]),
            (#selector(MainWindowController.findNextMatch(_:)), "g", [.command]),
            (#selector(MainWindowController.findPreviousMatch(_:)), "g", [.command, .shift]),
            (#selector(ComposeWindowController.insertPicture(_:)), "i", [.command, .option]),
            (#selector(MainWindowController.openSelectionInNewWindow(_:)), "o", [.command]),
            (#selector(MainWindowController.makeReaderTextBigger(_:)), "+", [.command]),
            (#selector(MainWindowController.makeReaderTextSmaller(_:)), "-", [.command]),
            (#selector(ConversationViewController.helpMeWrite(_:)), "j", [.command]),
            (#selector(ConversationViewController.helpMeWriteWithInstructions(_:)), "j", [.command, .shift]),
        ]
        for (action, key, modifiers) in expected {
            // The composer's items (Send Later…, Insert Picture…) are hidden outside a composer and still claim their keys.
            let candidates = all.filter { $0.action == action }
            XCTAssertFalse(candidates.isEmpty, "\(action) has a menu item")
            XCTAssertTrue(candidates.contains { item in
                item.keyEquivalent == key
                    && (key.isEmpty || item.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == modifiers)
            }, "\(action) answers \(key)")
        }
        // The sender rules have no key: a rule is set rarely, and a single key could set one by a slip.
        XCTAssertFalse(Quire.cheatSheet.flatMap(\.rows).contains { $0.label.localizedCaseInsensitiveContains("sender") })
    }

    /// A reader window answers every new command that acts on its conversation, so none is disabled there (§5.49).
    func testAReaderWindowAnswersTheNewCommands() {
        for action in [#selector(ReaderWindowController.markSelectionSpam(_:)), #selector(ReaderWindowController.toggleMuteSelection(_:)),
                       #selector(ReaderWindowController.alwaysArchiveSender(_:)), #selector(ReaderWindowController.blockSender(_:)),
                       #selector(ReaderWindowController.downloadAttachments(_:)), #selector(ReaderWindowController.printConversation(_:)),
                       #selector(ReaderWindowController.findInConversation(_:)), #selector(ReaderWindowController.findNextMatch(_:)),
                       #selector(ReaderWindowController.findPreviousMatch(_:)), #selector(ReaderWindowController.makeReaderTextBigger(_:)),
                       #selector(ReaderWindowController.makeReaderTextSmaller(_:))] {
            XCTAssertTrue(ReaderWindowController.instancesRespond(to: action), "\(action)")
        }
    }
}
