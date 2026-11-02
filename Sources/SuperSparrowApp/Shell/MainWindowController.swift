import AppKit
import SSCore
import SSDesign
import WebKit
import os

/// The main window: account rail, message list and reader in a split view, or the welcome screen when there is
/// nothing to show yet. It owns the selection, routes reader actions and shortcuts, keeps the undo history for
/// mail actions and the toasts that offer it, and reduces every account's status into the sync line.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, KeyboardRouterTarget {
    static let defaultSize = QuireWindowChrome.defaultSize
    static let minimumSize = QuireWindowChrome.minimumSize
    private static let log = Logger(subsystem: "io.supersparrow.mac", category: "shell")

    let environment: AppEnvironment
    private let settings: AppSettings

    /// Wired by the app delegate, which owns sign-in, settings and environment switching.
    var onAddAccount: ((ProviderKind?) -> Void)?
    var onReconnect: ((Account) -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Settings on its Accounts pane: the sync line and its “Reconnect…” go there (§5.11).
    var onOpenAccountsSettings: (() -> Void)?
    var onTryDemo: (() -> Void)?
    var onCancelSignIn: (() -> Void)?
    /// The demo tag's Leave Demo… (§5.43): the app delegate asks, as File › Leave Demo… does, then wipes the
    /// demo store and returns to the welcome screen.
    var onLeaveDemo: (() -> Void)?

    private let splitController = MainSplitViewController()
    private let strip = AccountStripViewController()
    private let list: MessageListViewController
    private let listPane: ListPaneViewController
    private let conversation: ConversationViewController
    private let conversationPane: ConversationPaneViewController
    private let welcome = WelcomeViewController()
    private var stripItem: NSSplitViewItem!
    private var listItem: NSSplitViewItem!

    private let inboxMonitor: InboxMonitor
    private let activity: SyncActivityMonitor
    let notifier: NewMailNotifier
    private var router: KeyboardRouter?
    private var statusObservation: StoreObservation?
    private var stripCollapseObservation: NSKeyValueObservation?

    /// The lights' geometry, measured once the window exists: the rail width and the minimal-mode masthead
    /// follow from it (§3.2).
    private var chrome = QuireWindowChrome.fallbackMetrics

    private(set) var accounts: [Account] = []
    private var statuses: [AccountSyncStatus] = []
    private var scope: AccountScope = .unified
    private var mailboxView: MailboxView = .inbox
    private var section: InboxSection?
    private var searchText = ""
    private var showingWelcome = false
    private var unifiedUnread = 0
    private var unreadByAccount: [AccountID: Int] = [:]
    /// Unread counts when the user last chose a scope; more than this in another account is new mail (§5.3).
    private var unreadAtScopeChange: [AccountID: Int] = [:]

    // Undo and toasts
    private var undoHistory = MailActionUndoHistory(grace: Quire.Motion.undoKeyGrace, coalesceWindow: Quire.Motion.toastCoalesce)

    // Sign-in, checks
    private var pendingSignIn: PendingSignIn?
    private var requestedSignIn: (request: PendingSignIn, at: Date)?
    private var signInEndedAt: Date?
    private var reconnectedAccount: AccountID?
    private var checkStartedAt: Date?
    /// The one account a reconnect's check waits for; nil when the user asked to check every account.
    private var checkScope: AccountID?
    private var checkTimer: Timer?
    private var acknowledgeTimer: Timer?

    #if DEBUG
    /// `--snapshot-state=…` (debug builds): states to put the window in before a snapshot.
    private var debugStatuses: [AccountSyncStatus]?
    private var debugKeyStealer: NSWindow?
    #endif

    init(environment: AppEnvironment, settings: AppSettings) {
        self.environment = environment
        self.settings = settings
        list = MessageListViewController(store: environment.store)
        listPane = ListPaneViewController(list: list)
        conversation = ConversationViewController(client: environment.engine)
        conversationPane = ConversationPaneViewController(conversation: conversation)
        inboxMonitor = InboxMonitor(store: environment.store)
        activity = SyncActivityMonitor(store: environment.store)
        notifier = NewMailNotifier(settings: settings)

        let window = MainWindow(contentRect: NSRect(origin: .zero, size: QuireWindowChrome.defaultSize),
                                styleMask: QuireWindowChrome.mainStyleMask, backing: .buffered, defer: false)
        QuireWindowChrome.configureMainWindow(window, title: environment.isDemo ? "SuperSparrow — Demo" : "SuperSparrow")
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.autorecalculatesKeyViewLoop = false
        super.init(window: window)
        window.delegate = self
        chrome = QuireWindowChrome.metrics(of: window)

        buildSplit()
        wireCallbacks()
        refreshAccounts()
        applyQuery()

        window.contentViewController = showingWelcome ? welcome : splitController
        window.setContentSize(Self.defaultSize)
        window.center()
        if !isSnapshot {
            // Restores the last frame, which also overrides the centering above after the first run.
            window.setFrameAutosaveName("MainWindow")
        }
        chrome = QuireWindowChrome.metrics(of: window)
        applyRailWidth()
        if !showingWelcome { placeDividersIfNeeded() }
        window.shellKeyViews = { [weak self] in self?.shellKeyViews ?? [] }
        window.readerRoot = conversationPane.view
        // Otherwise AppKit picks the first key view, the search field, and single-key shortcuts start as text.
        window.initialFirstResponder = Self.firstDescendant(of: list.view, as: NSTableView.self)
        // The split view's autosave can bring the rail back collapsed, and dragging the divider can collapse it
        // too; either way the window is in minimal mode then.
        applyMinimalMode()
        stripCollapseObservation = stripItem.observe(\.isCollapsed, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.applyMinimalMode() }
            }
        }

        statusObservation = environment.engine.observeStatus { [weak self] statuses in
            MainActor.assumeIsolated { self?.statusesChanged(statuses) }
        }
        inboxMonitor.start(accounts: accounts.map(\.id))
        activity.start()
        let router = KeyboardRouter(target: self)
        router.install()
        self.router = router
        listPane.setDemo(environment.isDemo)
        refreshSyncLine()
        NotificationCenter.default.addObserver(self, selector: #selector(composeDraftDiscarded(_:)),
                                               name: ComposeWindowController.draftDiscardedNotification, object: nil)
    }

    /// A composer's Message › Discard Draft… confirms here: “Draft discarded · Undo” (spec §5.20). Its Undo is
    /// a click with no keycap: Z and ⌘Z here revert mail actions, so the toast leaves ⌘Z with any undo-send
    /// panel still counting.
    @objc private func composeDraftDiscarded(_ note: Notification) {
        let undo = note.userInfo?[ComposeWindowController.draftUndoKey] as? ComposeDraftUndo
        listPane.toasts.show("Draft discarded", kind: .undoable, symbol: Quire.Icon.trash, actionTitle: "Undo") { undo?.undo() }
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
        activity.stop()
        checkTimer?.invalidate()
        acknowledgeTimer?.invalidate()
        listPane.toasts.dismiss()
        window?.orderOut(nil)
    }

    // MARK: Layout

    private func buildSplit() {
        if !isSnapshot { splitController.splitView.autosaveName = "MainSplit" }
        stripItem = NSSplitViewItem(viewController: strip)
        stripItem.canCollapse = true
        stripItem.holdingPriority = .defaultHigh + 10

        listItem = NSSplitViewItem(viewController: listPane)
        listItem.minimumThickness = ListPaneViewController.minimumWidth
        listItem.maximumThickness = ListPaneViewController.maximumWidth
        // Live resize: the list keeps its width and the reader takes the change.
        listItem.holdingPriority = .defaultLow + 10
        listItem.canCollapse = false

        let readerItem = NSSplitViewItem(viewController: conversationPane)
        readerItem.minimumThickness = ConversationPaneViewController.minimumWidth
        readerItem.holdingPriority = .defaultLow
        readerItem.canCollapse = false

        splitController.splitViewItems = [stripItem, listItem, readerItem]
        applyRailWidth()
    }

    /// The rail is exactly as wide as the lights need (76 on macOS 15, 84 from 26 on).
    private func applyRailWidth() {
        let width = chrome.railWidth
        strip.railWidth = width
        stripItem?.minimumThickness = width
        stripItem?.maximumThickness = width
    }

    /// A first run has no autosaved divider positions; the list then starts at its preferred width.
    private let isFirstSplitLayout = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MainSplit") == nil

    /// `--snapshot`: the window keeps the default size and divider positions, so it compares with the specimen
    /// and never rewrites the user's saved frame.
    private let isSnapshot = LaunchOptions().snapshotPath != nil

    private var isMinimal: Bool { stripItem?.isCollapsed ?? false }

    private var didPlaceDividers = false

    /// With no saved positions (a first run, or a snapshot) the list starts at its default 364 pt. Done once the
    /// split is in the window, which after the welcome screen is only when the first account arrives.
    private func placeDividersIfNeeded() {
        guard !didPlaceDividers, isSnapshot || isFirstSplitLayout else { return }
        didPlaceDividers = true
        splitController.splitView.layoutSubtreeIfNeeded()
        splitController.splitView.setPosition(chrome.railWidth + ListPaneViewController.preferredWidth, ofDividerAt: 1)
    }

    /// Minimal mode (§5.1): the masthead moves past the would-be rail, the title menu gains the accounts and the
    /// new-mail dot may show. Row 2 of the header never changes.
    private func applyMinimalMode() {
        listPane.setMastheadX(isMinimal ? chrome.mastheadMinimalX : Quire.Layout.ListHeader.mastheadX)
        updateNewMailDot()
    }

    private func wireCallbacks() {
        strip.onSelect = { [weak self] scope in self?.scopeChanged(scope) }
        strip.onAddAccount = { [weak self] kind in self?.requestAddAccount(kind) }
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
        listPane.onCompose = { [weak self] in self?.composeNew() }
        listPane.onSelectAccountShortcut = { [weak self] number in self?.strip.selectShortcut(number) }
        listPane.onAddAccount = { [weak self] kind in self?.requestAddAccount(kind) }
        listPane.onLeaveDemo = { [weak self] in self?.onLeaveDemo?() }
        listPane.titleMenuModel = { [weak self] in self?.titleMenuModel ?? TitleMenu.Model(
            view: .inbox, inboxUnread: 0, scope: .unified, showsAccounts: false, unifiedUnread: 0, accounts: []) }
        listPane.statusBar.onOpenSettings = { [weak self] in self?.openAccountsSettings() }
        listPane.statusBar.onAction = { [weak self] action in self?.syncLineAction(action) }
        listPane.toasts.onEnd = { [weak self] id, reason in self?.toastEnded(id, reason: reason) }

        list.onSelectionChange = { [weak self] id in self?.selectionChanged(id) }
        list.onOpen = { [weak self] id in
            guard let self else { return }
            if self.conversation.currentConversationID != id { self.conversation.show(id) }
            self.focusReader()
        }
        list.onRowsChange = { [weak self] in self?.listPane.listRowsDidChange() }

        conversation.onAction = { [weak self] action in self?.handle(action) }

        welcome.onAddAccount = { [weak self] kind in self?.onAddAccount?(kind) }
        welcome.onTryDemo = { [weak self] in self?.onTryDemo?() }
        welcome.onCancelSignIn = { [weak self] in self?.onCancelSignIn?() }

        inboxMonitor.onCounts = { [weak self] unified, perAccount in self?.countsChanged(unified: unified, perAccount: perAccount) }
        inboxMonitor.onRows = { [weak self] rows in
            guard let self else { return }
            self.notifier.inboxDidChange(rows, accounts: self.accountsByID)
        }
        inboxMonitor.onFailures = { [weak self] failures in self?.operationsFailed(failures) }
        notifier.onOpenConversation = { [weak self] id in self?.reveal(id) }
        activity.onChange = { [weak self] in self?.refreshSyncLine() }
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
        let previous = Set(accounts.map(\.id))
        accounts = fresh
        if changed {
            let byID = accountsByID
            strip.setAccounts(fresh)
            list.accountsByID = byID
            conversation.accountsByID = byID
            inboxMonitor.updateAccounts(fresh.map(\.id))
            listPane.setSearchEnabled(!fresh.isEmpty)
            selectAddedAccount(previous: previous)
            updateScopeDetails()
        }
        updateWelcome()
    }

    /// A sign-in that just added an account selects it (§5.44): the pending tile becomes the account's tile.
    private func selectAddedAccount(previous: Set<AccountID>) {
        let recent = pendingSignIn != nil || (signInEndedAt.map { Date().timeIntervalSince($0) < 5 } ?? false)
        // The first account has nothing to be told apart from; the launch's own read is not an addition.
        guard recent, !previous.isEmpty, let added = accounts.last(where: { !previous.contains($0.id) }) else { return }
        strip.select(.account(added.id), notify: true)
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
        if !wantsWelcome {
            placeDividersIfNeeded()
            focusList()
        }
    }

    private func statusesChanged(_ statuses: [AccountSyncStatus]) {
        self.statuses = statuses
        refreshAccounts()
        list.syncStatuses = statuses
        announceReconnectIfDone()
        refreshSyncLine()
    }

    /// No toast for a reconnect: the badge leaving is the confirmation, and VoiceOver hears it in words (§5.44).
    private func announceReconnectIfDone() {
        guard let id = reconnectedAccount, let status = statuses.first(where: { $0.accountID == id }),
              status.phase != .needsReauth else { return }
        reconnectedAccount = nil
        if let account = accountsByID[id] {
            announce("\(AccountMonogram.name(for: account)) reconnected.")
        }
    }

    /// The statuses the rail and the sync line draw from.
    private var effectiveStatuses: [AccountSyncStatus] {
        #if DEBUG
        if let debugStatuses { return debugStatuses }
        #endif
        return statuses
    }

    /// Shows progress on the welcome screen while a browser sign-in runs, and the waiting state in the rail and
    /// the sync line (§5.44).
    func setSignInInProgress(_ message: String?) {
        welcome.setBusy(message)
        if message != nil {
            if let requested = requestedSignIn, Date().timeIntervalSince(requested.at) < 3 {
                pendingSignIn = requested.request
            } else if pendingSignIn == nil {
                pendingSignIn = .other
            }
            requestedSignIn = nil
        } else if let ended = pendingSignIn {
            pendingSignIn = nil
            signInEndedAt = Date()
            if case .reconnecting(let id) = ended {
                // A finished reconnect checks that account for mail, a check the user asked for (§5.11).
                reconnectedAccount = id
                startCheck(onlyFor: id)
            }
        }
        applySignInState()
    }

    /// A reconnect succeeded, wherever it started (§5.44): the line checks that account for mail and VoiceOver
    /// hears “… reconnected.” once its badge has left. One started from this window is already being checked.
    func reconnectDidSucceed(_ id: AccountID) {
        guard reconnectedAccount != id else { return }
        reconnectedAccount = id
        startCheck(onlyFor: id)
    }

    private func applySignInState() {
        switch pendingSignIn {
        case .adding?: strip.setSignIn(active: true, adding: true, reconnecting: nil)
        case .reconnecting(let id)?: strip.setSignIn(active: true, adding: false, reconnecting: id)
        case .other?: strip.setSignIn(active: true, adding: false, reconnecting: nil)
        case nil: strip.setSignIn(active: false, adding: false, reconnecting: nil)
        }
        listPane.statusBar.actionsEnabled = pendingSignIn == nil
        refreshSyncLine()
    }

    private func requestAddAccount(_ kind: ProviderKind) {
        guard pendingSignIn == nil else { return }
        requestedSignIn = (.adding(kind), Date())
        onAddAccount?(kind)
    }

    private func requestReconnect(_ account: Account) {
        guard pendingSignIn == nil else { return }
        requestedSignIn = (.reconnecting(account.id), Date())
        onReconnect?(account)
    }

    // MARK: Sync line

    private func refreshSyncLine() {
        let effective = effectiveStatuses
        strip.setStatuses(effective)
        let signIn: SyncLineSummary.SignIn?
        switch pendingSignIn {
        case .adding(let kind)?: signIn = .adding(kind)
        case .reconnecting(let id)?: signIn = .reconnecting(id)
        case .other?: signIn = .adding(nil)
        case nil: signIn = nil
        }
        let summary = SyncLineSummary.make(SyncLineSummary.Input(
            statuses: effective, accounts: accounts, isDemo: environment.isDemo, isNetworkReachable: activity.isNetworkReachable,
            signIn: signIn, sendingCount: activity.sendingCount, isChecking: isCheckRunning
        ))
        listPane.statusBar.apply(summary)
        updateCategoriesKnown()
    }

    private func syncLineAction(_ action: SyncLineSummary.Action) {
        switch action {
        case .reconnect(let id):
            guard let account = accountsByID[id] else { return }
            requestReconnect(account)
        case .reconnectSeveral:
            openAccountsSettings()
        case .retry(let ids):
            for id in ids { environment.engine.syncNow(accountID: id) }
        case .cancelSignIn:
            onCancelSignIn?()
        }
    }

    private func openAccountsSettings() {
        (onOpenAccountsSettings ?? onOpenSettings)?()
    }

    /// First sync with no categories known yet: Focused and Other wait (§5.5).
    private func updateCategoriesKnown() {
        let inScope = effectiveStatuses.filter { status in scope.accountIDs.map { $0.contains(status.accountID) } ?? true }
        let known = inScope.isEmpty || !inScope.allSatisfy { $0.phase == .bootstrapping }
        listPane.setCategoriesKnown(known)
    }

    // MARK: Checking for mail

    /// View › Check for New Mail (⇧⌘N), by way of the app delegate: the one check that shows on the line, once
    /// it has run 150 ms (§5.11).
    func checkForNewMail() {
        environment.engine.syncNow(accountID: nil)
        startCheck()
    }

    private func startCheck(onlyFor account: AccountID? = nil) {
        checkStartedAt = Date()
        checkScope = account
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if !self.isCheckPending {
                    timer.invalidate()
                    self.checkTimer = nil
                    self.checkStartedAt = nil
                    self.checkScope = nil
                    self.announceReconnectIfDone()
                    self.reconnectedAccount = nil
                }
                self.refreshSyncLine()
            }
        }
    }

    /// The check has not finished: some working account has not synced since it started, and 30 s have not
    /// passed. A reconnect's check waits only for that account, which may still read “needs sign-in” until the
    /// engine takes the new tokens (a cancelled reconnect keeps it so, under the line's Sign in required).
    private var isCheckPending: Bool {
        guard let started = checkStartedAt, Date().timeIntervalSince(started) < 30 else { return false }
        if let scope = checkScope {
            guard let status = statuses.first(where: { $0.accountID == scope }), status.phase != .error else { return false }
            return status.phase == .needsReauth || status.phase == .syncing || (status.lastSuccessfulSyncAt ?? .distantPast) < started
        }
        let working = statuses.filter { $0.phase != .needsReauth && $0.phase != .error }
        return working.contains { ($0.lastSuccessfulSyncAt ?? .distantPast) < started || $0.phase == .syncing }
    }

    private var isCheckRunning: Bool {
        guard let started = checkStartedAt else { return false }
        return Date().timeIntervalSince(started) >= Quire.Motion.spinnerDelay && isCheckPending
    }

    // MARK: Query

    private func scopeChanged(_ scope: AccountScope) {
        self.scope = scope
        unreadAtScopeChange = unreadByAccount
        updateScopeDetails()
        applyQuery()
        updateCategoriesKnown()
    }

    /// Narrowed to one account, the masthead names its address (§5.3).
    private func updateScopeDetails() {
        if case .account(let id) = scope, let account = accountsByID[id] {
            listPane.setNarrowedAddress(account.email)
        } else {
            listPane.setNarrowedAddress(nil)
        }
        updateNewMailDot()
    }

    private func countsChanged(unified: Int, perAccount: [AccountID: Int]) {
        unifiedUnread = unified
        unreadByAccount = perAccount
        strip.setUnreadCounts(unified: unified, perAccount: perAccount)
        updateNewMailDot()
    }

    /// Minimal mode, narrowed: another account received mail since the user chose this scope.
    private func updateNewMailDot() {
        guard isMinimal, case .account(let current) = scope else {
            listPane.setNewMailDot(false)
            return
        }
        let fresh = unreadByAccount.contains { id, count in id != current && count > (unreadAtScopeChange[id] ?? 0) }
        listPane.setNewMailDot(fresh)
    }

    private var titleMenuModel: TitleMenu.Model {
        let monograms = AccountMonogram.monograms(for: accounts)
        let inboxUnread: Int
        if case .account(let id) = scope { inboxUnread = unreadByAccount[id] ?? 0 } else { inboxUnread = unifiedUnread }
        return TitleMenu.Model(
            view: mailboxView, inboxUnread: inboxUnread, scope: scope, showsAccounts: isMinimal, unifiedUnread: unifiedUnread,
            accounts: accounts.map { TitleMenu.AccountEntry(account: $0, monogram: monograms[$0.id] ?? "?", unread: unreadByAccount[$0.id] ?? 0) }
        )
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
        conversation.mailboxView = mailboxView
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
        } else {
            // The same query (a trailing space, say) brings no new rows; the field must not wait for them.
            listPane.listRowsDidChange()
        }
        listPane.display(view: mailboxView, section: mailboxView == .inbox ? section : nil)
        // No notification for Other mail while the Inbox filter is Focused (spec §5.41).
        notifier.hidesOtherMail = mailboxView == .inbox && section == .focused
    }

    // MARK: Selection

    private func selectionChanged(_ id: ConversationID?) {
        conversation.show(id)
        acknowledgeTimer?.invalidate()
        acknowledgeTimer = nil
        guard let id else { return }
        let neighbors = list.neighbors(of: id)
        var seen: Set<ConversationID> = [id]
        let wanted = [neighbors.next, neighbors.previous, neighbors.nextUnread].compactMap { $0 }.filter { seen.insert($0).inserted }
        conversation.prerender(wanted)
        if list.conversations.first(where: { $0.id == id })?.failedOperation != nil {
            // Opening the conversation for 150 ms acknowledges its failed mark (§5.7, §8.5).
            acknowledgeTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.list.selectedConversationID == id else { return }
                    try? self.environment.store.acknowledgeFailedOperation(conversationID: id)
                }
            }
        }
    }

    // MARK: Snapshot support

    /// Debug aid for `--snapshot`: selects the first row as a click would.
    @discardableResult
    func selectFirstConversation() -> ConversationID? {
        #if DEBUG
        applyDebugSnapshotStates()
        #endif
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
        strip.select(.unified, notify: false)
        scope = .unified
        updateScopeDetails()
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

    /// The shell's part of the Tab order (§3.4): rail (hidden in minimal mode), header controls, list, sync line.
    private var shellKeyViews: [NSView] {
        guard !showingWelcome else { return [] }
        return (isMinimal ? [] : strip.keyViews) + listPane.keyViews
    }

    private func announce(_ text: String) {
        guard let window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: KeyboardRouterTarget

    var keyboardWindow: NSWindow? { showingWelcome ? nil : window }

    /// The g-sequence HUD sits where the toast does, at the bottom centre of the list pane, and replaces it.
    var sequenceHUDHost: NSView? { listPane.view }
    /// Dismissed, not cut short silently: Z keeps reaching the toast's action for the grace period (§6.1).
    func sequenceHUDWillAppear() { listPane.toasts.dismiss() }

    var isReaderFocused: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: conversationPane.view)
    }

    func perform(_ command: KeyCommand) -> Bool {
        // The router sees every key first; ↑/↓ and ↩ on a focused rail tile, sync line or menu button are that
        // control's own (§5.2, §5.11), so they go on to it instead of moving or opening the list.
        if focusedControlTakesCurrentKey { return false }
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
            // R and A focus the reader's quick reply where it shows; elsewhere they open the composer (spec §5.18).
            return conversation.focusQuickReply(all: false) || composeReply(all: false)
        case .replyAll:
            return conversation.focusQuickReply(all: true) || composeReply(all: true)
        case .forward:
            return composeForward()
        case .compose:
            composeNew()
            return true
        case .search:
            listPane.focusSearch()
            return true
        case .clearSearch:
            return escape()
        case .moveToInbox:
            return moveSelectionToInbox()
        case .undo:
            // ⌘Z cancels a quick reply still in its undo window, as its strip's keycap says; Z never does (spec §6.1).
            if NSApp.currentEvent?.modifierFlags.contains(.command) == true, conversation.cancelQuickSend() { return true }
            return undoLastAction()
        case .goTo(let view):
            setView(view)
            return true
        }
    }

    private var focusedControlTakesCurrentKey: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown,
              let control = window?.firstResponder as? ShellKeyHandling else { return false }
        return control.handlesKey(event)
    }

    /// Esc outside a text field, by the precedence of §6.1: a visible toast goes first (its undo keeps working
    /// for the grace period), then focus in the reader returns to the list, then a kept search query clears.
    /// On the list with nothing to undo Esc does nothing, without a beep.
    private func escape() -> Bool {
        if listPane.toasts.isVisible {
            listPane.toasts.dismiss()
            return true
        }
        if isReaderFocused {
            focusList()
            return true
        }
        if !searchText.isEmpty || !listPane.searchText.isEmpty {
            endSearch()
            applyQuery()
            return true
        }
        return true
    }

    // MARK: Mail actions

    /// Applies a change to the selected conversation and remembers how to undo it. Actions that take the row
    /// out of the view say so in a toast with Undo; several within 1000 ms coalesce into one (§5.30).
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
        recordUndo(record)
        return true
    }

    /// A toast's Undo reverts the group that toast offers, whatever happened since; Z and ⌘Z follow
    /// `MailActionUndoHistory.target`.
    private func recordUndo(_ record: MailActionRecord) {
        let now = Date()
        let toasts = listPane.toasts
        if let group = undoHistory.coalesce(record, at: now, visibleToastID: toasts.visibleID) {
            let id = group.id
            toasts.show(MailActionCopy.toast(for: record.change, count: group.records.count), kind: .undoable,
                        symbol: symbol(for: record.change), actionTitle: "Undo", keycap: "Z",
                        updating: group.toastID) { [weak self] in self?.undo(groupID: id) }
            UndoSendPanel.yieldUndoKey()
            return
        }
        // No toast for a change the row itself shows; Z still reaches it for the grace period.
        let toasted = MailActionCopy.wantsToast(for: record.change, in: mailboxView, isSearching: !searchText.isEmpty)
        let id = undoHistory.add(record, at: now, toasted: toasted)
        guard toasted else { return }
        let toastID = toasts.show(MailActionCopy.toast(for: record.change), kind: .undoable, symbol: symbol(for: record.change),
                                  actionTitle: "Undo", keycap: "Z") { [weak self] in self?.undo(groupID: id) }
        undoHistory.bindToast(toastID, to: id)
        // The toast's Z keycap takes ⌘Z from an undo-send panel still counting, until the toast's life is over.
        UndoSendPanel.yieldUndoKey()
    }

    /// A toast stopped being visible: Z and ⌘Z reach its action for 10000 ms more (§6.1).
    private func toastEnded(_ id: Int, reason: ToastPresenter.End) {
        undoHistory.toastEnded(id, at: Date())
    }

    /// The group Z and ⌘Z would undo now.
    private var undoTarget: MailActionUndoHistory.Group? {
        undoHistory.target(at: Date(), visibleToastID: listPane.toasts.visibleID)
    }

    /// Brings the selected conversation back to the inbox: out of the trash when it is there, else out of the
    /// archive.
    @discardableResult
    private func moveSelectionToInbox() -> Bool {
        mailAction(.moveToInbox)
    }

    @discardableResult
    private func undoLastAction() -> Bool {
        guard let target = undoTarget else {
            NSSound.beep()
            return true
        }
        return undo(groupID: target.id)
    }

    @discardableResult
    private func undo(groupID: Int) -> Bool {
        guard let group = undoHistory.remove(groupID) else {
            NSSound.beep()
            return true
        }
        do {
            for record in group.records.reversed() {
                for step in record.inverse {
                    try environment.engine.perform(step.change, on: step.targets)
                }
            }
        } catch {
            Self.log.error("undo failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return true
        }
        listPane.toasts.show(MailActionCopy.undoConfirmation(for: group.change), kind: .confirmation, symbol: Quire.Icon.undone)
        if let id = group.records.last?.conversation, [.archive, .trash, .moveToInbox, .restoreFromTrash].contains(group.change) {
            // The row comes back; put the selection on it so the user sees what was restored.
            list.selectedConversationID = id
            selectionChanged(id)
        }
        return true
    }

    /// The provider refused an action and the store put the row back (§5.7): say so.
    private func operationsFailed(_ failures: [(ConversationID, OperationKind)]) {
        guard let kind = failures.last?.1 else { return }
        listPane.toasts.show(MailActionCopy.failure(for: kind), kind: .error)
    }

    private func symbol(for change: MetadataChange) -> String {
        switch change {
        case .archive: return Quire.Icon.archive
        case .trash: return Quire.Icon.trash
        case .moveToInbox, .restoreFromTrash: return Quire.Icon.moveToInbox
        case .setRead(true): return Quire.Icon.markRead
        case .setRead(false): return Quire.Icon.markUnread
        case .setStarred: return Quire.Icon.star
        }
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
        case .moveToInbox(let id):
            mailAction(.moveToInbox, on: id)
        case .openAttachment:
            // The reader already opened Quick Look.
            break
        case .continueDraft(let id):
            DraftReopener.present(id, client: environment.engine, accounts: accounts)
        case .discardDraft(let id):
            mailAction(.trash, on: id)
        case .reveal(let id):
            reveal(id)
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

    /// View › All / Focused / Other and ⌥1 / ⌥2 / ⌥3 (§5.5, §5.35). The menu item's tag is the tab's index.
    @objc func selectInboxSection(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, ListPaneViewController.sections.indices.contains(item.tag) else { return }
        if mailboxView != .inbox { mailboxView = .inbox }
        section = ListPaneViewController.sections[item.tag].section
        endSearch()
        applyQuery()
    }

    /// ⌃⌘S: the rail goes instantly in every mode, so no row re-truncates and no frame re-measures over frames
    /// (§5.1, §8.2).
    @objc func toggleAccountStrip(_ sender: Any?) {
        let collapse = !stripItem.isCollapsed
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            stripItem.isCollapsed = collapse
        }
        applyMinimalMode()
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
            // Titled by its target, as Edit › Undo is (§6.1).
            let target = undoTarget
            menuItem.title = target.map { MailActionCopy.undoMenuTitle(for: $0.change) } ?? "Can't Undo"
            return !showingWelcome && !typing && target != nil
        case #selector(selectAccountShortcut(_:)):
            return !showingWelcome && (menuItem.tag == 0 || menuItem.tag <= accounts.count)
        case #selector(selectInboxSection(_:)):
            let current = ListPaneViewController.sections.firstIndex { $0.section == section } ?? 0
            menuItem.state = mailboxView == .inbox && menuItem.tag == current ? .on : .off
            return !showingWelcome && !typing
        case #selector(goToMailboxView(_:)):
            menuItem.state = MailboxView.allCases.indices.contains(menuItem.tag) && MailboxView.allCases[menuItem.tag] == mailboxView ? .on : .off
            return !showingWelcome
        case #selector(toggleAccountStrip(_:)):
            menuItem.title = stripItem.isCollapsed ? "Show Account Rail" : "Hide Account Rail"
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

/// A browser sign-in the window is waiting on (§5.44).
private enum PendingSignIn: Equatable {
    /// Started from this window's rail or Demo tag, for this provider.
    case adding(ProviderKind)
    /// Started from the sync line's Reconnect.
    case reconnecting(AccountID)
    /// Started elsewhere (Settings, the File menu): the line waits, the rail does not guess.
    case other
}

#if DEBUG
extension MainWindowController {
    /// `--snapshot-state=key,notkey,minimal,narrowed,adding,reconnect,signin,toast,search,focus-rail,focus-action,
    /// hover-demo,hover-masthead,ic,graphite` (debug builds):
    /// puts the window in the named states before `--snapshot` captures it, so every state of the chrome can be
    /// compared with the specimen without a screen recording.
    fileprivate func applyDebugSnapshotStates() {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot-state=") }) else { return }
        let states = Set(argument.dropFirst("--snapshot-state=".count).split(separator: ",").map(String.init))
        let second = accounts.dropFirst().first
        if states.contains("ic") || states.contains("graphite") {
            QuireEnvironment.shared.setOverrides(QuireEnvironment.Overrides(
                isGraphite: states.contains("graphite") ? true : nil, increaseContrast: states.contains("ic") ? true : nil))
        }
        if states.contains("narrowed"), let first = accounts.first {
            strip.select(.account(first.id), notify: true)
            // Another account has mail since the scope was chosen.
            unreadAtScopeChange = unreadByAccount.mapValues { max(0, $0 - 1) }
        }
        if states.contains("minimal") {
            stripItem.isCollapsed = true
            applyMinimalMode()
        }
        if states.contains("signin") || states.contains("reconnect"), let second {
            debugStatuses = statuses.map { $0.accountID == second.id ? AccountSyncStatus(accountID: second.id, phase: .needsReauth) : $0 }
        }
        if states.contains("adding") {
            requestedSignIn = (.adding(.gmail), Date())
            setSignInInProgress("Finish signing in in your browser…")
        }
        if states.contains("reconnect"), let second {
            requestedSignIn = (.reconnecting(second.id), Date())
            setSignInInProgress("Finish signing in in your browser…")
        }
        refreshSyncLine()
        if states.contains("toast") {
            listPane.toasts.show(MailActionCopy.toast(for: .archive, count: 3), kind: .undoable, symbol: Quire.Icon.archive,
                                 actionTitle: "Undo", keycap: "Z") {}
            // Frozen part-way through its life, as the specimen draws it, so the contrail shows in the snapshot.
            if let contrail = listPane.toastView.slip?.lifetimeContrail {
                contrail.mode = .countdown(duration: Quire.Motion.toastLife, remaining: Quire.Motion.toastLife * 0.6)
                contrail.isPaused = true
            }
        }
        if states.contains("search") {
            listPane.header.search.query = "lisbon"
            listPane.header.search.onQueryChange?("lisbon")
        }
        // Forced looks: a snapshot launched from a terminal may never become the key window, so focus rings and
        // hover are drawn by state rather than by the real first responder.
        if states.contains("focus-rail") {
            (strip.selectedTile as? QuireControl)?.displayState = .focused
        }
        if states.contains("focus-action") {
            listPane.statusBar.actionButton.displayState = .focused
        }
        if states.contains("hover-demo") {
            listPane.header.demoTag.displayState = .hover
        }
        if states.contains("hover-masthead") {
            listPane.header.masthead.displayState = .hover
        }
        if states.contains("key") {
            // Draws the key-window marks of the chrome's own controls even when another app is frontmost (the
            // traffic lights stay the system's).
            func forceKey(_ view: NSView) {
                (view as? QuireControl)?.windowKeyOverride = true
                view.subviews.forEach(forceKey)
            }
            forceKey(strip.view)
            forceKey(listPane.header)
            forceKey(listPane.statusBar)
        }
        if states.contains("notkey") {
            // A borderless window far off screen takes key, so this one draws its not-key marks.
            let stealer = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 10, height: 10), styleMask: [.titled],
                                   backing: .buffered, defer: false)
            stealer.isReleasedWhenClosed = false
            stealer.makeKeyAndOrderFront(nil)
            debugKeyStealer = stealer
        }
    }
}
#endif
