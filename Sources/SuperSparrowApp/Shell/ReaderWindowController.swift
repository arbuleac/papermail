import AppKit
import SSCore
import SSDesign
import WebKit

/// A conversation in a window of its own (spec §5.49), for reading beside a composer: the reader alone, without the split,
/// under the main window's chrome so its header's first row sits on the lights' centre line (§3.2). Its web view comes
/// from a pool of one of its own, outside the main window's: the window is one more WebContent process.
///
/// The main window that opened it owns it and takes its mail actions, by the rules of the view the conversation was opened
/// from (Later and Unsubscribe included). The undo history and the toast are the app's (`MailUndoCenter`): a step taken
/// here toasts here and is undone here, and a step that takes the conversation off the desk (E, #, !, L, Unsubscribe, M
/// where it archives, a confirmed Discard Draft…) closes the window, its toast in the main window and its undo opening the
/// window again while Z still reaches the step (a deeper ⌘Z brings the conversation back in the main window instead); so
/// does Send and Archive from its quick reply, its countdown going to an undo-send panel. Esc, once nothing else in the
/// window takes it, closes the window as ⌘W does while its quick reply holds none of the user's work (§6.1), the way Esc
/// closes an untouched composer; only a fresh press does, never the key's repeat, so holding Esc down cannot close one
/// window after another.
@MainActor
final class ReaderWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, KeyboardRouterTarget {
    private static let sizeDefaultsKey = "ReaderWindowSize"
    /// How far each new window sits down and right of the one it cascades from, about as far as document windows cascade.
    /// Placed by hand rather than by `cascadeTopLeft(from:)`, so the step is the same whichever window it starts from.
    private static let cascadeStep: CGFloat = 22

    let place: ReaderWindowPlace
    /// The reader; internal so the app's tests can read what it shows.
    let conversation: ConversationViewController
    /// Where the toast of a step taken here shows: the reader's bottom centre, above the quick reply.
    let toastView = ToastView()
    private let undoCenter: MailUndoCenter
    /// The main window's settings: the reader's own Text size (⌘+, ⌘−) is the app's, so every reader follows it (§4.15).
    private let settings: AppSettings
    private weak var opener: MainWindowController?
    private var router: KeyboardRouter?
    private var hasClosed = false

    var conversationID: ConversationID { place.conversation }

