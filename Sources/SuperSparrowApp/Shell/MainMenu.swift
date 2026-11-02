import AppKit
import SSCore

/// The menu bar. Mail commands target the first responder so they reach the main window controller, which
/// validates them (disabled while typing, so plain-letter equivalents never steal keystrokes); app-level
/// commands target the app delegate directly.
@MainActor
enum MainMenu {
    static func build(appDelegate: AppDelegate) -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu(appDelegate)))
        main.addItem(submenu(fileMenu(appDelegate)))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(viewMenu()))
        main.addItem(submenu(messageMenu()))
        #if DEBUG
        // The gallery rewrites app-wide QuireEnvironment overrides while open: a development tool only.
        main.addItem(submenu(debugMenu(appDelegate)))
        #endif
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = helpMenu(appDelegate)
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func item(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command,
        target: AnyObject? = nil,
        tag: Int = 0
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        item.tag = tag
        return item
    }

    private static func appMenu(_ delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "SuperSparrow")
        menu.addItem(item("About SuperSparrow", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: delegate))
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())
        menu.addItem(item("Hide SuperSparrow", #selector(NSApplication.hide(_:)), "h", target: NSApp))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp))
        menu.addItem(.separator())
        menu.addItem(item("Quit SuperSparrow", #selector(NSApplication.terminate(_:)), "q", target: NSApp))
        return menu
    }

    private static func fileMenu(_ delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New Message", #selector(AppDelegate.newMessage(_:)), "n", target: delegate))
        menu.addItem(item("Add Account…", #selector(AppDelegate.addAccountFromMenu(_:)), target: delegate))
        menu.addItem(item("Leave Demo…", #selector(MainWindowController.leaveDemo(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", NSSelectorFromString("undo:"), "z"))
        menu.addItem(item("Redo", NSSelectorFromString("redo:"), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())
        menu.addItem(item("Find…", #selector(MainWindowController.focusSearchField(_:)), "f"))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        menu.addItem(item("All Inboxes", #selector(MainWindowController.selectAccountShortcut(_:)), "0", tag: 0))
        for number in 1...9 {
            menu.addItem(item("Account \(number)", #selector(MainWindowController.selectAccountShortcut(_:)), "\(number)", tag: number))
        }
        menu.addItem(.separator())
        let titles: [MailboxView: String] = [.inbox: "Inbox", .starred: "Starred", .sent: "Sent", .drafts: "Drafts", .trash: "Trash", .all: "All Mail"]
        for (index, view) in MailboxView.allCases.enumerated() {
            menu.addItem(item(titles[view] ?? view.rawValue, #selector(MainWindowController.goToMailboxView(_:)), tag: index))
        }
        menu.addItem(.separator())
        menu.addItem(item("Focused Inbox", #selector(MainWindowController.toggleFocusedInbox(_:)), "\\"))
        for (index, title) in ["All", "Focused", "Other"].enumerated() {
            menu.addItem(item(title, #selector(MainWindowController.selectInboxSection(_:)), "\(index + 1)", .option, tag: index))
        }
        menu.addItem(item("Check for New Mail", #selector(MainWindowController.checkForNewMail(_:)), "n", [.command, .shift]))
        menu.addItem(item("Hide Account Strip", #selector(MainWindowController.toggleAccountStrip(_:)), "s", [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func messageMenu() -> NSMenu {
        let menu = NSMenu(title: "Message")
        menu.addItem(item("Reply", #selector(MainWindowController.replyToSelection(_:)), "r"))
        menu.addItem(item("Reply All", #selector(MainWindowController.replyAllToSelection(_:)), "r", [.command, .shift]))
        menu.addItem(item("Forward", #selector(MainWindowController.forwardSelection(_:)), "f", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Archive", #selector(MainWindowController.archiveSelection(_:)), "e", []))
        menu.addItem(item("Star", #selector(MainWindowController.toggleStarSelection(_:)), "s", []))
        menu.addItem(item("Mark as Unread", #selector(MainWindowController.markSelectionUnread(_:)), "u", [.command, .shift]))
        menu.addItem(item("Move to Trash", #selector(MainWindowController.trashSelection(_:)), "\u{8}"))
        // Plain ⇧I also works outside text fields (see KeyboardRouter); this is the discoverable copy.
        menu.addItem(item("Move to Inbox", #selector(MainWindowController.moveSelectionToInbox(_:)), "i", [.command, .shift]))
        menu.addItem(.separator())
        // ⌘Z is claimed by the keyboard router outside text fields; the menu item shows what it will undo.
        menu.addItem(item("Undo Mail Action", #selector(MainWindowController.undoMailAction(_:)), "z"))
        menu.addItem(.separator())
        // Composer windows only: the responder chain reaches the composer's window controller (spec §5.20).
        let discard = item("Discard Draft…", #selector(ComposeWindowController.discardDraft(_:)))
        discard.image = NSImage(systemSymbolName: "trash", accessibilityDescription: nil)
        menu.addItem(discard)
        return menu
    }

    #if DEBUG
    /// Tools for checking the app's own drawing; nothing here touches mail. Debug builds only.
    private static func debugMenu(_ delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Debug")
        menu.addItem(item("Design Gallery", #selector(AppDelegate.showDesignGallery(_:)), target: delegate))
        return menu
    }
    #endif

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
        return menu
    }

    private static func helpMenu(_ delegate: AppDelegate) -> NSMenu {
        let menu = NSMenu(title: "Help")
        menu.addItem(item("Keyboard Shortcuts", #selector(AppDelegate.showKeyboardHelp(_:)), "/", [.command, .shift], target: delegate))
        menu.addItem(item("Setting Up OAuth…", #selector(AppDelegate.showOAuthHelp(_:)), target: delegate))
        return menu
    }
}
