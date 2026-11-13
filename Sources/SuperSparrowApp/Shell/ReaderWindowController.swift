import AppKit
import SSCore
import SSDesign
import WebKit

/// A conversation in a window of its own (spec §5.19a), for reading beside a composer: the reader alone, without the split,
/// under the main window's chrome so its header's first row sits on the lights' centre line (§3.2). Its web view comes
/// from a pool of one of its own, outside the main window's: the window is one more WebContent process.
///
/// The main window that opened it owns it and takes its mail actions, by the rules of the view the conversation was opened
/// from (Later and Unsubscribe included). The undo history and the toast are the app's (`MailUndoCenter`): a step taken
/// here toasts here and is undone here, and a step that takes the conversation off the desk (E, #, L, Unsubscribe) closes
/// the window, its toast in the main window and its undo opening the window again.
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
    private weak var opener: MainWindowController?
    private var router: KeyboardRouter?
    private var hasClosed = false

    var conversationID: ConversationID { place.conversation }

    init(place: ReaderWindowPlace, client: MailClient, accountsByID: [AccountID: Account], undoCenter: MailUndoCenter,
         opener: MainWindowController) {
        self.place = place
        self.undoCenter = undoCenter
        self.opener = opener
        conversation = ConversationViewController(client: client, poolSize: 1)
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
        let subject = RenderPayloadBuilder.subject(of: conversation.currentMessages).trimmingCharacters(in: .whitespacesAndNewlines)
        window.title = subject.isEmpty ? "No subject" : subject
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
        conversation.onAction = { [weak self] action in self?.handle(action) }
        conversation.onQuickSendChange = { UndoSendPanel.refreshUndoKeyOwner() }
        conversation.messageMenu = { [weak self] in self?.contextMenu() }
        conversation.isDraftInComposer = { ComposeWindowRegistry.shared.controller(holdingDraft: $0) != nil }
        conversation.onBottomOverlayChange = { [weak self] in self?.window?.contentView?.needsLayout = true }
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

    /// Move to Inbox took the conversation out of the view it was opened from: its keys and header now treat it as an Inbox
    /// row (Archive in place of Move to Inbox).
    func conversationMoved(to view: MailboxView) {
        place.view = view
        conversation.mailboxView = view
    }

    private var isStarred: Bool { conversation.currentMessages.contains(where: \.isStarred) }
    private var hasUnread: Bool { conversation.currentMessages.contains { !$0.isRead } }
    private var showsMessages: Bool { !conversation.currentMessages.isEmpty }

    /// The message R, A and F answer: the reader's target, else the latest.
    private var replyTarget: MessageID? {
        conversation.selectedMessageID ?? conversation.currentMessages.last?.id
    }

    // MARK: Actions

    private func handle(_ action: ConversationAction) {
        switch action {
        case .escapeQuickReply:
            // §6.1: this window's toast takes the first Esc; the next gives the page the keyboard, the bar keeping its text.
            if undoCenter.toasts.isVisible(in: toastView) {
                undoCenter.toasts.dismiss()
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
    /// Everything here is the reader: arrows scroll the page and ← is Esc.
    var isReaderFocused: Bool { true }
    var showsLater: Bool { opener?.showsLater ?? false }
    var sequenceHUDHost: NSView? { window?.contentView }
    func sequenceHUDWillAppear() { undoCenter.toasts.dismiss(in: toastView) }
    var cheatSheetWindow: NSWindow? { opener?.keyboardWindow }

    func perform(_ command: KeyCommand) -> Bool {
        guard let opener else { return false }
        let id = conversationID
        switch command {
        case .next, .previous, .extendNext, .extendPrevious, .open:
            // No list to move in or open from: the key goes on to the page (↩ presses a focused elision mark there).
            return false
        case .archive:
            opener.perform(.archive(id), from: self)
        case .trash:
            // In the Trash # does nothing, quietly (§5.12).
            if place.view != .trash { opener.perform(.trash(id), from: self) }
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
            undoCenter.toasts.dismiss(in: toastView)
        case .undo:
            // The router acts only outside text, so typing is never ⌘Z's target here; Z never cancels a send.
            let commandZ = NSApp.currentEvent?.modifierFlags.contains(.command) == true
            undoCenter.perform(commandZ ? undoCenter.commandZTarget(textCanUndo: false) : undoCenter.zTarget, typing: window?.undoManager)
        case .goTo(let view):
            opener.goTo(view)
        }
        return true
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

    @objc func nextMessage(_ sender: Any?) { conversation.nextMessage(sender) }
    @objc func previousMessage(_ sender: Any?) { conversation.previousMessage(sender) }
    @objc func toggleQuotedText(_ sender: Any?) { conversation.toggleQuotedText(sender) }
    @objc func loadImages(_ sender: Any?) { conversation.loadImages(sender) }
    @objc func toggleOriginalColors(_ sender: Any?) { conversation.toggleOriginalColors(sender) }
    @objc func saveAttachments(_ sender: Any?) { conversation.saveAttachments(sender) }

    private static let readerCommands: Set<Selector> = [
        #selector(nextMessage(_:)), #selector(previousMessage(_:)), #selector(toggleQuotedText(_:)), #selector(loadImages(_:)),
        #selector(toggleOriginalColors(_:)), #selector(saveAttachments(_:)),
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
            return !typing && place.view != .trash
        case #selector(moveSelectionToInbox(_:)):
            return !typing && showsMessages && place.view != .inbox
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
            MainMenu.item("Move to Inbox", #selector(moveSelectionToInbox(_:)), "I", [.shift], symbol: Quire.Icon.moveToInbox, target: self),
            .separator(),
            MainMenu.item("Move to Trash", #selector(trashSelection(_:)), "#", [], symbol: Quire.Icon.trash, target: self),
        ]
        items.forEach(menu.addItem)
        if conversation.unsubscribeTarget != nil {
            menu.addItem(.separator())
            menu.addItem(MainMenu.item("Unsubscribe", #selector(unsubscribeFromConversation(_:)), "u", [.command, .shift], target: self))
        }
        return menu
    }

    // MARK: NSWindowDelegate

    func windowDidEndLiveResize(_ notification: Notification) {
        saveSize()
    }

    /// The window goes, by the user or by a step that took its conversation away: its reader lets go of the conversation
    /// (a quick reply still counting down moves to an undo-send panel, §5.18), its toast ends (its undo keeps its grace),
    /// and the main window forgets it. The place stays in the undo history for the step's undo.
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
        opener?.readerWindowDidClose(self)
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
/// toast sits at the reader's bottom centre above the bar (§5.19a).
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
