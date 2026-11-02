import AppKit
import SSCore
import WebKit
import os

/// The main window: account strip, message list and reader in a split view, or the welcome screen when there is
/// nothing to show yet. It owns the selection, routes reader actions and shortcuts, and keeps the undo stack
/// for mail actions.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, KeyboardRouterTarget {
    static let defaultSize = NSSize(width: 1200, height: 760)
    static let minimumSize = NSSize(width: 820, height: 520)
    private static let log = Logger(subsystem: "io.supersparrow.mac", category: "shell")

    let environment: AppEnvironment
    private let settings: AppSettings

    /// Wired by the app delegate, which owns sign-in, settings and environment switching.
    var onAddAccount: ((ProviderKind?) -> Void)?
    var onReconnect: ((Account) -> Void)?
    var onOpenSettings: (() -> Void)?
    var onTryDemo: (() -> Void)?
    var onCancelSignIn: (() -> Void)?

    private let splitController = NSSplitViewController()
    private let strip = AccountStripViewController()
    private let list: MessageListViewController
    private let listPane: ListPaneViewController
    private let conversation: ConversationViewController
    private let conversationPane: ConversationPaneViewController
    private let welcome = WelcomeViewController()
    private var stripItem: NSSplitViewItem!

    private let inboxMonitor: InboxMonitor
    let notifier: NewMailNotifier
    private var router: KeyboardRouter?
    private var statusObservation: StoreObservation?
    private var stripCollapseObservation: NSKeyValueObservation?

    private(set) var accounts: [Account] = []
    private var statuses: [AccountSyncStatus] = []
    private var scope: AccountScope = .unified
    private var mailboxView: MailboxView = .inbox
    private var section: InboxSection?
    private var searchText = ""
    private var undoStack = MailActionUndoStack()
    private var showingWelcome = false

    init(environment: AppEnvironment, settings: AppSettings) {
        self.environment = environment
        self.settings = settings
        list = MessageListViewController(store: environment.store)
        listPane = ListPaneViewController(list: list)
        conversation = ConversationViewController(client: environment.engine)
        conversationPane = ConversationPaneViewController(conversation: conversation)
        inboxMonitor = InboxMonitor(store: environment.store)
        notifier = NewMailNotifier(settings: settings)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = environment.isDemo ? "SuperSparrow — Demo" : "SuperSparrow"
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        super.init(window: window)
        window.delegate = self

        buildSplit()
        wireCallbacks()
        refreshAccounts()
        applyQuery()

        window.contentViewController = showingWelcome ? welcome : splitController
        window.setContentSize(Self.defaultSize)
        window.center()
        // Restores the last frame, which also overrides the centering above after the first run.
        window.setFrameAutosaveName("MainWindow")
        if isFirstSplitLayout {
            splitController.splitView.layoutSubtreeIfNeeded()
            splitController.splitView.setPosition(AccountStripViewController.width + ListPaneViewController.preferredWidth, ofDividerAt: 1)
        }
        // Otherwise AppKit picks the first key view, the search field, and single-key shortcuts start as text.
        window.initialFirstResponder = Self.firstDescendant(of: list.view, as: NSTableView.self)
        // The split view's autosave can bring the strip back collapsed, and dragging the divider can collapse
        // it too; either way the traffic lights then sit over the list header.
        listPane.setClearsTrafficLights(stripItem.isCollapsed)
        stripCollapseObservation = stripItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            let collapsed = item.isCollapsed
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.listPane.setClearsTrafficLights(collapsed) }
            }
        }

        statusObservation = environment.engine.observeStatus { [weak self] statuses in
            MainActor.assumeIsolated { self?.statusesChanged(statuses) }
        }
        inboxMonitor.start(accounts: accounts.map(\.id))
        let router = KeyboardRouter(target: self)
        router.install()
        self.router = router
        NotificationCenter.default.addObserver(self, selector: #selector(composeDraftDiscarded(_:)),
                                               name: ComposeWindowController.draftDiscardedNotification, object: nil)
    }

    /// A composer's Message › Discard Draft… confirms here: “Draft discarded · Undo” (spec §5.20).
    @objc private func composeDraftDiscarded(_ note: Notification) {
        let undo = note.userInfo?[ComposeWindowController.draftUndoKey] as? ComposeDraftUndo
        listPane.toast.show("Draft discarded") { undo?.undo() }
        UndoSendPanel.yieldUndoKey()
    }

    required init?(coder: NSCoder) {
        nil
    }

    /// Releases the observations and the key monitor before the environment behind them shuts down.
    func tearDown() {
        router?.uninstall()
        router = nil
        statusObservation?.cancel()
        statusObservation = nil
        stripCollapseObservation?.invalidate()
        stripCollapseObservation = nil
        inboxMonitor.stop()
        window?.orderOut(nil)
    }

    // MARK: Layout

    private func buildSplit() {
        let splitView = splitController.splitView
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.autosaveName = "MainSplit"

        stripItem = NSSplitViewItem(viewController: strip)
        stripItem.canCollapse = true
        stripItem.holdingPriority = .defaultHigh + 10
        stripItem.minimumThickness = AccountStripViewController.width
        stripItem.maximumThickness = AccountStripViewController.width

        let listItem = NSSplitViewItem(viewController: listPane)
        listItem.minimumThickness = ListPaneViewController.minimumWidth
        listItem.holdingPriority = .defaultLow + 10
        listItem.canCollapse = false

        let readerItem = NSSplitViewItem(viewController: conversationPane)
        readerItem.minimumThickness = ConversationPaneViewController.minimumWidth
        readerItem.holdingPriority = .defaultLow
        readerItem.canCollapse = false

        splitController.splitViewItems = [stripItem, listItem, readerItem]
    }

    /// A first run has no autosaved divider positions; the list then starts at its preferred width.
    private let isFirstSplitLayout = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MainSplit") == nil

    private func wireCallbacks() {
        strip.onSelect = { [weak self] scope in self?.scopeChanged(scope) }
        strip.onAddAccount = { [weak self] in self?.onAddAccount?(nil) }
        strip.onOpenSettings = { [weak self] in self?.onOpenSettings?() }

        listPane.onViewChange = { [weak self] view in self?.setView(view) }
        listPane.onSectionChange = { [weak self] section in
            self?.section = section
            self?.applyQuery()
        }
        listPane.onSearchChange = { [weak self] text in
            self?.searchText = text
            self?.applyQuery()
        }
        listPane.onLeaveSearch = { [weak self] in self?.focusList() }
        listPane.statusBar.onReconnect = { [weak self] id in
            guard let self, let account = self.accounts.first(where: { $0.id == id }) else { return }
            self.onReconnect?(account)
        }

        list.onSelectionChange = { [weak self] id in self?.selectionChanged(id) }
        list.onOpen = { [weak self] id in
            guard let self else { return }
            if self.conversation.currentConversationID != id { self.conversation.show(id) }
            self.focusReader()
        }

        conversation.onAction = { [weak self] action in self?.handle(action) }

        welcome.onAddAccount = { [weak self] kind in self?.onAddAccount?(kind) }
        welcome.onTryDemo = { [weak self] in self?.onTryDemo?() }
        welcome.onCancelSignIn = { [weak self] in self?.onCancelSignIn?() }

        inboxMonitor.onCounts = { [weak self] unified, perAccount in
            self?.strip.setUnreadCounts(unified: unified, perAccount: perAccount)
        }
        inboxMonitor.onRows = { [weak self] rows in
            guard let self else { return }
            self.notifier.inboxDidChange(rows, accounts: self.accountsByID)
        }
        notifier.onOpenConversation = { [weak self] id in self?.reveal(id) }
    }

    // MARK: Accounts and status

    var accountsByID: [AccountID: Account] {
        Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Re-reads the accounts from the store. Called on status changes, which fire whenever an account is added
    /// to or removed from the engine.
    func refreshAccounts() {
        let fresh = ((try? environment.store.accounts()) ?? []).sorted { $0.addedAt < $1.addedAt }
        let changed = fresh != accounts
        accounts = fresh
        if changed {
            let byID = accountsByID
            strip.setAccounts(fresh)
            list.accountsByID = byID
            conversation.accountsByID = byID
            inboxMonitor.updateAccounts(fresh.map(\.id))
        }
        updateWelcome()
    }

    private func updateWelcome() {
        let wantsWelcome = accounts.isEmpty && !environment.isDemo
        guard wantsWelcome != showingWelcome else { return }
        showingWelcome = wantsWelcome
        guard let window, window.contentViewController != nil else { return }
        // Swapping the content controller resizes the window to the new view; keep the user's frame.
        let frame = window.frame
        window.contentViewController = wantsWelcome ? welcome : splitController
        window.setFrame(frame, display: true)
        if !wantsWelcome { focusList() }
    }

    private func statusesChanged(_ statuses: [AccountSyncStatus]) {
        self.statuses = statuses
        refreshAccounts()
        listPane.statusBar.apply(SyncStatusSummary.make(statuses: statuses, accounts: accountsByID))
    }

    /// Shows progress on the welcome screen while a browser sign-in runs.
    func setSignInInProgress(_ message: String?) {
        welcome.setBusy(message)
    }

    // MARK: Query

    private func scopeChanged(_ scope: AccountScope) {
        self.scope = scope
        applyQuery()
    }

    /// Picking a mailbox means "show me that mailbox", so it also ends a search that would otherwise keep
    /// overriding the view.
    private func setView(_ view: MailboxView) {
        mailboxView = view
        if view != .inbox { section = nil }
        endSearch()
        applyQuery()
    }

    private func endSearch() {
        guard !searchText.isEmpty || !listPane.searchText.isEmpty else { return }
        listPane.clearSearch(notify: false)
        searchText = ""
    }

    private func applyQuery() {
        let query = ShellQuery.make(
            scope: scope.accountIDs, view: mailboxView, section: section, searchText: searchText
        )
        if query != list.query {
            // A selection carried into another list would be handed to whatever row replaced it there, and the
            // reader would open (and mark read) a conversation the user never picked.
            if list.selectedConversationID != nil {
                list.selectedConversationID = nil
                conversation.show(nil)
            }
            list.query = query
        }
        listPane.display(view: mailboxView, section: mailboxView == .inbox ? section : nil)
    }

    // MARK: Selection

    private func selectionChanged(_ id: ConversationID?) {
        conversation.show(id)
        guard let id else { return }
        let neighbors = list.neighbors(of: id)
        var seen: Set<ConversationID> = [id]
        let wanted = [neighbors.next, neighbors.previous, neighbors.nextUnread].compactMap { $0 }.filter { seen.insert($0).inserted }
        conversation.prerender(wanted)
    }

    // MARK: Snapshot support

    /// Debug aid for `--snapshot`: selects the first row as a click would.
    @discardableResult
    func selectFirstConversation() -> ConversationID? {
        guard let first = list.conversations.first?.id else { return nil }
        list.selectedConversationID = first
        selectionChanged(first)
        return first
    }

    var hasConversations: Bool { !list.conversations.isEmpty }

    func whenReaderSettles(timeout: TimeInterval, _ completion: @escaping (WKWebView?) -> Void) {
        conversation.whenShownRenderLands(timeout: timeout, completion)
    }

    /// Debug aid for `--snapshot-compose`.
    func openReplyComposer() -> Bool {
        composeReply(all: false)
    }

    /// Brings a conversation on screen from outside the list (a notification click).
    func reveal(_ id: ConversationID) {
        showWindow(nil)
        listPane.clearSearch(notify: false)
        searchText = ""
        scope = .unified
        strip.select(.unified, notify: false)
        mailboxView = .inbox
        section = nil
        applyQuery()
        list.selectedConversationID = id
        selectionChanged(id)
    }

    private var selectedSummary: ConversationSummary? {
        guard let id = list.selectedConversationID else { return nil }
        return list.conversations.first { $0.id == id }
    }

    // MARK: Focus

    private func focusList() {
        guard let table = Self.firstDescendant(of: list.view, as: NSTableView.self) else { return }
        window?.makeFirstResponder(table)
    }

    private func focusReader() {
        let webView = Self.firstDescendant(of: conversation.view, as: WKWebView.self) { !$0.isHiddenOrHasHiddenAncestor }
        if let webView { window?.makeFirstResponder(webView) }
    }

    private static func firstDescendant<T: NSView>(of view: NSView, as type: T.Type, where predicate: (T) -> Bool = { _ in true }) -> T? {
        for subview in view.subviews {
            if let match = subview as? T, predicate(match) { return match }
            if let match = firstDescendant(of: subview, as: type, where: predicate) { return match }
        }
        return nil
    }

    // MARK: KeyboardRouterTarget

    var keyboardWindow: NSWindow? { showingWelcome ? nil : window }

    var isReaderFocused: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: conversationPane.view)
    }

    func perform(_ command: KeyCommand) -> Bool {
        switch command {
        case .next:
            list.selectNext()
            return true
        case .previous:
            list.selectPrevious()
            return true
        case .open:
            guard let id = list.selectedConversationID else { return false }
            list.onOpen?(id)
            return true
        case .archive:
            return mailAction(.archive)
        case .toggleStar:
            guard let summary = selectedSummary else { return false }
            return mailAction(.setStarred(!summary.isStarred))
        case .toggleRead:
            guard let summary = selectedSummary else { return false }
            return mailAction(.setRead(summary.unreadCount > 0))
        case .trash:
            return mailAction(.trash)
        case .reply:
            return composeReply(all: false)
        case .replyAll:
            return composeReply(all: true)
        case .forward:
            return composeForward()
        case .compose:
            composeNew()
            return true
        case .search:
            listPane.focusSearch()
            return true
        case .clearSearch:
            guard !searchText.isEmpty || !listPane.searchText.isEmpty else { return false }
            endSearch()
            applyQuery()
            return true
        case .moveToInbox:
            return moveSelectionToInbox()
        case .undo:
            return undoLastAction()
        case .goTo(let view):
            setView(view)
            return true
        }
    }

    // MARK: Mail actions

    /// Applies a change to the selected conversation, remembers how to undo it and offers Undo in a toast.
    @discardableResult
    private func mailAction(_ change: MetadataChange, on id: ConversationID? = nil) -> Bool {
        guard let id = id ?? list.selectedConversationID else { return false }
        let store = environment.store
        guard let all = try? store.messages(in: id), !all.isEmpty else { return false }
        let kind = accountsByID[id.accountID]?.kind ?? .gmail
        let messages = MailActionRecord.targets(for: change, in: all, kind: kind)
        guard let record = MailActionRecord.make(change, on: messages, conversation: id) else {
            // Archive in the Trash, star on nothing: say so rather than appear to ignore the key.
            NSSound.beep()
            return true
        }
        do {
            try environment.engine.perform(change, on: record.targets)
        } catch {
            Self.log.error("mail action failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return true
        }
        undoStack.push(record)
        listPane.toast.show(record.title) { [weak self] in self?.undoLastAction() }
        UndoSendPanel.yieldUndoKey()
        return true
    }

    /// Brings the selected conversation back to the inbox: out of the trash when it is there, else out of the
    /// archive.
    @discardableResult
    private func moveSelectionToInbox() -> Bool {
        mailAction(.moveToInbox)
    }

    @discardableResult
    private func undoLastAction() -> Bool {
        guard let record = undoStack.pop() else {
            NSSound.beep()
            return true
        }
        do {
            for step in record.inverse {
                try environment.engine.perform(step.change, on: step.targets)
            }
        } catch {
            Self.log.error("undo failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return true
        }
        listPane.toast.show("Undid “\(record.title.lowercased())”", buttonTitle: nil)
        if let id = record.conversation, [.archive, .trash, .moveToInbox, .restoreFromTrash].contains(record.change) {
            // The row comes back; put the selection on it so the user sees what was restored.
            list.selectedConversationID = id
            selectionChanged(id)
        }
        return true
    }

    private func handle(_ action: ConversationAction) {
        switch action {
        case .reply(let id):
            compose(.reply(id, all: false), accountID: id.accountID)
        case .replyAll(let id):
            compose(.reply(id, all: true), accountID: id.accountID)
        case .forward(let id):
            compose(.forward(id), accountID: id.accountID)
        case .archive(let id):
            mailAction(.archive, on: id)
        case .star(let id, let starred):
            mailAction(.setStarred(starred), on: id)
        case .trash(let id):
            mailAction(.trash, on: id)
        case .openAttachment:
            // The reader already opened Quick Look.
            break
        }
    }

    // MARK: Compose

    /// The reader's selected card when the reader shows the selection, else the conversation's latest message.
    private var replyTarget: MessageID? {
        guard let id = list.selectedConversationID else { return nil }
        if conversation.currentConversationID == id {
            return conversation.selectedMessageID ?? conversation.currentMessages.last?.id
        }
        return (try? environment.store.messages(in: id))?.last?.id
    }

    private func composeReply(all: Bool) -> Bool {
        guard let target = replyTarget else { return false }
        compose(.reply(target, all: all), accountID: target.accountID)
        return true
    }

    private func composeForward() -> Bool {
        guard let target = replyTarget else { return false }
        compose(.forward(target), accountID: target.accountID)
        return true
    }

    func composeNew() {
        let preferred: AccountID?
        if case .account(let id) = scope { preferred = id } else { preferred = accounts.first?.id }
        guard let accountID = preferred else {
            onAddAccount?(nil)
            return
        }
        compose(.new, accountID: accountID)
    }

    private func compose(_ mode: ComposeMode, accountID: AccountID) {
        guard let account = accounts.first(where: { $0.id == accountID }) ?? accounts.first else { return }
        ComposeWindowController.present(client: environment.engine, account: account, accounts: accounts, mode: mode)
    }

    // MARK: Menu actions (first responder)

    @objc func archiveSelection(_ sender: Any?) { mailAction(.archive) }
    @objc func trashSelection(_ sender: Any?) { mailAction(.trash) }
    @objc func moveSelectionToInbox(_ sender: Any?) { moveSelectionToInbox() }
    @objc func toggleStarSelection(_ sender: Any?) { _ = perform(.toggleStar) }
    @objc func markSelectionUnread(_ sender: Any?) {
        guard let summary = selectedSummary else { return }
        mailAction(.setRead(summary.unreadCount > 0))
    }
    @objc func replyToSelection(_ sender: Any?) { _ = composeReply(all: false) }
    @objc func replyAllToSelection(_ sender: Any?) { _ = composeReply(all: true) }
    @objc func forwardSelection(_ sender: Any?) { _ = composeForward() }
    @objc func undoMailAction(_ sender: Any?) { undoLastAction() }
    @objc func focusSearchField(_ sender: Any?) { listPane.focusSearch() }

    @objc func selectAccountShortcut(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        strip.selectShortcut(item.tag)
    }

    @objc func goToMailboxView(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, MailboxView.allCases.indices.contains(item.tag) else { return }
        setView(MailboxView.allCases[item.tag])
    }

    @objc func toggleFocusedInbox(_ sender: Any?) {
        if mailboxView != .inbox { mailboxView = .inbox }
        section = section == .focused ? nil : .focused
        endSearch()
        applyQuery()
    }

    @objc func toggleAccountStrip(_ sender: Any?) {
        let collapse = !stripItem.isCollapsed
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            stripItem.animator().isCollapsed = collapse
        }
        listPane.setClearsTrafficLights(collapse)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let typing = KeyboardRouter.isTextInput(window?.firstResponder)
        switch menuItem.action {
        case #selector(archiveSelection(_:)), #selector(toggleStarSelection(_:)), #selector(trashSelection(_:)),
             #selector(moveSelectionToInbox(_:)):
            // Plain-letter and ⌘⌫ equivalents must not fire while the user is typing.
            return !showingWelcome && !typing && list.selectedConversationID != nil
        case #selector(markSelectionUnread(_:)):
            if let summary = selectedSummary {
                menuItem.title = summary.unreadCount > 0 ? "Mark as Read" : "Mark as Unread"
            }
            return !showingWelcome && list.selectedConversationID != nil
        case #selector(replyToSelection(_:)), #selector(replyAllToSelection(_:)), #selector(forwardSelection(_:)):
            return !showingWelcome && list.selectedConversationID != nil
        case #selector(undoMailAction(_:)):
            menuItem.title = undoStack.last.map { "Undo \($0.title)" } ?? "Undo Mail Action"
            return !showingWelcome && !typing && !undoStack.isEmpty
        case #selector(selectAccountShortcut(_:)):
            return !showingWelcome && (menuItem.tag == 0 || menuItem.tag <= accounts.count)
        case #selector(toggleFocusedInbox(_:)):
            menuItem.state = section == .focused && mailboxView == .inbox ? .on : .off
            return !showingWelcome
        case #selector(goToMailboxView(_:)):
            menuItem.state = MailboxView.allCases.indices.contains(menuItem.tag) && MailboxView.allCases[menuItem.tag] == mailboxView ? .on : .off
            return !showingWelcome
        case #selector(toggleAccountStrip(_:)):
            menuItem.title = stripItem.isCollapsed ? "Show Account Strip" : "Hide Account Strip"
            return !showingWelcome
        case #selector(focusSearchField(_:)):
            return !showingWelcome
        default:
            return true
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        if !showingWelcome, window?.firstResponder === window { focusList() }
    }
}