    /// `drafts` is the mailbox's quick-reply text, shared with the main window's reader: what is typed here outlives the
    /// window, for the window an undo opens again or the main window showing the conversation. `findSession` is Find in
    /// conversation's last query, the main window's (§5.50). `settings` are the main window's, whose reader Text size this
    /// window's reader follows (spec §4.15).
    init(place: ReaderWindowPlace, client: MailClient, accountsByID: [AccountID: Account], drafts: QuickReplyDraftShelf,
         findSession: FindSession, settings: AppSettings, undoCenter: MailUndoCenter, opener: MainWindowController) {
        self.place = place
        self.undoCenter = undoCenter
        self.settings = settings
        self.opener = opener
        conversation = ConversationViewController(client: client, poolSize: 1, drafts: drafts, settings: settings, findSession: findSession)
        conversation.accountsByID = accountsByID
        conversation.mailboxView = place.view
        let size = Self.savedSize() ?? QuireWindowChrome.readerWindowDefaultSize
        let window = ReaderWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: QuireWindowChrome.mainStyleMask,
                                  backing: .buffered, defer: false)
        QuireWindowChrome.configureReaderWindow(window, title: "")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        window.contentViewController = ReaderWindowContentController(conversation: conversation, toastView: toastView)
        // Setting the content controller sizes the window to the content's own fitting size.
        window.setContentSize(size)
        // The lights share the header's first row here: the kicker starts where minimal mode's masthead does, clear of them.
        conversation.header.kickerMinX = QuireWindowChrome.metrics(of: window).mastheadMinimalX
        wire()
        place.window = self
        conversation.show(place.conversation)
        updateTitle()
        let router = KeyboardRouter(target: self)
        router.install()
        self.router = router
        // The page takes the keyboard when the window first shows, so Space, N and P act on it at once. Otherwise AppKit
        // picks the first key view, which may be the quick reply's field, and single keys would start as text.
        window.initialFirstResponder = conversation.pool.current?.webView
    }

    required init?(coder: NSCoder) {
        nil
    }

    private func wire() {
        conversation.onAction = { [weak self, weak opener] action in
            if let self {
                self.handle(action)
            } else if case .attachmentsSaved = action {
                // The window closed, and this controller went with it, while a download started from it went on (its
                // task holds the reader): the saved toast, Show in Finder or Couldn't save, shows in the main window.
                opener?.handle(action)
            }
        }
        conversation.onQuickSendChange = { UndoSendPanel.refreshUndoKeyOwner() }
        conversation.messageMenu = { [weak self] in self?.contextMenu() }
        conversation.isDraftInComposer = { ComposeWindowRegistry.shared.controller(holdingDraft: $0) != nil }
        conversation.onBottomOverlayChange = { [weak self] in self?.window?.contentView?.needsLayout = true }
        conversation.onMessagesChange = { [weak self] in self?.updateTitle() }
        conversation.onQuickSendArchived = { [weak self] in
            guard let self else { return }
            self.opener?.quickReplyArchived(in: self)
        }
    }

    /// The window is named by its subject (§5.49: the Window menu, Mission Control and VoiceOver), read again whenever the
    /// reader's messages are: one opened while its mail was still out of every view (an undo's window, say) takes the
    /// subject once the mail is back. A conversation that empties keeps the name it had.
    private func updateTitle() {
        guard let window else { return }
        let messages = conversation.currentMessages
        guard !messages.isEmpty || window.title.isEmpty else { return }
        let subject = RenderPayloadBuilder.subject(of: messages).trimmingCharacters(in: .whitespacesAndNewlines)
        window.title = subject.isEmpty ? "No subject" : subject
    }

    // MARK: Placing

    /// Puts the window at `frame` (reopened by an undo), else one cascade step down and right of `anchor` (the last reader
    /// window, or the main window), kept on the anchor's screen.
    func place(at frame: NSRect?, cascadingFrom anchor: NSWindow?) {
        guard let window else { return }
        if let frame {
            window.setFrame(frame, display: false)
            return
        }
        guard let anchor else {
            window.center()
            return
        }
        var origin = NSPoint(x: anchor.frame.minX + Self.cascadeStep, y: anchor.frame.maxY - Self.cascadeStep - window.frame.height)
        if let visible = anchor.screen?.visibleFrame {
            origin.x = max(visible.minX, min(origin.x, visible.maxX - window.frame.width))
            origin.y = max(visible.minY, min(origin.y, visible.maxY - window.frame.height))
        }
        window.setFrameOrigin(origin)
    }

    private static func savedSize() -> NSSize? {
        // A snapshot draws the default size, whatever size the user left a reader window at.
        guard !LaunchOptions().isWindowSnapshot, let stored = UserDefaults.standard.string(forKey: sizeDefaultsKey) else { return nil }
        let size = NSSizeFromString(stored)
        let minimum = QuireWindowChrome.readerWindowMinimumSize
        guard size.width >= minimum.width, size.height >= minimum.height else { return nil }
        return size
    }

    private func saveSize() {
        guard !LaunchOptions().isWindowSnapshot, let content = window?.contentView?.bounds.size else { return }
        UserDefaults.standard.set(NSStringFromSize(content), forKey: Self.sizeDefaultsKey)
    }

    // MARK: State

    /// Move to Inbox took the conversation out of the view it was opened from, or its undo put it back: its keys, menus and
    /// header now treat it as a row of `view` (from the Trash to the Inbox, Archive in place of Move to Inbox).
    func conversationMoved(to view: MailboxView) {
        place.view = view
        conversation.mailboxView = view
    }

    private var isStarred: Bool { conversation.currentMessages.contains(where: \.isStarred) }
    private var hasUnread: Bool { conversation.currentMessages.contains { !$0.isRead } }
    private var showsMessages: Bool { !conversation.currentMessages.isEmpty }

    /// The conversation is in the Trash: opened from it, or every message there now, whichever window put it there. The
    /// header reads it the same way (§5.12), so it, the menus and # agree: Star · Move to Inbox, and no Move to Trash.
    private var isInTrash: Bool {
        place.view == .trash || (showsMessages && conversation.currentMessages.allSatisfy { $0.roles.contains(.trash) })
    }

    /// ! applies (spec, Mark as spam (Q2.3)): not to what is in the Trash or Drafts, as in the main window.
    private var marksSpam: Bool {
        showsMessages && !isInTrash && place.view != .drafts
    }

    /// The message R, A and F answer: the reader's target, else the latest.
    private var replyTarget: MessageID? {
        conversation.selectedMessageID ?? conversation.currentMessages.last?.id
    }

    // MARK: Actions

    private func handle(_ action: ConversationAction) {
        switch action {
        case .escapeQuickReply(let repeated):
            // §6.1: this window's toast takes the first Esc (row 7), held down or not. The next closes the window over an
            // empty bar (row 10), a fresh press only, and over one holding the user's work gives the page the keyboard, the
            // bar keeping it (row 11); a repeat does neither.
            if undoCenter.toasts.isVisible(in: toastView) {
                undoCenter.toasts.dismiss()
            } else if repeated {
                return
            } else if !conversation.quickReplyHoldsWork {
                closeAfterThisKey()
            } else {
                conversation.leaveQuickReply()
            }
        default:
            opener?.perform(action, from: self)
        }
    }

    private func reply(all: Bool) {
        guard let target = replyTarget else { return }
        opener?.perform(all ? .replyAll(target) : .reply(target), from: self)
    }

    // MARK: KeyboardRouterTarget

    var keyboardWindow: NSWindow? { window }
    /// Everything here is the reader: arrows scroll the page, and ← is Esc only while there is something for it to close.
    var isReaderFocused: Bool { true }
    var showsLater: Bool { opener?.showsLater ?? false }
    /// The toast's overlay, between the header and the quick reply: the HUD takes the toast's place, 16 pt above the bar
    /// (§5.32, §5.49). The window has no sync line to clear, and its content view's bottom is under the quick reply.
    var sequenceHUDHost: NSView? { toastView }
    var sequenceHUDBottomInset: CGFloat { Quire.Layout.Toast.aboveSyncLine }
    func sequenceHUDWillAppear() { undoCenter.toasts.dismiss(in: toastView) }
    var cheatSheetWindow: NSWindow? { opener?.keyboardWindow }

    func perform(_ command: KeyCommand) -> Bool {
        guard let opener else { return false }
        let id = conversationID
        switch command {
        case .next, .previous, .extendNext, .extendPrevious, .open, .openInWindow:
            // No list to move in or open from: the key goes on to the page (↩ presses a focused elision mark there).
            return false
        case .archive:
            opener.perform(.archive(id), from: self)
        case .trash:
            // In the Trash # does nothing, quietly (§5.12).
            if !isInTrash { opener.perform(.trash(id), from: self) }
        case .markSpam:
            // Where the main window refuses it (the Trash, Drafts) it beeps, as there.
            if marksSpam { opener.perform(.applyToSelection(.markSpam, [id]), from: self) } else { NSSound.beep() }
        case .toggleMute:
            opener.toggleMute(from: self)
        case .toggleStar:
            opener.perform(.star(id, !isStarred), from: self)
        case .toggleRead:
            opener.perform(.applyToSelection(.setRead(hasUnread), [id]), from: self)
        case .moveToInbox:
            opener.perform(.moveToInbox(id), from: self)
        case .later:
            opener.showLaterMenu(for: self)
        case .reply, .replyAll:
            let all = command == .replyAll
            if !conversation.focusQuickReply(all: all) { reply(all: all) }
        case .forward:
            guard let target = replyTarget else { return false }
            opener.perform(.forward(target), from: self)
        case .compose:
            opener.composeNew()
        case .search:
            opener.comeForward()
            opener.focusSearchField(nil)
        case .clearSearch:
            // §6.1: this window's toast first, then an open find bar, then an open list of recipients with focus in it;
            // then the window closes, unless its quick reply holds the user's work, when Esc does nothing (no beep).
            if !closeForEscape(foldingAddresses: true), !conversation.quickReplyHoldsWork {
                window?.performClose(nil)
            }
        case .escapeRepeat:
            // Esc held down: its repeats still take the rows before the window's (toast, find bar, recipients), as they
            // always have, but never close the window (§6.1 row 10), and are spent quietly, without a beep.
            _ = closeForEscape(foldingAddresses: true)
        case .back:
            // There is no list to go back to: ← closes what Esc would, and otherwise is the page's (a chip's or a
            // Download button's ← →, a recipient's in an open list, the reply tabs, a wide body's scroll).
            return closeForEscape(foldingAddresses: false)
        case .undo:
            // The router acts only outside text, so typing is never ⌘Z's target here; Z never cancels a send.
            let commandZ = NSApp.currentEvent?.modifierFlags.contains(.command) == true
            undoCenter.perform(commandZ ? undoCenter.commandZTarget(textCanUndo: false) : undoCenter.zTarget, typing: window?.undoManager)
        case .goTo(let view):
            opener.goTo(view)
        }
        return true
    }

    /// Esc in the quick reply over an empty bar (§6.1 row 10): the window closes as ⌘W and the close button close it, on
    /// the next turn of the run loop, once the field the key was typed in, which goes with the window, has done with it
    /// (as Send and Archive from the bar closes it, `MainWindowController.quickReplyArchived(in:)`).
    private func closeAfterThisKey() {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.hasClosed, !self.conversation.quickReplyHoldsWork else { return }
                self.window?.performClose(nil)
            }
        }
    }

    /// This window's toast, else an open find bar, else (for Esc, never ←, which moves along the recipients there) an open
    /// list of recipients with focus in it. False when none was there.
    private func closeForEscape(foldingAddresses: Bool) -> Bool {
        if undoCenter.toasts.isVisible(in: toastView) {
            undoCenter.toasts.dismiss(in: toastView)
            return true
        }
        if conversation.closeFindForEscape() { return true }
        return foldingAddresses && conversation.foldAddressesForEscape()
    }

    // MARK: Edit › Undo (§6.1)

    /// Row 1 of §6.1: a text view or field has focus and its undo manager can undo.
    private var textCanUndo: Bool {
        KeyboardRouter.isTextInput(window?.firstResponder) && window?.undoManager?.canUndo == true
    }

    func performEditUndo() {
        undoCenter.perform(undoCenter.commandZTarget(textCanUndo: textCanUndo), typing: window?.undoManager)
    }

    func validateEditUndo(_ item: NSMenuItem) -> Bool {
        let target = undoCenter.commandZTarget(textCanUndo: textCanUndo)
        item.title = undoCenter.undoMenuTitle(for: target, typing: window?.undoManager)
        return target != .nothing
    }

    // MARK: Menu actions (first responder)

    // The Message menu's selectors, answered for this window's conversation (§5.35).
    @objc func archiveSelection(_ sender: Any?) { _ = perform(.archive) }
    @objc func laterSelection(_ sender: Any?) { _ = perform(.later) }
    @objc func snoozeSelectionUntil(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let date = LaterMenu.date(of: item) else { return }
        opener?.snooze(from: self, until: date)
    }
    @objc func pickSnoozeDate(_ sender: Any?) { opener?.pickSnoozeDate(for: self) }
    @objc func trashSelection(_ sender: Any?) { _ = perform(.trash) }
    @objc func markSelectionSpam(_ sender: Any?) { _ = perform(.markSpam) }
    @objc func toggleMuteSelection(_ sender: Any?) { _ = perform(.toggleMute) }
    @objc func alwaysArchiveSender(_ sender: Any?) { setSenderRule(.archive) }
    @objc func blockSender(_ sender: Any?) { setSenderRule(.trash) }
    @objc func moveSelectionToInbox(_ sender: Any?) { _ = perform(.moveToInbox) }
    @objc func toggleStarSelection(_ sender: Any?) { _ = perform(.toggleStar) }
    @objc func markSelectionUnread(_ sender: Any?) { _ = perform(.toggleRead) }
    @objc func replyToSelection(_ sender: Any?) { reply(all: false) }
    @objc func replyAllToSelection(_ sender: Any?) { reply(all: true) }
    @objc func forwardSelection(_ sender: Any?) {
        guard let target = replyTarget else { return }
        opener?.perform(.forward(target), from: self)
    }
    /// Message › Undo (Z): the latest toast's action, never a send (§6.1).
    @objc func undoMailAction(_ sender: Any?) { undoCenter.perform(undoCenter.zTarget, typing: nil) }
    @objc func unsubscribeFromConversation(_ sender: Any?) {
        guard let target = conversation.unsubscribeTarget else {
            NSSound.beep()
            return
        }
        opener?.perform(.unsubscribe(target), from: self)
    }
    /// Find… (⌘F) searches the mailbox: the main window comes forward with its field.
    @objc func focusSearchField(_ sender: Any?) {
        opener?.comeForward()
        opener?.focusSearchField(sender)
    }

    /// View › Inbox, Starred and the rest act in the main window, which comes forward on that view, as the G-sequences
    /// listed beside them do here (§5.49).
    @objc func goToMailboxView(_ sender: Any?) {
        opener?.comeForward()
        opener?.goToMailboxView(sender)
    }

    /// View › All Inboxes and the accounts (⌘0 to ⌘9): the main window comes forward on that account.
    @objc func selectAccountShortcut(_ sender: Any?) {
        opener?.comeForward()
        opener?.selectAccountShortcut(sender)
    }

    @objc func nextMessage(_ sender: Any?) { conversation.nextMessage(sender) }
    @objc func previousMessage(_ sender: Any?) { conversation.previousMessage(sender) }
    @objc func toggleQuotedText(_ sender: Any?) { conversation.toggleQuotedText(sender) }
    @objc func loadImages(_ sender: Any?) { conversation.loadImages(sender) }
    @objc func toggleOriginalColors(_ sender: Any?) { conversation.toggleOriginalColors(sender) }
    @objc func saveAttachments(_ sender: Any?) { conversation.saveAttachments(sender) }
    @objc func downloadAttachments(_ sender: Any?) { conversation.downloadAttachments(sender) }
    @objc func printConversation(_ sender: Any?) { conversation.printConversation(sender) }
    @objc func findInConversation(_ sender: Any?) { conversation.findInConversation(sender) }
    @objc func findNextMatch(_ sender: Any?) { conversation.findNextMatch(sender) }
    @objc func findPreviousMatch(_ sender: Any?) { conversation.findPreviousMatch(sender) }
    /// View › Make Text Bigger and Make Text Smaller (⌘+, ⌘−): the reader's own size, the app's, so this window, the main
    /// window's reader and every other reader window step together (spec §4.15).
    @objc func makeReaderTextBigger(_ sender: Any?) { settings.stepReaderTextSize(larger: true) }
    @objc func makeReaderTextSmaller(_ sender: Any?) { settings.stepReaderTextSize(larger: false) }

    /// Always Archive Mail from This Sender and Block Sender from this window's menus: the sender of its target message, or
    /// of its newest mail from someone else, as in the main window (spec, Sender rules (Q4.2)).
    private func setSenderRule(_ action: SenderRule.Action) {
        guard let target = conversation.senderRuleTarget else {
            NSSound.beep()
            return
        }
        opener?.perform(.senderRule(action, target.id), from: self)
    }

    private static let readerCommands: Set<Selector> = [
        #selector(nextMessage(_:)), #selector(previousMessage(_:)), #selector(toggleQuotedText(_:)), #selector(loadImages(_:)),
        #selector(toggleOriginalColors(_:)), #selector(saveAttachments(_:)), #selector(downloadAttachments(_:)),
        #selector(printConversation(_:)), #selector(findInConversation(_:)), #selector(findNextMatch(_:)),
        #selector(findPreviousMatch(_:)),
    ]

    /// The same rules as the main window's for one selected conversation, read from the view it was opened from.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let typing = KeyboardRouter.isTextInput(window?.firstResponder)
        if let action = menuItem.action, Self.readerCommands.contains(action) {
            return conversation.validateMenuItem(menuItem)
        }
        switch menuItem.action {
        case #selector(archiveSelection(_:)):
            return !typing && showsMessages
        case #selector(laterSelection(_:)), #selector(snoozeSelectionUntil(_:)), #selector(pickSnoozeDate(_:)):
            return !typing && (opener?.canSnooze(in: self) ?? false)
        case #selector(toggleStarSelection(_:)):
            menuItem.title = isStarred ? "Unstar" : "Star"
            return !typing && showsMessages
        case #selector(trashSelection(_:)):
            // Already in Trash (§5.12); an emptied conversation keeps Trash (§5.19).
            return !typing && !isInTrash
        case #selector(markSelectionSpam(_:)):
            return !typing && marksSpam
        case #selector(makeReaderTextBigger(_:)):
            return settings.readerSize.larger != nil
        case #selector(makeReaderTextSmaller(_:)):
            return settings.readerSize.smaller != nil
        case #selector(toggleMuteSelection(_:)):
            menuItem.title = MailActionCopy.muteCommand(muting: !(opener?.isMuted(conversationID) ?? false))
            return !typing && showsMessages
        case #selector(alwaysArchiveSender(_:)), #selector(blockSender(_:)):
            // Mail from someone else is open; the rule its sender has is checked and has nothing to do.
            let action: SenderRule.Action = menuItem.action == #selector(blockSender(_:)) ? .trash : .archive
            guard let target = conversation.senderRuleTarget else {
                menuItem.state = .off
                return false
            }
            let current = conversation.senderRule(for: target)
            menuItem.state = current == action ? .on : .off
            return current != action
        case #selector(moveSelectionToInbox(_:)):
            // Everything opened from the Inbox is there already, unless it has gone to the Trash since.
            return !typing && showsMessages && (place.view != .inbox || isInTrash)
        case #selector(markSelectionUnread(_:)):
            menuItem.title = hasUnread ? "Mark as Read" : "Mark as Unread"
            return showsMessages
        case #selector(replyToSelection(_:)), #selector(replyAllToSelection(_:)), #selector(forwardSelection(_:)):
            return showsMessages
        case #selector(undoMailAction(_:)):
            let target = undoCenter.zTarget
            menuItem.title = undoCenter.undoMenuTitle(for: target, typing: nil)
            return !typing && target != .nothing
        case #selector(unsubscribeFromConversation(_:)):
            return conversation.unsubscribeTarget != nil
        case #selector(focusSearchField(_:)):
            return opener?.keyboardWindow != nil
        case #selector(goToMailboxView(_:)), #selector(selectAccountShortcut(_:)):
            // As the main window answers them, which is where they act.
            return opener?.validateMenuItem(menuItem) ?? false
        default:
            return true
        }
    }

    /// The context menu on a message's chrome (§5.35): the rows' menu, acting on this window's conversation.
    func contextMenu() -> NSMenu {
        let menu = NSMenu(title: "Conversation")
        let later = NSMenuItem(title: "Later", action: nil, keyEquivalent: "")
        later.image = QuireSymbol.image(Quire.Icon.later, size: .inText, accessibilityDescription: nil)
        later.submenu = opener?.laterMenu(target: self)
        later.isEnabled = opener?.canSnooze(in: self) ?? false
        let items: [NSMenuItem] = [
            MainMenu.item("Reply", #selector(replyToSelection(_:)), "r", [], symbol: Quire.Icon.reply, target: self),
            MainMenu.item("Reply All", #selector(replyAllToSelection(_:)), "a", [], symbol: Quire.Icon.replyAll, target: self),
            MainMenu.item("Forward", #selector(forwardSelection(_:)), "f", [], symbol: Quire.Icon.forward, target: self),
            .separator(),
            MainMenu.item("Archive", #selector(archiveSelection(_:)), "e", [], symbol: Quire.Icon.archive, target: self),
            later,
            MainMenu.item("Star", #selector(toggleStarSelection(_:)), "s", [], symbol: Quire.Icon.star, target: self),
            MainMenu.item("Mark as Unread", #selector(markSelectionUnread(_:)), "u", [], symbol: Quire.Icon.markUnread, target: self),
            MainMenu.item("Mute", #selector(toggleMuteSelection(_:)), "m", [], symbol: Quire.Icon.mute, target: self),
            MainMenu.item("Move to Inbox", #selector(moveSelectionToInbox(_:)), "I", [.shift], symbol: Quire.Icon.moveToInbox, target: self),
            .separator(),
            MainMenu.item("Move to Trash", #selector(trashSelection(_:)), "#", [], symbol: Quire.Icon.trash, target: self),
            MainMenu.item("Mark as Spam", #selector(markSelectionSpam(_:)), "!", [], symbol: Quire.Icon.spam, target: self),
        ]
        items.forEach(menu.addItem)
        // As the main window's: Unsubscribe where a list wrote, the sender rules where someone other than the user did.
        let unsubscribes = conversation.unsubscribeTarget != nil
        let setsRules = conversation.senderRuleTarget != nil
        if unsubscribes || setsRules {
            menu.addItem(.separator())
        }
        if unsubscribes {
            menu.addItem(MainMenu.item("Unsubscribe", #selector(unsubscribeFromConversation(_:)), "u", [.command, .shift], target: self))
        }
        if setsRules {
            menu.addItem(MainMenu.item(MailActionCopy.senderRuleCommand(.archive), #selector(alwaysArchiveSender(_:)),
                                       symbol: Quire.Icon.alwaysArchiveSender, target: self))
            menu.addItem(MainMenu.item(MailActionCopy.senderRuleCommand(.trash), #selector(blockSender(_:)),
                                       symbol: Quire.Icon.blockSender, target: self))
        }
        return menu
    }

    // MARK: NSWindowDelegate

    func windowDidEndLiveResize(_ notification: Notification) {
        saveSize()
    }

    /// The window goes, by the user or by a step that took its conversation away: its reader lets go of the conversation
    /// (a quick reply still counting down moves to an undo-send panel, §5.18; the text in the box is parked with the
    /// mailbox's, for the next reader to show the conversation; replies past their undo window go on being watched by the
    /// main window's reader), its toast ends (its undo keeps its grace), and the main window forgets it. The place stays in
    /// the undo history for the step's undo.
    func windowWillClose(_ notification: Notification) {
        guard !hasClosed else { return }
        hasClosed = true
        saveSize()
        conversation.handOffQuickSend()
        undoCenter.toasts.dismiss(in: toastView)
        router?.uninstall()
        router = nil
        conversation.show(nil)
        if place.window === self { place.window = nil }
        let watched = conversation.handOffWatchedSends()
        if let opener {
            opener.readerWindowDidClose(self, watching: watched)
        } else {
            // No main window to watch them: their failures are the window's settler's, at the next launch if need be (§5.53).
            for id in watched.keys { SendOwnership.release(id) }
        }
    }
}

/// A reader window. Edit › Undo, which NSWindow would give to its undo manager alone, follows the app's undo order
/// (§6.1: typing, then sends and toasts) through its controller, as the main window's does.
@MainActor
final class ReaderWindow: NSWindow {
    @objc func undo(_ sender: Any?) {
        if let controller = windowController as? ReaderWindowController {
            controller.performEditUndo()
        } else {
            undoManager?.undo()
        }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(undo(_:)), let controller = windowController as? ReaderWindowController {
            return controller.validateEditUndo(menuItem)
        }
        return super.validateMenuItem(menuItem)
    }
}

/// The window's content: the reader filling it, on the desk, with the toast's overlay over it.
@MainActor
private final class ReaderWindowContentController: NSViewController {
    private let conversation: ConversationViewController
    private let toastView: ToastView

    init(conversation: ConversationViewController, toastView: ToastView) {
        self.conversation = conversation
        self.toastView = toastView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = ReaderWindowDeskView(frame: NSRect(origin: .zero, size: QuireWindowChrome.readerWindowDefaultSize))
        addChild(conversation)
        let content = conversation.view
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        root.addSubview(toastView)
        root.toastView = toastView
        root.bottomOverlay = { [weak conversation] in conversation?.bottomOverlayHeight ?? 0 }
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: root.topAnchor),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }
}

/// The reader desk, `canvas`, and the toast's overlay laid over the reader between its header and its quick reply, so a
/// toast sits at the reader's bottom centre above the bar (§5.49).
@MainActor
private final class ReaderWindowDeskView: NSView {
    weak var toastView: NSView?
    var bottomOverlay: () -> CGFloat = { 0 }

    override var isOpaque: Bool { true }
    override var isFlipped: Bool { true }
    /// Below the title-bar zone a click never drags the window (§3.2); the header drags its own zone.
    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Increase Contrast changes `canvas` without an appearance change (QuireEnvironment).
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    @objc private func environmentDidChange(_ note: Notification) {
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        let top = Quire.Layout.ReaderHeader.height
        toastView?.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top - bottomOverlay()))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qCanvas.setFill()
        dirtyRect.intersection(bounds).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
