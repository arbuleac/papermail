import AppKit
import SSCore
import SSDesign
import WebKit
import os

/// The main window: account rail, message list and reader in a split view, or the welcome screen when there is
/// nothing to show yet. It owns the selection (one conversation or several), routes reader actions and
/// shortcuts, keeps the window's one undo history and ranks Z and ⌘Z across it, the quick reply's countdown
/// and the undo-send panels (§6.1), and reduces every account's status into the sync line.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, KeyboardRouterTarget, UndoKeyArbiter {
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
    /// The panes' split view (the app's tests measure its dividers).
    var splitView: NSSplitView { splitController.splitView }
    // The panes are internal, not private, so the app's tests can drive the window as a user would.
    let strip = AccountStripViewController()
    let list: MessageListViewController
    let listPane: ListPaneViewController
    let conversation: ConversationViewController
    private let conversationPane: ConversationPaneViewController
    private let welcome = WelcomeViewController()
    private var stripItem: NSSplitViewItem!
    private var listItem: NSSplitViewItem!

    private let inboxMonitor: InboxMonitor
    /// Internal so the app's tests can drive the network path without a real path monitor.
    let activity: SyncActivityMonitor
    /// Checks every account at once, when the network comes back; an account waiting for sign-in keeps waiting
    /// (`MailClient.checkForMail`). Replaceable so the app's tests, whose engine never starts, can count the checks.
    lazy var checkAllAccounts: () -> Void = { [weak self] in self?.environment.engine.checkForMail() }
    /// Drafts kept on this Mac, which the Drafts view lists and the reader shows beside the provider's.
    let localDrafts = LocalDrafts()
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
    private var searchText = ""
    private var showingWelcome = false
    private var unifiedUnread = 0
    private var unreadByAccount: [AccountID: Int] = [:]
    /// Unread counts when the user last chose a scope; more than this in another account is new mail (§5.3).
    private var unreadAtScopeChange: [AccountID: Int] = [:]

    // Undo and toasts
    private var undoHistory = MailActionUndoHistory(grace: Quire.Motion.undoKeyGrace, coalesceWindow: Quire.Motion.toastCoalesce)
    /// How the history's external steps are reverted (a discarded draft reopens its composer), by group id.
    private var externalUndos: [Int: () -> Void] = [:]
    /// What the reader was last asked to show, so the list's two selection callbacks show it once.
    private var shownSelection: [ConversationID] = []

    // Sign-in, checks
    private(set) var pendingSignIn: PendingSignIn?
    private var signInEndedAt: Date?
    private var reconnectedAccount: AccountID?
    private var checkStartedAt: Date?
    /// The one account a reconnect's check waits for; nil when the user asked to check every account.
    private var checkScope: AccountID?
    private var checkTimer: Timer?
    private var acknowledgeTimer: Timer?
    private var retryLineTimer: Timer?

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
        list.allowsMultipleSelection = true
        if isSnapshot {
            // Wherever the pointer happens to rest, no row draws a hover wash into the render.
            list.loadViewIfNeeded()
            list.tableView.isHoverableRow = { _ in false }
        }
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
        UndoSendPanel.undoKeyArbiter = self
        NotificationCenter.default.addObserver(self, selector: #selector(composeDraftDiscarded(_:)),
                                               name: ComposeWindowController.draftDiscardedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(signInProgressChanged(_:)),
                                               name: SignInProgress.didChange, object: nil)
        // A window built while a sign-in runs (the demo replaced mid-way) shows it from the start.
        if let running = SignInProgress.current { applySignIn(running) }
        NotificationCenter.default.addObserver(self, selector: #selector(composersChanged(_:)),
                                               name: ComposeWindowRegistry.didChange, object: nil)
    }

    /// A composer opened or closed: a draft it holds reads “Open in a composer window” in the reader (§5.19).
    @objc private func composersChanged(_ note: Notification) {
        conversation.composersDidChange()
    }

    /// A composer's Message › Discard Draft… confirms here: “Draft discarded · Undo” (spec §5.20). It joins the
    /// window's undo history like a mail action, so Z and ⌘Z reach it in the order of §6.1, and its Undo
    /// reopens the composer with the draft.
    @objc private func composeDraftDiscarded(_ note: Notification) {
        guard let undo = note.userInfo?[ComposeWindowController.draftUndoKey] as? ComposeDraftUndo else { return }
        recordExternalUndo(command: "Discard Draft", toast: "Draft discarded", symbol: Quire.Icon.trash) { undo.undo() }
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
        retryLineTimer?.invalidate()
        listPane.toasts.dismiss()
        if UndoSendPanel.undoKeyArbiter === self { UndoSendPanel.undoKeyArbiter = nil }
        crossFadeOverlay?.orderOut(nil)
        crossFadeOverlay = nil
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
        (splitController.splitView as? HairlineSplitView)?.onThicknessChange = { [weak self] in self?.applyRailWidth() }
    }

    /// The rail is exactly as wide as the lights need (76 on macOS 15, 84 from 26 on), its trailing hairline
    /// included (§3.2): the split's divider is that hairline, so the rail's own pane is one hairline narrower.
    private func applyRailWidth() {
        let width = chrome.railWidth
        strip.railWidth = width
        let pane = width - splitController.splitView.dividerThickness
        stripItem?.minimumThickness = pane
        stripItem?.maximumThickness = pane
    }

    /// A first run has no autosaved divider positions; the list then starts at its preferred width.
    private let isFirstSplitLayout = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MainSplit") == nil

    /// `--snapshot` and the other window snapshots (`LaunchOptions.isWindowSnapshot`): the window keeps the
    /// default size and divider positions and ignores the pointer, so it compares with the specimen and never
    /// rewrites the user's saved frame.
    private let isSnapshot = LaunchOptions().isWindowSnapshot

    private var isMinimal: Bool { stripItem?.isCollapsed ?? false }

    private var didPlaceDividers = false

    /// With no saved positions (a first run, or a snapshot) the list starts at its default 364 pt. Done once the
    /// split is in the window, which after the welcome screen is only when the first account arrives.
    private func placeDividersIfNeeded() {
        guard !didPlaceDividers, isSnapshot || isFirstSplitLayout else { return }
        didPlaceDividers = true
        splitController.splitView.layoutSubtreeIfNeeded()
        // The list's 364 includes its own trailing hairline, as the rail's width includes the rail's.
        let split = splitController.splitView
        split.setPosition(chrome.railWidth + ListPaneViewController.preferredWidth - split.dividerThickness, ofDividerAt: 1)
    }

    /// Minimal mode (§5.1): the masthead moves past the would-be rail and becomes the title menu (the views and
    /// the accounts the rail held), and the new-mail dot may show. Search and compose keep the header line.
    private func applyMinimalMode() {
        listPane.setMinimalMode(isMinimal, mastheadX: isMinimal ? chrome.mastheadMinimalX : Quire.Layout.ListHeader.mastheadX)
        updateNewMailDot()
    }

    private func wireCallbacks() {
        strip.onSelect = { [weak self] scope in self?.scopeChanged(scope) }
        strip.onSelectView = { [weak self] view in self?.setView(view) }
        strip.onAddAccount = { [weak self] kind in self?.requestAddAccount(kind) }
        strip.onOpenSettings = { [weak self] in self?.onOpenSettings?() }

        listPane.onViewChange = { [weak self] view in self?.setView(view) }
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

        list.onSelectionChange = { [weak self] _ in self?.listSelectionDidChange() }
        list.onSelectionSetChange = { [weak self] _ in self?.listSelectionDidChange() }
        list.rowMenu = { [weak self] in self?.selectionContextMenu() }
        conversation.messageMenu = { [weak self] in self?.selectionContextMenu() }
        list.onOpen = { [weak self] id in
            guard let self else { return }
            // In Drafts, ↩ and a double-click are Continue Editing (§5.19).
            if self.mailboxView == .drafts {
                if let draft = self.draftMessageID(in: id) { self.continueDraft(draft) }
                return
            }
            if self.conversation.currentConversationID != id { self.conversation.show(id) }
            self.focusReader()
        }
        list.onRowsChange = { [weak self] in self?.listPane.listRowsDidChange() }

        conversation.onAction = { [weak self] action in self?.handle(action) }
        conversation.onQuickSendChange = { UndoSendPanel.refreshUndoKeyOwner() }
        conversation.localDrafts = localDrafts
        conversation.isDraftInComposer = { ComposeWindowRegistry.shared.controller(holdingDraft: $0) != nil }
        list.localMessages = { [weak self] id in self?.localDrafts.messages(in: id) }
        localDrafts.onChange = { [weak self] in
            self?.showLocalDrafts()
            self?.conversation.draftsDidChange()
        }

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
        notifier.conversationOpenInKeyWindow = { [weak self] in
            guard let self, self.window?.isKeyWindow == true else { return nil }
            return self.conversation.currentConversationID
        }
        activity.onChange = { [weak self] in self?.refreshSyncLine() }
        // Back online: check now rather than when the engine's backoff next allows.
        activity.onNetworkReturned = { [weak self] in self?.checkAllAccounts() }
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
            localDrafts.accounts = fresh
            showLocalDrafts()
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
        // The welcome as it last looked, for the cross-fade to the inbox after a successful add (§5.39).
        let outgoing = wantsWelcome || !window.isVisible || isSnapshot ? nil : Self.snapshot(of: window)
        // Swapping the content controller resizes the window to the new view; keep the user's frame.
        let frame = window.frame
        window.contentViewController = wantsWelcome ? welcome : splitController
        window.setFrame(frame, display: true)
        if !wantsWelcome {
            placeDividersIfNeeded()
            focusList()
            if let outgoing { crossFade(from: outgoing, over: window) }
        }
    }

    /// The window as drawn now, title-bar zone and traffic lights included.
    private static func snapshot(of window: NSWindow) -> NSImage? {
        guard let view = window.contentView?.superview ?? window.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(bitmap)
        return image
    }

    /// The overlay a cross-fade is drawing, while it runs.
    private(set) var crossFadeOverlay: NSWindow?

    /// Success on the welcome screen: the inbox, already laid out with its skeleton, shows through as the
    /// welcome's last frame fades out over `dur.slow` (`ease.settle`; a short fade under Reduce Motion). The
    /// old frame sits in a borderless child window that takes no clicks, so the split view is live from the
    /// first frame, and a key press (`Quire.Motion.finishAll()`) ends the fade at once.
    private func crossFade(from image: NSImage, over window: NSWindow) {
        crossFadeOverlay?.orderOut(nil)
        let overlay = NSWindow(contentRect: window.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        overlay.isReleasedWhenClosed = false
        overlay.isOpaque = false
        overlay.backgroundColor = .clear
        overlay.hasShadow = false
        overlay.ignoresMouseEvents = true
        overlay.animationBehavior = .none
        let imageView = NSImageView(frame: NSRect(origin: .zero, size: window.frame.size))
        imageView.image = image
        imageView.imageScaling = .scaleAxesIndependently
        overlay.contentView = imageView
        window.addChildWindow(overlay, ordered: .above)
        crossFadeOverlay = overlay
        Quire.Motion.run(Quire.Motion.slow, .settle, reduced: .fade, animations: { _ in
            overlay.animator().alphaValue = 0
        }, completion: { [weak self, weak window] in
            window?.removeChildWindow(overlay)
            overlay.orderOut(nil)
            if self?.crossFadeOverlay === overlay { self?.crossFadeOverlay = nil }
        })
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
            announce("\(AccountLabels.name(for: account)) reconnected.")
        }
    }

    /// The statuses the rail and the sync line draw from.
    private var effectiveStatuses: [AccountSyncStatus] {
        #if DEBUG
        if let debugStatuses { return debugStatuses }
        #endif
        return statuses
    }

    @objc private func signInProgressChanged(_ note: Notification) {
        applySignIn(note.object as? SignInProgress)
    }

    /// The browser sign-in that is really running, wherever it started (the rail, the welcome, File › Add…,
    /// the sync line, Settings): the welcome's waiting button, the rail's pending tile (an add) or its
    /// reconnecting tooltip, and the sync line's waiting state with Cancel follow it (§5.44). Success is told
    /// apart from Cancel by the accounts that arrive and by `reconnectDidSucceed`, never by timing.
    func applySignIn(_ progress: SignInProgress?) {
        welcome.showSignIn(progress)
        let next = progress.map { $0.reconnecting.map(PendingSignIn.reconnecting) ?? .adding($0.kind) }
        guard next != pendingSignIn else { return }
        if pendingSignIn != nil, next == nil { signInEndedAt = Date() }
        pendingSignIn = next
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
        case nil: strip.setSignIn(active: false, adding: false, reconnecting: nil)
        }
        listPane.statusBar.actionsEnabled = pendingSignIn == nil
        refreshSyncLine()
    }

    private func requestAddAccount(_ kind: ProviderKind) {
        guard pendingSignIn == nil else { return }
        onAddAccount?(kind)
    }

    private func requestReconnect(_ account: Account) {
        guard pendingSignIn == nil else { return }
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
        case nil: signIn = nil
        }
        let now = Date()
        let summary = SyncLineSummary.make(SyncLineSummary.Input(
            statuses: effective, accounts: accounts, isDemo: environment.isDemo, isNetworkReachable: activity.isNetworkReachable,
            signIn: signIn, sendingCount: activity.sendingCount, isChecking: isCheckRunning, now: now
        ))
        listPane.statusBar.apply(summary)
        // “retrying in 30 s” counts down: the line is chosen again each second while a retry is ahead.
        let retryAhead = effective.contains { ($0.retryAt ?? .distantPast) > now }
        if retryAhead, retryLineTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSyncLine() }
            }
            RunLoop.main.add(timer, forMode: .common)
            retryLineTimer = timer
        } else if !retryAhead {
            retryLineTimer?.invalidate()
            retryLineTimer = nil
        }
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
    }

    /// Narrowed to one account, the masthead names its address (§5.3) and the rail's Inbox counts its mail.
    private func updateScopeDetails() {
        if case .account(let id) = scope, let account = accountsByID[id] {
            listPane.setNarrowedAccount(address: account.email, name: AccountLabels.name(for: account))
        } else {
            listPane.setNarrowedAccount(address: nil, name: nil)
        }
        strip.setInboxUnread(inboxUnread)
        updateNewMailDot()
    }

    private func countsChanged(unified: Int, perAccount: [AccountID: Int]) {
        unifiedUnread = unified
        unreadByAccount = perAccount
        strip.setUnreadCounts(unified: unified, perAccount: perAccount)
        strip.setInboxUnread(inboxUnread)
        updateNewMailDot()
    }

    /// The unread Inbox count of the current scope (all accounts, or the narrowed one): the rail's Inbox badge and
    /// the title menu's Inbox item (§5.2, §5.4).
    private var inboxUnread: Int {
        if case .account(let id) = scope { return unreadByAccount[id] ?? 0 }
        return unifiedUnread
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
        let monograms = AccountLabels.monograms(for: accounts)
        return TitleMenu.Model(
            view: mailboxView, inboxUnread: inboxUnread, scope: scope, showsAccounts: isMinimal, unifiedUnread: unifiedUnread,
            accounts: accounts.map { TitleMenu.AccountEntry(account: $0, monogram: monograms[$0.id] ?? "?", unread: unreadByAccount[$0.id] ?? 0) }
        )
    }

    /// Picking a mailbox means "show me that mailbox", so it also ends a search that would otherwise keep
    /// overriding the view.
    private func setView(_ view: MailboxView) {
        mailboxView = view
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
        let query = ShellQuery.make(scope: scope.accountIDs, view: mailboxView, searchText: searchText)
        if query != list.query {
            // A selection carried into another list would be handed to whatever row replaced it there, and the
            // reader would open (and mark read) a conversation the user never picked.
            if list.selectedConversationID != nil || !shownSelection.isEmpty {
                list.selectedConversationID = nil
                present(selection: [])
            }
            list.query = query
        } else {
            // The same query (a trailing space, say) brings no new rows; the field must not wait for them.
            listPane.listRowsDidChange()
        }
        listPane.display(view: mailboxView)
        strip.selectView(mailboxView, notify: false)
    }

    // MARK: Selection

    /// The list reports its lead and its whole selection separately; both land here and the reader is told
    /// once. Two or more selected show the reader's several-selected state (§5.19).
    private func listSelectionDidChange() {
        let ids = list.selectedConversationIDs
        let selection = ids.count > 1 ? ids : (list.selectedConversationID ?? ids.first).map { [$0] } ?? []
        guard selection != shownSelection else { return }
        present(selection: selection)
    }

    /// Shows `ids` in the reader: nothing, one conversation (pre-rendering its neighbours), or several.
    private func present(selection ids: [ConversationID]) {
        shownSelection = ids
        acknowledgeTimer?.invalidate()
        acknowledgeTimer = nil
        guard ids.count < 2 else {
            conversation.showSelection(ids)
            return
        }
        conversation.show(ids.first)
        guard let id = ids.first else { return }
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
        present(selection: [first])
        #if DEBUG
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--snapshot-state=") && $0.contains("several") }) {
            let ids = Array(list.conversations.prefix(3).map(\.id))
            list.selectConversations(ids, lead: ids.last)
            present(selection: ids)
        }
        #endif
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
        applyQuery()
        list.selectedConversationID = id
        present(selection: [id])
    }

    private var selectedSummary: ConversationSummary? {
        guard let id = list.selectedConversationID else { return nil }
        return list.conversations.first { $0.id == id }
    }

    /// Every selected conversation in list order: what E, #, S, U, ⇧I and the Message menu act on.
    private var selectedIDs: [ConversationID] { list.selectedConversationIDs }

    private var selectedSummaries: [ConversationSummary] {
        let ids = Set(selectedIDs)
        guard ids.count > 1 else { return selectedSummary.map { [$0] } ?? [] }
        return list.conversations.filter { ids.contains($0.id) }
    }

    /// Two or more conversations are selected: replies have no single target (§5.12).
    private var isSeveralSelected: Bool { selectedIDs.count > 1 }

    /// S on the selection: stars all unless every one is starred, then unstars all (§5.12's all-starred rule).
    private var starChangeForSelection: MetadataChange? {
        let summaries = selectedSummaries
        guard !summaries.isEmpty else { return nil }
        return .setStarred(!summaries.allSatisfy(\.isStarred))
    }

    /// U on the selection: marks read when every selected conversation is unread, otherwise marks unread.
    private var readChangeForSelection: MetadataChange? {
        let summaries = selectedSummaries
        guard !summaries.isEmpty else { return nil }
        return .setRead(summaries.allSatisfy { $0.unreadCount > 0 })
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
        case .extendNext:
            list.extendSelection(by: 1)
            return true
        case .extendPrevious:
            list.extendSelection(by: -1)
            return true
        case .open:
            // Several selected have nothing single to open; the key is spent all the same.
            guard !isSeveralSelected else { return true }
            guard let id = list.selectedConversationID else { return false }
            list.onOpen?(id)
            return true
        case .archive:
            return mailAction(.archive)
        case .toggleStar:
            guard let change = starChangeForSelection else { return false }
            return mailAction(change)
        case .toggleRead:
            guard let change = readChangeForSelection else { return false }
            return mailAction(change)
        case .trash:
            // In Drafts, # is Discard Draft…, asked first (§5.12).
            if mailboxView == .drafts {
                confirmDiscardDrafts(selectedIDs)
                return true
            }
            // In Trash the conversation is already there and v1 has no Delete Forever: # does nothing, quietly,
            // and never trashes the rest of a conversation only partly in Trash (§5.12).
            if mailboxView == .trash { return true }
            return mailAction(.trash)
        case .reply, .replyAll, .forward:
            // A reply answers one conversation: with several selected R, A and F do nothing (§5.12).
            if isSeveralSelected { return true }
            switch command {
            case .reply:
                // R and A focus the reader's quick reply where it shows; elsewhere they open the composer (§5.18).
                return conversation.focusQuickReply(all: false) || composeReply(all: false)
            case .replyAll:
                return conversation.focusQuickReply(all: true) || composeReply(all: true)
            default:
                return composeForward()
            }
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
            // The router acts only outside text, so typing is never ⌘Z's target here; Z never cancels a send.
            let commandZ = NSApp.currentEvent?.modifierFlags.contains(.command) == true
            performUndo(commandZ ? commandZTarget(textCanUndo: false) : zTarget)
            return true
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

    /// Applies a change to `ids` (the selection when nil) and remembers how to undo it, as one step: several
    /// selected conversations make one toast (“Archived 3 conversations”) and one undo (§5.19). Actions that
    /// take rows out of the view say so in a toast with Undo; several within 1000 ms coalesce (§5.30).
    @discardableResult
    private func mailAction(_ change: MetadataChange, on ids: [ConversationID]? = nil) -> Bool {
        let targets = ids ?? selectedIDs
        guard !targets.isEmpty else { return false }
        let store = environment.store
        var records: [MailActionRecord] = []
        for id in targets {
            guard let all = try? store.messages(in: id), !all.isEmpty else { continue }
            let kind = accountsByID[id.accountID]?.kind ?? .gmail
            let messages = MailActionRecord.targets(for: change, in: all, kind: kind)
            if let record = MailActionRecord.make(change, on: messages, conversation: id) { records.append(record) }
        }
        guard !records.isEmpty else {
            // Archive in the Trash, star on nothing: say so rather than appear to ignore the key.
            NSSound.beep()
            return true
        }
        do {
            // One call: the store applies each account's share in one transaction, so the rows leave together.
            try environment.engine.perform(change, on: records.flatMap(\.targets))
        } catch {
            Self.log.error("mail action failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return true
        }
        recordUndo(records, change: change)
        return true
    }

    /// A toast's Undo reverts the group that toast offers, whatever happened since; Z and ⌘Z follow
    /// `UndoPrecedence`.
    private func recordUndo(_ records: [MailActionRecord], change: MetadataChange) {
        let now = Date()
        let toasts = listPane.toasts
        defer { UndoSendPanel.refreshUndoKeyOwner() }
        if let group = undoHistory.coalesce(records, at: now, visibleToastID: toasts.visibleID) {
            let id = group.id
            toasts.show(MailActionCopy.toast(for: change, count: group.records.count), kind: .undoable,
                        symbol: symbol(for: change), actionTitle: "Undo", keycap: "Z",
                        updating: group.toastID) { [weak self] in self?.undo(groupID: id) }
            return
        }
        // No toast for a change the row itself shows; Z still reaches it for the grace period.
        let toasted = MailActionCopy.wantsToast(for: change, in: mailboxView, isSearching: !searchText.isEmpty, count: records.count)
        let id = undoHistory.add(records, at: now, toasted: toasted)
        guard toasted else { return }
        let toastID = toasts.show(MailActionCopy.toast(for: change, count: records.count), kind: .undoable, symbol: symbol(for: change),
                                  actionTitle: "Undo", keycap: "Z") { [weak self] in self?.undo(groupID: id) }
        undoHistory.bindToast(toastID, to: id)
    }

    /// A step that is not a mail action, offered by its own toast and reverted by `revert` (§5.20).
    private func recordExternalUndo(command: String, toast message: String, symbol: String, revert: @escaping () -> Void) {
        let id = undoHistory.addExternal(command: command, at: Date(), toasted: true)
        externalUndos[id] = revert
        let toastID = listPane.toasts.show(message, kind: .undoable, symbol: symbol, actionTitle: "Undo", keycap: "Z") { [weak self] in
            self?.undo(groupID: id)
        }
        undoHistory.bindToast(toastID, to: id)
        // Groups that fell out of the history no longer need their reverts.
        let live = Set(undoHistory.groups.map(\.id))
        externalUndos = externalUndos.filter { live.contains($0.key) }
        UndoSendPanel.refreshUndoKeyOwner()
    }

    /// A toast stopped being visible: Z and ⌘Z reach its action for 10000 ms more (§6.1), and an undo-send
    /// panel it outranked takes ⌘Z back.
    private func toastEnded(_ id: Int, reason: ToastPresenter.End) {
        undoHistory.toastEnded(id, at: Date())
        UndoSendPanel.refreshUndoKeyOwner()
    }

    // MARK: Undo order (§6.1)

    /// The group the visible toast offers.
    private var visibleToastGroup: UndoPrecedence.ToastGroup? {
        undoHistory.toastGroup(visibleToastID: listPane.toasts.visibleID).map { .init(groupID: $0.id, actedAt: $0.lastActionAt) }
    }

    /// Every send ⌘Z can still cancel: the composers' panels counting down and the quick reply's countdown.
    private var liveSends: [UndoPrecedence.LiveSend] {
        UndoSendPanel.liveSends + (conversation.liveQuickSend.map { [$0] } ?? [])
    }

    /// ⌘Z and Edit › Undo: typing, then the newest live send or toast, then a toast's action in its grace.
    func commandZTarget(textCanUndo: Bool) -> UndoPrecedence.Target {
        UndoPrecedence.commandZ(textCanUndo: textCanUndo, sends: liveSends, toast: visibleToastGroup,
                                graceGroup: undoHistory.graceGroup(at: Date())?.id)
    }

    /// Z and Message › Undo: only ever the latest toast's action.
    var zTarget: UndoPrecedence.Target {
        UndoPrecedence.z(toast: visibleToastGroup, graceGroup: undoHistory.graceGroup(at: Date())?.id)
    }

    func sendOwningCommandZ() -> String? {
        UndoPrecedence.sendOwningCommandZ(sends: liveSends, toast: visibleToastGroup)
    }

    /// Edit › Undo's title for `target`: “Undo Typing”, “Undo Send”, “Undo Archive”, “Can't Undo”.
    func undoMenuTitle(for target: UndoPrecedence.Target) -> String {
        switch target {
        case .typing: return window?.undoManager?.undoMenuItemTitle ?? "Undo"
        case .send: return "Undo Send"
        case .group(let id):
            guard let group = undoHistory.groups.last(where: { $0.id == id }) else { return "Can't Undo" }
            if let change = group.change { return MailActionCopy.undoMenuTitle(for: change) }
            return "Undo " + (group.externalCommand ?? "")
        case .nothing: return "Can't Undo"
        }
    }

    func performUndo(_ target: UndoPrecedence.Target) {
        switch target {
        case .typing:
            window?.undoManager?.undo()
        case .send(let id):
            if conversation.liveQuickSend?.id == id {
                _ = conversation.cancelQuickSend()
            } else if let panel = UndoSendPanel.panel(sendID: id) {
                panel.undo()
            }
        case .group(let id):
            undo(groupID: id)
        case .nothing:
            NSSound.beep()
        }
    }

    /// Edit › Undo (⌘Z) from the main window, wherever focus is: the menu item and the key reach the same target.
    func performEditUndo() {
        performUndo(commandZTarget(textCanUndo: textCanUndo))
    }

    func validateEditUndo(_ item: NSMenuItem) -> Bool {
        let target = commandZTarget(textCanUndo: textCanUndo)
        item.title = undoMenuTitle(for: target)
        return target != .nothing
    }

    /// Row 1 of §6.1: a text view or field has focus and its undo manager can undo.
    private var textCanUndo: Bool {
        KeyboardRouter.isTextInput(window?.firstResponder) && window?.undoManager?.canUndo == true
    }

    /// Brings the selected conversations back to the inbox: out of the trash when there, else out of the archive.
    @discardableResult
    private func moveSelectionToInbox() -> Bool {
        mailAction(.moveToInbox)
    }

    @discardableResult
    private func undo(groupID: Int) -> Bool {
        guard let group = undoHistory.remove(groupID) else {
            NSSound.beep()
            return true
        }
        defer { UndoSendPanel.refreshUndoKeyOwner() }
        guard let change = group.change else {
            externalUndos.removeValue(forKey: groupID)?()
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
        listPane.toasts.show(MailActionCopy.undoConfirmation(for: change), kind: .confirmation, symbol: Quire.Icon.undone)
        let restored = group.records.compactMap(\.conversation)
        if !restored.isEmpty, [.archive, .trash, .moveToInbox, .restoreFromTrash].contains(change) {
            // The rows come back; put the selection on them so the user sees what was restored.
            list.selectConversations(restored, lead: restored.last)
            present(selection: restored.count > 1 ? restored : [restored[0]])
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

    /// The reader's actions (`ConversationViewController.onAction`); internal so the app's tests can send them.
    func handle(_ action: ConversationAction) {
        switch action {
        case .reply(let id):
            compose(.reply(id, all: false), accountID: id.accountID)
        case .replyAll(let id):
            compose(.reply(id, all: true), accountID: id.accountID)
        case .forward(let id):
            compose(.forward(id), accountID: id.accountID)
        case .archive(let id):
            mailAction(.archive, on: [id])
        case .star(let id, let starred):
            mailAction(.setStarred(starred), on: [id])
        case .trash(let id):
            mailAction(.trash, on: [id])
        case .moveToInbox(let id):
            mailAction(.moveToInbox, on: [id])
        case .applyToSelection(let change, let ids):
            mailAction(change, on: ids)
        case .openAttachment:
            // The reader already opened Quick Look.
            break
        case .continueDraft(let id):
            continueDraft(id)
        case .discardDrafts(let ids):
            confirmDiscardDrafts(ids)
        case .reveal(let id):
            reveal(id)
        case let .replyInComposer(id, all, body, attach):
            guard let account = accounts.first(where: { $0.id == id.accountID }) ?? accounts.first else { return }
            ComposeWindowController.present(client: environment.engine, account: account, accounts: accounts, mode: .reply(id, all: all),
                                            body: body, attach: attach)
        case .quickReplyFailed(let draft):
            // §5.18: the bar is not involved; the draft is already kept, so this toast only points at it.
            let engine = environment.engine
            listPane.toasts.show("Couldn\u{2019}t send your reply", kind: .error, symbol: Quire.Icon.error, actionTitle: "Open draft") { [weak self] in
                guard let self else { return }
                ComposeWindowController.present(client: engine, accounts: self.accounts, draft: draft)
            }
        case .escapeQuickReply:
            // §6.1: a visible toast takes the first Esc; the next returns to the list, the bar keeping its text.
            if listPane.toasts.isVisible {
                listPane.toasts.dismiss()
            } else {
                focusList()
            }
        }
    }

    // MARK: Drafts (§5.19)

    /// The Drafts view lists the kept drafts beside the provider's; a provider's draft that a kept one continues
    /// gives way to it.
    private func showLocalDrafts() {
        list.localDrafts = localDrafts.summaries
        let store = environment.store
        list.hiddenDrafts = Set(localDrafts.continuedDrafts.compactMap { try? store.message($0)?.conversationID })
    }

    /// The draft a Drafts row stands for: a kept draft's own message, or the conversation's newest draft.
    private func draftMessageID(in id: ConversationID) -> MessageID? {
        if let draftID = LocalDraftConversation.draftID(of: id) {
            return LocalDraftConversation.messageID(draftID: draftID, account: id.accountID)
        }
        let messages = (try? environment.store.messages(in: id)) ?? []
        return (messages.last { $0.roles.contains(.drafts) } ?? messages.last)?.id
    }

    /// Continue Editing: a kept draft reopens as it was left (its window comes forward if open), so sending it
    /// leaves nothing behind; a provider's draft goes through `DraftReopener`.
    private func continueDraft(_ id: MessageID) {
        if let draftID = LocalDraftConversation.draftID(of: id) {
            if !ComposeWindowController.reopenKeptDraft(id: draftID, client: environment.engine, accounts: accounts) { NSSound.beep() }
            return
        }
        DraftReopener.present(id, client: environment.engine, accounts: accounts)
    }

    /// “Discard this draft?” (or “Discard 3 drafts?”), the reader's form (§5.33), from the header, the sheet's
    /// footer or #.
    private func confirmDiscardDrafts(_ ids: [ConversationID]) {
        guard !ids.isEmpty else { return }
        let recipient = ids.count == 1 ? draftMessageID(in: ids[0]).flatMap(draftRecipient(of:)) : nil
        AppAlert.discardDrafts(count: ids.count, recipient: recipient).present(on: window) { [weak self] choice in
            if choice == 1 { self?.discardDrafts(ids) }
        }
    }

    private func draftRecipient(of id: MessageID) -> String? {
        let message = LocalDraftConversation.isLocal(id)
            ? localDrafts.messages(in: ConversationID(accountID: id.accountID, providerID: id.providerID))?.first
            : try? environment.store.message(id)
        guard let first = message.flatMap({ $0.to.first ?? $0.cc.first ?? $0.bcc.first }) else { return nil }
        return QuotedReply.authorName(first)
    }

    /// Discards confirmed drafts as one step with one toast, “Draft discarded · Undo” (§5.19): kept drafts leave
    /// this Mac (a composer holding one closes, keeping nothing), the provider's go to Trash. Undo brings back
    /// both.
    func discardDrafts(_ ids: [ConversationID]) {
        var kept: [ComposeDraft] = []
        var records: [MailActionRecord] = []
        for id in ids {
            if let draftID = LocalDraftConversation.draftID(of: id) {
                guard let draft = localDrafts.draft(draftID) else { continue }
                kept.append(draft)
                ComposeWindowRegistry.shared.openControllers.first { $0.draftID == draftID }?.closeWithoutSaving()
                ComposeDraftStore.shared.remove(id: draftID)
            } else if let all = try? environment.store.messages(in: id), !all.isEmpty {
                let kind = accountsByID[id.accountID]?.kind ?? .gmail
                let targets = MailActionRecord.targets(for: .trash, in: all, kind: kind)
                if let record = MailActionRecord.make(.trash, on: targets, conversation: id) { records.append(record) }
            }
        }
        do {
            if !records.isEmpty { try environment.engine.perform(.trash, on: records.flatMap(\.targets)) }
        } catch {
            Self.log.error("discarding drafts failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
        let count = kept.count + records.count
        guard count > 0 else {
            NSSound.beep()
            return
        }
        let engine = environment.engine
        recordExternalUndo(command: "Discard Draft", toast: count == 1 ? "Draft discarded" : "Discarded \(count) drafts",
                           symbol: Quire.Icon.trash) {
            for draft in kept { ComposeDraftStore.shared.save(draft) }
            do {
                for record in records.reversed() {
                    for step in record.inverse { try engine.perform(step.change, on: step.targets) }
                }
            } catch {
                Self.log.error("bringing back drafts failed: \(String(describing: error), privacy: .public)")
            }
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

    // MARK: Context menu (§5.35)

    /// Rows and messages share one menu acting on the selection: Reply · Reply All · Forward · — · Archive ·
    /// Star · Mark as Unread · Move to Inbox · — · Move to Trash, each with its symbol and shortcut. Items
    /// that do not apply stay visible, disabled, through the same validation as the Message menu, so the two
    /// never disagree.
    func selectionContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Conversation")
        let items: [NSMenuItem] = [
            MainMenu.item("Reply", #selector(replyToSelection(_:)), "r", [], symbol: Quire.Icon.reply, target: self),
            MainMenu.item("Reply All", #selector(replyAllToSelection(_:)), "a", [], symbol: Quire.Icon.replyAll, target: self),
            MainMenu.item("Forward", #selector(forwardSelection(_:)), "f", [], symbol: Quire.Icon.forward, target: self),
            .separator(),
            MainMenu.item("Archive", #selector(archiveSelection(_:)), "e", [], symbol: Quire.Icon.archive, target: self),
            MainMenu.item("Star", #selector(toggleStarSelection(_:)), "s", [], symbol: Quire.Icon.star, target: self),
            MainMenu.item("Mark as Unread", #selector(markSelectionUnread(_:)), "u", [], symbol: Quire.Icon.markUnread, target: self),
            MainMenu.item("Move to Inbox", #selector(moveSelectionToInbox(_:)), "I", [.shift], symbol: Quire.Icon.moveToInbox, target: self),
            .separator(),
            MainMenu.item("Move to Trash", #selector(trashSelection(_:)), "#", [], symbol: Quire.Icon.trash, target: self),
        ]
        items.forEach(menu.addItem)
        return menu
    }

    // MARK: Menu actions (first responder)

    @objc func archiveSelection(_ sender: Any?) { mailAction(.archive) }
    @objc func trashSelection(_ sender: Any?) { mailAction(.trash) }
    @objc func moveSelectionToInbox(_ sender: Any?) { moveSelectionToInbox() }
    @objc func toggleStarSelection(_ sender: Any?) {
        if let change = starChangeForSelection { mailAction(change) }
    }
    @objc func markSelectionUnread(_ sender: Any?) {
        if let change = readChangeForSelection { mailAction(change) }
    }
    @objc func replyToSelection(_ sender: Any?) { _ = composeReply(all: false) }
    @objc func replyAllToSelection(_ sender: Any?) { _ = composeReply(all: true) }
    @objc func forwardSelection(_ sender: Any?) { _ = composeForward() }
    /// Message › Undo (Z): the latest toast's action, never a send (§6.1).
    @objc func undoMailAction(_ sender: Any?) { performUndo(zTarget) }
    @objc func focusSearchField(_ sender: Any?) { listPane.focusSearch() }

    // The reader's menu commands (§5.35) answer from anywhere in the main window, not only while focus is in
    // the reader, whose controller is in the responder chain only then. Validation is the reader's.
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

    @objc func selectAccountShortcut(_ sender: Any?) {
        guard let item = sender as? NSMenuItem else { return }
        strip.selectShortcut(item.tag)
    }

    @objc func goToMailboxView(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, MailboxView.allCases.indices.contains(item.tag) else { return }
        setView(MailboxView.allCases[item.tag])
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
        if let action = menuItem.action, Self.readerCommands.contains(action) {
            return !showingWelcome && conversation.validateMenuItem(menuItem)
        }
        switch menuItem.action {
        case #selector(archiveSelection(_:)):
            // Plain-letter and ⌘⌫ equivalents must not fire while the user is typing.
            return !showingWelcome && !typing && list.selectedConversationID != nil
        case #selector(toggleStarSelection(_:)):
            if case .setStarred(let star)? = starChangeForSelection { menuItem.title = star ? "Star" : "Unstar" }
            return !showingWelcome && !typing && list.selectedConversationID != nil
        case #selector(trashSelection(_:)):
            // Already in Trash (§5.12): Message › Move to Trash is disabled there.
            return !showingWelcome && !typing && list.selectedConversationID != nil && mailboxView != .trash
        case #selector(moveSelectionToInbox(_:)):
            // Everything in the Inbox view is in the Inbox already.
            return !showingWelcome && !typing && list.selectedConversationID != nil && mailboxView != .inbox
        case #selector(markSelectionUnread(_:)):
            if case .setRead(let read)? = readChangeForSelection {
                menuItem.title = read ? "Mark as Read" : "Mark as Unread"
            }
            return !showingWelcome && list.selectedConversationID != nil
        case #selector(replyToSelection(_:)), #selector(replyAllToSelection(_:)), #selector(forwardSelection(_:)):
            // A reply answers one conversation (§5.12).
            return !showingWelcome && list.selectedConversationID != nil && !isSeveralSelected
        case #selector(undoMailAction(_:)):
            // Titled by its target, as Edit › Undo is (§6.1).
            let target = zTarget
            menuItem.title = undoMenuTitle(for: target)
            return !showingWelcome && !typing && target != .nothing
        case #selector(selectAccountShortcut(_:)):
            return !showingWelcome && (menuItem.tag == 0 || menuItem.tag <= accounts.count)
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

/// A browser sign-in the window is waiting on (§5.44), from `SignInProgress`.
enum PendingSignIn: Equatable {
    /// Adding an account of this provider: the rail shows its pending tile.
    case adding(ProviderKind)
    /// Reconnecting this account: its tile keeps the attention badge.
    case reconnecting(AccountID)
}

#if DEBUG
extension MainWindowController {
    /// `--snapshot-state=key,notkey,minimal,narrowed,adding,reconnect,signin,toast,search,focus-rail,focus-folder,
    /// focus-action,hover-demo,hover-masthead,many-accounts,ic,graphite` (debug builds; `several` is applied where the
    /// first selection is made):
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
        if states.contains("many-accounts") {
            // Six made-up accounts after the real ones, in the rail only (never the store), so a render shows the
            // account stack scrolling under the folders (§5.2).
            let extra = (1...6).map { n in
                Account(id: AccountID("snapshot-\(n)"), kind: n % 2 == 0 ? .microsoft : .gmail, email: "alex@example\(n).test",
                        displayName: "Alex Morgan", addedAt: Date(), inkSlot: accounts.count + n)
            }
            strip.setAccounts(accounts + extra)
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
            applySignIn(SignInProgress(kind: .gmail, reconnecting: nil, subject: "Gmail"))
        }
        if states.contains("reconnect"), let second {
            applySignIn(SignInProgress(kind: second.kind, reconnecting: second.id, subject: AccountLabels.name(for: second)))
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
        if states.contains("focus-folder") {
            (strip.selectedFolderTile as? QuireControl)?.displayState = .focused
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
