import AppKit
import SSCore
import SSDesign

/// The menu bar (spec §5.35): system menus with Quire content. Items carry their symbol, title-case names and
/// their shortcut, single keys included (“Archive  E”), so nothing is learnable only from the cheat sheet.
/// Mail commands target the first responder so they reach the main window controller, the reader or a
/// composer; app-level commands target the app delegate. Items that do not apply stay visible, disabled.
///
/// Single-key shortcuts belong to `KeyboardRouter`, which acts only outside text fields; the menu bar shows
/// them but never matches them (`MainMenuBar`), so typing “e” in a field can never archive.
@MainActor
enum MainMenu {
    static func build(appDelegate: AppDelegate) -> NSMenu {
        let main = MainMenuBar()
        main.addItem(submenu(appMenu(appDelegate)))
        main.addItem(submenu(fileMenu(appDelegate)))
        let edit = editMenu()
        main.addItem(submenu(edit.menu))
        let view = viewMenu(appDelegate)
        main.addItem(submenu(view))
        let message = messageMenu()
        main.addItem(submenu(message.menu))
        let format = submenu(formatMenu())
        main.addItem(format)
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
        MainMenuController.shared = MainMenuController(mainWindowItems: message.mainWindow + [edit.searchServer],
                                                       composerItems: message.composer,
                                                       formatItem: format, viewMenu: view, appDelegate: appDelegate)
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    private static func menu(_ title: String) -> NSMenu {
        let menu = MainMenuBar(title: title)
        return menu
    }

    /// One item. `key` with no modifiers is a single-key shortcut, shown in the menu and handled by
    /// `KeyboardRouter`.
    static func item(
        _ title: String,
        _ action: Selector?,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command,
        symbol: String? = nil,
        target: AnyObject? = nil,
        tag: Int = 0
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        item.tag = tag
        if let symbol { item.image = QuireSymbol.image(symbol, size: .inText, accessibilityDescription: nil) }
        return item
    }

    /// A G-sequence item: two keys cannot be a key equivalent, so they are set as right-aligned shortcut text.
    private static func sequenceItem(_ title: String, keys: String, symbol: String, tag: Int) -> NSMenuItem {
        let item = item(title, #selector(MainWindowController.goToMailboxView(_:)), "", [], symbol: symbol, tag: tag)
        let font = NSFont.menuFont(ofSize: 0)
        let style = NSMutableParagraphStyle()
        style.tabStops = [NSTextTab(textAlignment: .right, location: sequenceColumn)]
        let text = NSMutableAttributedString(string: title, attributes: [.font: font, .paragraphStyle: style])
        text.append(NSAttributedString(string: "\t" + keys, attributes: [.font: font, .paragraphStyle: style,
                                                                          .foregroundColor: NSColor.secondaryLabelColor]))
        item.attributedTitle = text
        return item
    }

    /// Where the G-sequence keys end: past the View menu's longest title and its native shortcut column.
    private static var sequenceColumn: CGFloat {
        let font = NSFont.menuFont(ofSize: 0)
        let widest = ["Show Account Rail", "Check for New Mail", "Original Colors"]
            .map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max() ?? 120
        return ceil(widest) + 64
    }

    private static func appMenu(_ delegate: AppDelegate) -> NSMenu {
        let menu = menu("SuperSparrow")
        menu.addItem(item("About SuperSparrow", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(AppDelegate.showSettings(_:)), ",", symbol: Quire.Icon.settings, target: delegate))
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
        let menu = menu("File")
        menu.addItem(item("New Message", #selector(AppDelegate.newMessage(_:)), "n", symbol: Quire.Icon.compose, target: delegate))
        menu.addItem(item("Close Window", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(.separator())
        menu.addItem(item("Add Gmail Account…", #selector(AppDelegate.addGmailAccount(_:)), symbol: Quire.Icon.addAccountProvider,
                          target: delegate))
        menu.addItem(item("Add Microsoft Account…", #selector(AppDelegate.addMicrosoftAccount(_:)), symbol: Quire.Icon.addAccountProvider,
                          target: delegate))
        menu.addItem(.separator())
        // The reader saves the target message's attachments (spec §5.17).
        menu.addItem(item("Save Attachments…", #selector(MainWindowController.saveAttachments(_:)), symbol: Quire.Icon.attach))
        // Shown only in demo mode: the app delegate reveals it when it installs a demo environment.
        let leaveDemo = item("Leave Demo…", #selector(AppDelegate.leaveDemo(_:)), symbol: Quire.Icon.undo, target: delegate)
        leaveDemo.isHidden = true
        menu.addItem(leaveDemo)
        return menu
    }

    /// `searchServer` is the main window's: hidden while a composer is key, so its ⌘↩ never stands in for Send.
    private static func editMenu() -> (menu: NSMenu, searchServer: NSMenuItem) {
        let menu = menu("Edit")
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
        menu.addItem(item("Find…", #selector(MainWindowController.focusSearchField(_:)), "f", symbol: Quire.Icon.search))
        // Titled by the scope when it validates (“Search Gmail for More”, §5.10); ⌘↩ in the search field.
        let searchServer = item(ServerSearchRow.menuTitle(for: nil), #selector(MainWindowController.searchServer(_:)), "\r")
        menu.addItem(searchServer)
        // The text system's own submenus, acting on whichever text view has focus. Without them spelling, text
        // replacement and smart quotes could be switched only from a text view's context menu. Writing Tools, AutoFill,
        // Start Dictation and Emoji & Symbols are not built here: AppKit adds them at launch to the menu titled "Edit"
        // that holds Cut, Copy and Paste.
        menu.addItem(submenu(spellingMenu()))
        menu.addItem(submenu(substitutionsMenu()))
        menu.addItem(submenu(transformationsMenu()))
        menu.addItem(submenu(speechMenu()))
        return (menu, searchServer)
    }

    private static func spellingMenu() -> NSMenu {
        let menu = menu("Spelling and Grammar")
        menu.addItem(item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"))
        menu.addItem(item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"))
        menu.addItem(.separator())
        menu.addItem(item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))))
        menu.addItem(item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:))))
        menu.addItem(item("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))))
        return menu
    }

    private static func substitutionsMenu() -> NSMenu {
        let menu = menu("Substitutions")
        menu.addItem(item("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:))))
        menu.addItem(item("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))))
        menu.addItem(item("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))))
        menu.addItem(item("Smart Links", #selector(NSTextView.toggleAutomaticLinkDetection(_:))))
        menu.addItem(item("Data Detectors", #selector(NSTextView.toggleAutomaticDataDetection(_:))))
        menu.addItem(item("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:))))
        return menu
    }

    private static func transformationsMenu() -> NSMenu {
        let menu = menu("Transformations")
        menu.addItem(item("Make Upper Case", #selector(NSResponder.uppercaseWord(_:))))
        menu.addItem(item("Make Lower Case", #selector(NSResponder.lowercaseWord(_:))))
        menu.addItem(item("Capitalize", #selector(NSResponder.capitalizeWord(_:))))
        return menu
    }

    private static func speechMenu() -> NSMenu {
        let menu = menu("Speech")
        menu.addItem(item("Start Speaking", #selector(NSTextView.startSpeaking(_:))))
        menu.addItem(item("Stop Speaking", #selector(NSTextView.stopSpeaking(_:))))
        return menu
    }

    private static func viewMenu(_ delegate: AppDelegate) -> NSMenu {
        let menu = menu("View")
        let views: [(MailboxView, String, String, String)] = [
            (.inbox, "Inbox", "G I", Quire.Icon.viewInbox), (.later, "Later", "G L", Quire.Icon.viewLater),
            (.starred, "Starred", "G S", Quire.Icon.viewStarred),
            (.sent, "Sent", "G T", Quire.Icon.viewSent), (.drafts, "Drafts", "G D", Quire.Icon.viewDrafts),
            (.trash, "Trash", "G #", Quire.Icon.viewTrash), (.all, "All Mail", "G A", Quire.Icon.viewAllMail),
        ]
        for (view, title, keys, symbol) in views {
            let item = sequenceItem(title, keys: keys, symbol: symbol, tag: MailboxView.allCases.firstIndex(of: view) ?? 0)
            // Listed only while something in the main window's scope is snoozed (MainMenuController), as the rail's tile.
            item.isHidden = view == .later
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(item("All Inboxes", #selector(MainWindowController.selectAccountShortcut(_:)), "0", symbol: Quire.Icon.unifiedInbox,
                          tag: 0))
        for number in 1...9 {
            // Retitled with the account's name and hidden past the last account (MainMenuController). Hidden
            // items keep their shortcut, so an account added since the menu last opened still answers ⌘n; the
            // main window's validation decides whether that account exists.
            let account = item("Account \(number)", #selector(MainWindowController.selectAccountShortcut(_:)), "\(number)", tag: number)
            account.allowsKeyEquivalentWhenHidden = true
            menu.addItem(account)
        }
        menu.addItem(.separator())
        menu.addItem(item("Check for New Mail", #selector(AppDelegate.checkForNewMail(_:)), "n", [.command, .shift],
                          symbol: Quire.Icon.retry, target: delegate))
        menu.addItem(item("Hide Account Rail", #selector(MainWindowController.toggleAccountStrip(_:)), "s", [.command, .control],
                          symbol: Quire.Icon.toggleRail))
        menu.addItem(item("Compact Rows", #selector(AppDelegate.toggleCompactRows(_:)), "c", [.command, .option], target: delegate))
        menu.addItem(.separator())
        menu.addItem(item("Load Images", #selector(MainWindowController.loadImages(_:)), "i", [.command, .shift], symbol: Quire.Icon.loadImages))
        menu.addItem(item("Original Colors", #selector(MainWindowController.toggleOriginalColors(_:)), "o", [.command, .shift],
                          symbol: Quire.Icon.originalColors))
        menu.addItem(item("Show Quoted Text", #selector(MainWindowController.toggleQuotedText(_:)), ".", [], symbol: Quire.Icon.quotedText))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    /// The Message menu holds the main window's commands, or a composer's when a composer is key (§5.35).
    private static func messageMenu() -> (menu: NSMenu, mainWindow: [NSMenuItem], composer: [NSMenuItem]) {
        let menu = menu("Message")
        let main: [NSMenuItem] = [
            item("Reply", #selector(MainWindowController.replyToSelection(_:)), "r", [], symbol: Quire.Icon.reply),
            item("Reply All", #selector(MainWindowController.replyAllToSelection(_:)), "a", [], symbol: Quire.Icon.replyAll),
            item("Forward", #selector(MainWindowController.forwardSelection(_:)), "f", [], symbol: Quire.Icon.forward),
            .separator(),
            item("Archive", #selector(MainWindowController.archiveSelection(_:)), "e", [], symbol: Quire.Icon.archive),
            item("Later…", #selector(MainWindowController.laterSelection(_:)), "l", [], symbol: Quire.Icon.later),
            item("Move to Trash", #selector(MainWindowController.trashSelection(_:)), "#", [], symbol: Quire.Icon.trash),
            item("Move to Inbox", #selector(MainWindowController.moveSelectionToInbox(_:)), "I", [.shift], symbol: Quire.Icon.moveToInbox),
            item("Star", #selector(MainWindowController.toggleStarSelection(_:)), "s", [], symbol: Quire.Icon.star),
            item("Mark as Unread", #selector(MainWindowController.markSelectionUnread(_:)), "u", [], symbol: Quire.Icon.markUnread),
            item("Undo", #selector(MainWindowController.undoMailAction(_:)), "z", [], symbol: Quire.Icon.undo),
            .separator(),
            item("Unsubscribe", #selector(MainWindowController.unsubscribeFromConversation(_:)), "u", [.command, .shift]),
            .separator(),
            item("Next Message", #selector(MainWindowController.nextMessage(_:)), "n", []),
            item("Previous Message", #selector(MainWindowController.previousMessage(_:)), "p", []),
        ]
        let composer: [NSMenuItem] = [
            item("Send", #selector(ComposeWindowController.send(_:)), "\r", symbol: Quire.Icon.send),
            item("Attach Files…", #selector(ComposeWindowController.attachFile(_:)), "a", [.command, .shift], symbol: Quire.Icon.attach),
            item("Add Cc Field", #selector(ComposeWindowController.addCcField(_:)), "c", [.command, .shift]),
            item("Add Bcc Field", #selector(ComposeWindowController.addBccField(_:)), "b", [.command, .shift]),
            .separator(),
            item("Discard Draft…", #selector(ComposeWindowController.discardDraft(_:)), symbol: Quire.Icon.discardDraft),
        ]
        for entry in main + composer { menu.addItem(entry) }
        return (menu, main, composer)
    }

    /// Composer windows only (§5.35); the items act on the composer's text view.
    private static func formatMenu() -> NSMenu {
        let menu = menu("Format")
        menu.addItem(item("Show Format Row", #selector(ComposeWindowController.toggleFormatRow(_:)), "t", [.command, .shift],
                          symbol: Quire.Icon.format))
        menu.addItem(.separator())
        menu.addItem(item("Bold", #selector(ComposeWindowController.toggleBold(_:)), "b", symbol: Quire.Icon.bold))
        menu.addItem(item("Italic", #selector(ComposeWindowController.toggleItalic(_:)), "i", symbol: Quire.Icon.italic))
        menu.addItem(item("Underline", #selector(ComposeWindowController.toggleUnderline(_:)), "u", symbol: Quire.Icon.underline))
        menu.addItem(.separator())
        menu.addItem(item("Bulleted List", #selector(ComposeWindowController.toggleBulletList(_:)), "8", [.command, .shift],
                          symbol: Quire.Icon.bulletedList))
        menu.addItem(item("Numbered List", #selector(ComposeWindowController.toggleNumberedList(_:)), "7", [.command, .shift],
                          symbol: Quire.Icon.numberedList))
        menu.addItem(item("Quote", #selector(ComposeWindowController.toggleBlockQuote(_:)), "'", symbol: Quire.Icon.blockQuote))
        menu.addItem(.separator())
        menu.addItem(item("Add Link…", #selector(ComposeWindowController.insertLink(_:)), "k", symbol: Quire.Icon.link))
        return menu
    }

    #if DEBUG
    /// Tools for checking the app's own drawing; nothing here touches mail. Debug builds only.
    private static func debugMenu(_ delegate: AppDelegate) -> NSMenu {
        let menu = menu("Debug")
        menu.addItem(item("Design Gallery", #selector(AppDelegate.showDesignGallery(_:)), target: delegate))
        return menu
    }
    #endif

    private static func windowMenu() -> NSMenu {
        let menu = menu("Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp))
        return menu
    }

    private static func helpMenu(_ delegate: AppDelegate) -> NSMenu {
        let menu = menu("Help")
        menu.addItem(item("Keyboard Shortcuts", #selector(AppDelegate.showKeyboardHelp(_:)), "/", symbol: Quire.Icon.keyboard, target: delegate))
        return menu
    }
}

/// A menu that never matches a key equivalent without ⌘, ⌃ or ⌥. Single-key shortcuts are shown in the menus
/// but performed by `KeyboardRouter`, which knows when focus is in a text field; matched here, “e” typed in
/// the search field would archive.
@MainActor
final class MainMenuBar: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if !event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            return super.performKeyEquivalent(with: event)
        }
        // The Globe-key items AppKit adds to Edit (Emoji & Symbols fn-E, Start Dictation fn-D) carry only fn, and
        // must keep working in text fields. NSMenu ignores fn when it matches, so fn-E would reach Archive's plain
        // E through `super`; those keys are matched exactly instead, once, from the top of the bar.
        guard self === NSApp.mainMenu, event.modifierFlags.contains(.function), event.specialKey == nil else { return false }
        return Self.performExactly(event, in: self)
    }

    /// `KeyboardRouter`'s way to the single-key items (N, P, . and the rest): the visible item whose key
    /// equivalent is exactly this key with no ⌘, ⌃ or ⌥, performed only when it validates, so a disabled item
    /// lets the key go on to the responder chain.
    static func performSingleKey(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty, let bar = NSApp.mainMenu else { return false }
        return performExactly(event, in: bar)
    }

    private static func performExactly(_ event: NSEvent, in menu: NSMenu) -> Bool {
        guard let item = exactItem(for: event, in: menu), let action = item.action,
              let target = NSApp.target(forAction: action, to: item.target, from: item) as AnyObject? else { return false }
        if let validator = target as? NSMenuItemValidation {
            guard validator.validateMenuItem(item) else { return false }
        } else if let validator = target as? NSUserInterfaceValidations {
            guard validator.validateUserInterfaceItem(item) else { return false }
        }
        return NSApp.sendAction(action, to: target, from: item)
    }

    /// The item whose key equivalent and modifiers are exactly the event's, depth first. Shift counts for
    /// letters (an uppercase equivalent implies it) and is ignored for symbols it produces (# is ⇧3).
    static func exactItem(for event: NSEvent, in menu: NSMenu) -> NSMenuItem? {
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()
        guard !key.isEmpty else { return nil }
        let significant: NSEvent.ModifierFlags = [.command, .control, .option, .shift, .function]
        var pressed = event.modifierFlags.intersection(significant)
        // Arrows and function keys always carry fn; only a fn chord (Globe-E) means it.
        if event.specialKey != nil { pressed.remove(.function) }
        for item in menu.items {
            if let submenu = item.submenu {
                if let found = exactItem(for: event, in: submenu) { return found }
                continue
            }
            guard !item.keyEquivalent.isEmpty, !item.isHidden || item.allowsKeyEquivalentWhenHidden else { continue }
            var mask = item.keyEquivalentModifierMask.intersection(significant)
            let equivalent = item.keyEquivalent
            let isLetter = equivalent.unicodeScalars.allSatisfy { CharacterSet.letters.contains($0) }
            if isLetter, equivalent != equivalent.lowercased() { mask.insert(.shift) }
            var flags = pressed
            if !isLetter, !mask.contains(.shift) { flags.remove(.shift) }
            if equivalent.lowercased() == key, mask == flags { return item }
        }
        return nil
    }
}

/// Keeps the menus in step with the key window and the accounts: the Message menu's composer items and the
/// Format menu show only while a composer is key, View's ⌘1…⌘9 items carry the accounts' names, and View's Later
/// shows while the rail's Later tile does.
@MainActor
final class MainMenuController: NSObject, NSMenuDelegate {
    static var shared: MainMenuController?

    private let mainWindowItems: [NSMenuItem]
    private let composerItems: [NSMenuItem]
    private let formatItem: NSMenuItem
    private weak var appDelegate: AppDelegate?
    private var observers: [NSObjectProtocol] = []

    init(mainWindowItems: [NSMenuItem], composerItems: [NSMenuItem], formatItem: NSMenuItem, viewMenu: NSMenu, appDelegate: AppDelegate) {
        self.mainWindowItems = mainWindowItems
        self.composerItems = composerItems
        self.formatItem = formatItem
        self.appDelegate = appDelegate
        super.init()
        viewMenu.delegate = self
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { MainMenuController.shared?.updateForKeyWindow() }
            })
        }
        updateForKeyWindow()
    }

    func updateForKeyWindow() {
        let composing = NSApp.keyWindow?.windowController is ComposeWindowController
        for item in mainWindowItems { item.isHidden = composing }
        for item in composerItems { item.isHidden = !composing }
        formatItem.isHidden = !composing
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let laterTag = MailboxView.allCases.firstIndex(of: .later)
        for item in menu.items where item.action == #selector(MainWindowController.goToMailboxView(_:)) && item.tag == laterTag {
            item.isHidden = !(appDelegate?.menuShowsLater ?? false)
        }
        let accounts = appDelegate?.menuAccounts ?? []
        for item in menu.items where item.action == #selector(MainWindowController.selectAccountShortcut(_:)) && item.tag > 0 {
            let index = item.tag - 1
            item.isHidden = index >= accounts.count
            if index < accounts.count { item.title = AccountLabels.name(for: accounts[index]) + " · " + accounts[index].email }
        }
    }
}
