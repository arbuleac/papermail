import AppKit
import SSCore
import SSDesign
import WebKit
import os

/// The main window: account rail, message list and reader in a split view (the reader's pane holding the day column, or
/// the week in its place: `MainWindowController+Calendar`), or the welcome screen when there is nothing to show yet. It owns the selection (one conversation or several), routes reader actions and
/// shortcuts, opens the reader windows (§5.49) and takes their mail actions too, keeps the app's undo history with
/// them (`MailUndoCenter`, which ranks Z and ⌘Z across it, the quick replies' countdowns and the undo-send panels, §6.1),
/// and reduces every account's status into the sync line.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, KeyboardRouterTarget,
                                  SendArchiving {
    static let defaultSize = QuireWindowChrome.defaultSize
    static let minimumSize = QuireWindowChrome.minimumSize
    static let log = Logger(subsystem: "io.supersparrow.mac", category: "shell")

    let environment: AppEnvironment
    let settings: AppSettings

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
    /// Runs before a composer opened from here reads the accounts: Settings saves a signature still being edited, which
    /// re-reads them here, so the composer starts with it.
    var beforeCompose: (() -> Void)?

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
    private var readerItem: NSSplitViewItem!

    // The calendar (§5.54; MainWindowController+Calendar)
    /// What the day column, its strip and the week draw, read from the store and kept current.
    let calendarState: CalendarState
    /// The third split item: the reader with the day column at its trailing edge, or the week in the place of both.
    let desk: ReaderAndCalendarViewController
    /// The days the user chose and the selection the column last followed (spec §5.54, “It follows the mail”).
    var calendarFollow: CalendarFollow
    /// The accounts Connect still has to ask for the calendar, one after another, and the one being asked.
    var calendarConnectQueue: [Account] = []
    /// Asks `account` for the calendar permission through the app's sign-in (`AppDelegate`), which calls back with
    /// whether it was granted; wired by the app delegate.
    var onConnectCalendar: ((Account, @escaping @MainActor (Bool) -> Void) -> Void)?
    /// Opens a calendar link (Join, Open in Google Calendar, the setup guide). Tests replace it, so no test opens a browser.
    var openCalendarURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Asks the engine to read every account's calendar: the kept window (nil), or shown days outside it as well.
    /// Tests replace it to see what was asked.
    lazy var readCalendars: (DateInterval?) -> Void = { [weak self] range in
        guard let engine = self?.environment.engine else { return }
        if let range {
            engine.refreshCalendars(accountID: nil, covering: range)
        } else {
            engine.refreshCalendars(accountID: nil)
        }
    }
    /// Some calendar (the column, its strip or the week) was on screen at the last change: one coming on screen asks the
    /// engine for a fresh read.
    var wasCalendarOnScreen = false

    private let inboxMonitor: InboxMonitor
    /// Internal so the app's tests can drive the network path without a real path monitor.
    let activity: SyncActivityMonitor
    /// Checks every account at once, when the network comes back; an account waiting for sign-in keeps waiting
    /// (`MailClient.checkForMail`). Replaceable so the app's tests, whose engine never starts, can count the checks.
    lazy var checkAllAccounts: () -> Void = { [weak self] in self?.environment.engine.checkForMail() }
    /// Opens an unsubscribe page in the browser. Tests replace it, so no test opens a browser.
    var openUnsubscribePage: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// Drafts kept on this Mac, which the Drafts view lists and the reader shows beside the provider's.
    let localDrafts = LocalDrafts()
    /// Send Later's half in the window (§5.23): its messages in Drafts, and what happens when one goes, fails or was missed.
    private(set) lazy var sendLaterOutbox = SendLaterOutbox(client: environment.engine, localDrafts: localDrafts)
    /// Shows the alert about times missed while the app was closed; tests replace it to answer it.
    lazy var presentMissedSends: (AppAlert, @escaping @MainActor (Int) -> Void) -> Void = { [weak self] alert, completion in
        alert.present(on: self?.window, completion: completion)
    }
    /// The quick-reply text parked under each conversation, which this window's reader shares with its reader windows
    /// (§5.49): text typed in a window that closes is kept for the next reader to show the conversation.
    let quickReplyDrafts = QuickReplyDraftShelf()
    /// Find in conversation's words for the session, which this window's reader shares with its reader windows (§5.50).
    let findSession = FindSession()
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
    /// The view the list's rows come from: the rail's view, or while searching the one the search looks through (All
    /// Mail, or the view an `in:` term picked), so keys, menus and the reader treat results as rows of that view:
    /// `in:trash` results restore with ⇧I and # leaves them be, as in the Trash.
    var listView: MailboxView { list.query.view }
    private var searchText = ""
    private(set) var showingWelcome = false
    private var unifiedUnread = 0
    private var unreadByAccount: [AccountID: Int] = [:]
    /// Unread counts when the user last chose a scope; more than this in another account is new mail (§5.3).
    private var unreadAtScopeChange: [AccountID: Int] = [:]
    /// The scope is saved whenever it changes and the window opens on it at the next launch (the demo's apart from
    /// the real one). Off for snapshots, which neither read nor write it.
    private let remembersScope: Bool
    /// The scope an earlier launch saved, until there are accounts to check it against.
    private var scopeToRestore: AccountScope?
    /// A restored scope was chosen in an earlier launch, so the first unread counts this window sees stand for
    /// the moment it was chosen: minimal mode's dot then tells of mail that came since, not of all unread mail.
    private var scopeBaselinePending = false

    // Undo and toasts
    /// The app's undo history and its one toast, shared with the reader windows this window opens (§5.49).
    let undoCenter: MailUndoCenter
    private var undoHistory: MailActionUndoHistory {
        get { undoCenter.history }
        set { undoCenter.history = newValue }
    }
    var toasts: ToastPresenter { undoCenter.toasts }
    /// How the history's external steps are reverted (a discarded draft reopens its composer), by group id.
    private var externalUndos: [Int: () -> Void] = [:]
    /// The snoozes each E in Later ended, with their times, by group id: presses that coalesced share a group, and its
    /// one undo puts all of them back.
    private var laterArchiveRestores: [Int: [Snooze.Change]] = [:]
    /// The groups recorded in Later, which an undo returns to when Later emptied meanwhile and the view went back to
    /// the Inbox: the restored rows are in Later, and the undo selects them there.
    private var groupsFromLater: Set<Int> = []
    /// The conditional view (Later or the Outbox) the window left for the Inbox because it emptied, while the user has not
    /// picked a view or a scope since: only then does an undo of a step taken there bring it back (§5.45, §5.53). Anywhere
    /// the user went themselves, an undo leaves them there, as every other undo does.
    private var viewLeftAsItEmptied: MailboxView?
    /// What an unsubscribe's Undo confirms itself with, by group id: the request it leaves sent (§5.30).
    private var unsubscribeUndoConfirmations: [Int: String] = [:]
    /// The latest unsubscribe's request and the toast reporting it. While that toast is up, the same request asked
    /// again (a double-click's second click, ⇧⌘U again where the archived row stays listed) is not sent twice and
    /// leaves the toast, with its Undo, in place.
    private var shownUnsubscribe: (accountID: AccountID, method: UnsubscribeMethod, toastID: Int)?

    // Reader windows (§5.49)
    /// The conversations open in windows of their own, in the order they opened.
    private(set) var readerWindows: [ReaderWindowController] = []
    /// The reader window whose step is being taken, or whose step is being undone; nil for the main window's own. The mail
    /// actions read it for the view the conversation is a row of, where the toast shows and whether the window closes.
    private var actingReader: ReaderWindowPlace?
    /// Puts a window on screen as the key window: a reader window opening, or this window coming forward from one. Showing
    /// a window moves it onto a screen, so the app's tests replace it and keep theirs off screen.
    var bringForward: (NSWindowController) -> Void = { $0.showWindow(nil) }
    /// Shows an alert as a sheet on a window (`AppAlert.present`); tests replace it to answer it.
    lazy var presentAlert: (AppAlert, NSWindow?, @escaping AppAlert.Completion) -> Void = { alert, window, done in
        alert.present(on: window, completion: done)
    }

    // Later (§5.45)
    /// Every snooze the store holds, from its observation; the Later tile, G L and the title menu go by those in scope.
    private(set) var snoozes: [Snooze] = []
    private var snoozeObservation: StoreObservation?
    /// Shows the Later menu at a point in a view. A popped menu tracks until it is dismissed, so tests replace it.
    lazy var popUpLaterMenu: (NSMenu, NSPoint, NSView) -> Void = { menu, point, view in
        menu.popUp(positioning: nil, at: point, in: view)
    }
    /// Shows Pick a Date…; tests replace it to answer the sheet.
    lazy var presentLaterDatePicker: (LaterDatePicker, NSWindow?, @escaping @MainActor (Date?) -> Void) -> Void = { picker, window, done in
        picker.present(on: window, completion: done)
    }
    /// The clock the Later menu and its sheet read; tests fix it.
    var laterNow: () -> Date = { Date() }
    /// Writes the Later menu's times and the snooze toast's, as the rows write times.
    private let laterFormatter = DateFormatting()
    /// What the reader was last asked to show, so the list's two selection callbacks show it once.
    private(set) var shownSelection: [ConversationID] = []

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

    /// `dockBadge` nil is the app's Dock tile; tests pass their own so no window of theirs badges a real icon. `calendar` and
    /// `now` are the day column's and the week's; tests fix them.
    init(environment: AppEnvironment, settings: AppSettings, remembersScope: Bool = !LaunchOptions().isSnapshot,
         dockBadge: DockBadge? = nil, calendar: Calendar = .autoupdatingCurrent, now: @escaping () -> Date = Date.init) {
        self.environment = environment
        self.settings = settings
        // Every Send button reads the user's choice from these settings (§5.23), the reader's built below among them.
        SendActionPreference.settings = settings
        self.remembersScope = remembersScope
        scopeToRestore = remembersScope ? settings.savedAccountScope(demo: environment.isDemo) : nil
        list = MessageListViewController(store: environment.store)
        listPane = ListPaneViewController(list: list)
        conversation = ConversationViewController(client: environment.engine, drafts: quickReplyDrafts, settings: settings,
                                                  findSession: findSession)
        conversationPane = ConversationPaneViewController(conversation: conversation)
        let engine = environment.engine
        calendarState = CalendarState(store: environment.store, calendar: calendar, now: now, observeStatus: { [weak engine] onChange in
            engine?.observeStatus(onChange: onChange) ?? StoreObservation {}
        })
        calendarFollow = CalendarFollow(day: calendarState.shownDay)
        // A snapshot always shows the column, whatever the Mac's own window was left with.
        desk = ReaderAndCalendarViewController(conversationPane: conversationPane, state: calendarState,
                                               isColumnOn: LaunchOptions().isWindowSnapshot || settings.showsDayColumn)
        undoCenter = MailUndoCenter(toasts: listPane.toasts)
        inboxMonitor = InboxMonitor(store: environment.store, dockBadge: dockBadge)
        activity = SyncActivityMonitor(store: environment.store)
        notifier = NewMailNotifier(settings: settings)

        let window = MainWindow(contentRect: NSRect(origin: .zero, size: QuireWindowChrome.defaultSize),
                                styleMask: QuireWindowChrome.mainStyleMask, backing: .buffered, defer: false)
        QuireWindowChrome.configureMainWindow(window, title: environment.isDemo ? "SuperSparrow Demo" : "SuperSparrow")
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
        window.calendarKeyViews = { [weak self] in self?.calendarKeyViews ?? [] }
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
        snoozeObservation = environment.store.observeSnoozes { [weak self] snoozes in
            MainActor.assumeIsolated { self?.snoozesChanged(snoozes) }
        }
        sendLaterOutbox.onMissed = { [weak self] sends in self?.askAboutMissedSends(sends) }
        sendLaterOutbox.onFailed = { [weak self] draft, lastError in self?.sendFailed(draft, lastError: lastError) }
        sendLaterOutbox.start()
        let router = KeyboardRouter(target: self)
        router.install()
        self.router = router
        listPane.setDemo(environment.isDemo)
        refreshSyncLine()
        undoCenter.readers = { [weak self] in
            guard let self else { return [] }
            return [self.conversation] + self.readerWindows.map(\.conversation)
        }
        undoCenter.revertGroup = { [weak self] id in self?.undo(groupID: id) }
        UndoSendPanel.undoKeyArbiter = undoCenter
        SendArchive.archiver = self
        NotificationCenter.default.addObserver(self, selector: #selector(composeDraftDiscarded(_:)),
                                               name: ComposeWindowController.draftDiscardedNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(sendLaterScheduled(_:)),
                                               name: SendLaterScheduled.didSchedule, object: nil)
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
        for reader in readerWindows { reader.conversation.composersDidChange() }
    }

    /// A composer's Message › Discard Draft… confirms here: “Draft discarded · Undo” (spec §5.20). It joins the
    /// window's undo history like a mail action, so Z and ⌘Z reach it in the order of §6.1, and its Undo
    /// reopens the composer with the draft.
    @objc private func composeDraftDiscarded(_ note: Notification) {
        guard let undo = note.userInfo?[ComposeWindowController.draftUndoKey] as? ComposeDraftUndo else { return }
        recordExternalUndo(command: "Discard Draft", accounts: undo.accountID.map { [$0] } ?? [], toast: "Draft discarded",
                           symbol: Quire.Icon.trash) { undo.undo() }
    }

    /// A composer or the quick reply scheduled a message (§5.23): “Sends Tue 09:00 · Undo”, joining the window's undo
    /// history like a mail action, so Z and ⌘Z reach it in the order of §6.1. Undo takes the schedule back and returns the
    /// message to where it was written. Only the window of the engine that holds the send answers.
    @objc private func sendLaterScheduled(_ note: Notification) {
        guard let scheduled = note.userInfo?[SendLaterScheduled.userInfoKey] as? SendLaterScheduled,
              let send = (try? environment.store.pendingSendSummaries())?.first(where: { $0.id == scheduled.sendID }) else { return }
        let time = laterFormatter.dueTime(for: scheduled.date, reference: laterFormatter.reference(now: laterNow()))
        let fromWindow = (note.object as? ConversationViewController).flatMap { source in
            readerWindows.first { $0.conversation === source }
        }
        let windowConversation = fromWindow?.conversationID
        weak let windowReader = fromWindow?.conversation
        weak let controller = self
        let record = {
            self.recordExternalUndo(command: SendLaterCopy.command, accounts: [send.accountID], toast: SendLaterCopy.sends(time),
                                    symbol: Quire.Icon.later) {
                // Gone already (a deeper ⌘Z after its time): nothing was taken back, so no reply comes back either.
                guard scheduled.undo() else { return }
                Analytics.send(.sendUndone(.sendLater))
                // Its window has closed since (⌘W keeps no frame for an undo to open it again at): the reply's text is
                // parked under its conversation, so a reader showing that conversation takes it, or the main window's
                // says it was not sent; otherwise nothing on screen would show the undo.
                guard let controller, let id = windowConversation else { return }
                if let open = windowReader, controller.readerWindows.contains(where: { $0.conversation === open }) { return }
                controller.handUnsentQuickReply(under: id)
            }
        }
        // A reader window's quick reply scheduled it: the step is that window's, so its toast and its undo's confirmation
        // show there (spec, Reader window (Q3.5)); the window stays open, as nothing left the desk.
        if let reader = fromWindow {
            act(in: reader, closing: false) { _ = record() }
        } else {
            _ = record()
        }
    }

    /// A reply scheduled in a reader window that has closed was taken back: the readers showing its conversation take the
    /// parked text, the main window's first; with none, the main window's reader says it was not sent and where it waits.
    private func handUnsentQuickReply(under id: ConversationID) {
        let readers = [conversation] + readerWindows.map(\.conversation)
        if readers.first(where: { $0.takeUnsentQuickReply(under: id, confirming: false) }) == nil {
            conversation.takeUnsentQuickReply(under: id, confirming: true)
        }
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
        snoozeObservation?.cancel()
        snoozeObservation = nil
        calendarState.tearDown()
        sendLaterOutbox.stop()
        stripCollapseObservation?.invalidate()
        stripCollapseObservation = nil
        inboxMonitor.stop()
        activity.stop()
        checkTimer?.invalidate()
        acknowledgeTimer?.invalidate()
        retryLineTimer?.invalidate()
        // The reader windows show this mailbox, whose engine is about to stop.
        for reader in readerWindows { reader.close() }
        readerWindows = []
        toasts.dismiss()
        if UndoSendPanel.undoKeyArbiter === undoCenter { UndoSendPanel.undoKeyArbiter = nil }
        if SendArchive.archiver === self { SendArchive.archiver = nil }
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

        // The reader's item holds the day column too (§5.1): the split keeps its three items and its autosave.
        readerItem = NSSplitViewItem(viewController: desk)
        readerItem.holdingPriority = .defaultLow
        readerItem.canCollapse = false

        splitController.splitViewItems = [stripItem, listItem, readerItem]
        applyColumnWidths()
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

    /// While the day column is on, the reader's item keeps room for its strip beside a 400 pt reader, and the list's
    /// maximum gives up the strip's 28 pt (§3.2), so even the folded column never takes the reader under 400.
    func applyColumnWidths() {
        // The strip may stand at the trailing edge: the column is on, or hidden with the calendar's toggle kept (§5.54).
        let strip = desk.isColumnOn || desk.hasCalendarAccess ? Quire.Layout.CalendarPane.stripWidth : 0
        readerItem?.minimumThickness = ConversationPaneViewController.minimumWidth + strip
        listItem?.maximumThickness = ListPaneViewController.maximumWidth - strip
    }

    /// A first run has no autosaved divider positions; the list then starts at its preferred width.
    private let isFirstSplitLayout = UserDefaults.standard.object(forKey: "NSSplitView Subview Frames MainSplit") == nil

    /// `--snapshot` and the other window snapshots (`LaunchOptions.isWindowSnapshot`): the window keeps the
    /// default size and divider positions and ignores the pointer, so it compares with the specimen and never
    /// rewrites the user's saved frame.
    let isSnapshot = LaunchOptions().isWindowSnapshot

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
        strip.acceptsDrop = { [weak self] view, ids in self?.acceptsDrop(of: ids, onto: view) ?? false }
        strip.onDrop = { [weak self] view, ids in self?.drop(ids, onto: view) ?? false }

        listPane.onViewChange = { [weak self] view in self?.setView(view) }
        listPane.onSearchChange = { [weak self] text in
            self?.searchText = text
            self?.applyQuery()
        }
        listPane.onLeaveSearch = { [weak self] in self?.focusList() }
        listPane.onSubmitSearch = { [weak self] in self?.list.requestServerSearchFromField() }
        listPane.header.onSearchFocusChange = { [weak self] focused in self?.list.searchFieldHasFocus = focused }
        listPane.onCompose = { [weak self] in self?.composeNew() }
        listPane.onSelectAccountShortcut = { [weak self] number in self?.strip.selectShortcut(number) }
        listPane.onAddAccount = { [weak self] kind in self?.requestAddAccount(kind) }
        listPane.onLeaveDemo = { [weak self] in self?.onLeaveDemo?() }
        listPane.titleMenuModel = { [weak self] in self?.titleMenuModel ?? TitleMenu.Model(
            view: .inbox, inboxUnread: 0, scope: .unified, showsAccounts: false, unifiedUnread: 0, accounts: []) }
        listPane.statusBar.onOpenSettings = { [weak self] in self?.openAccountsSettings() }
        listPane.statusBar.onAction = { [weak self] action in self?.syncLineAction(action) }
        // A countdown under another line is in the tooltip alone, which nothing ticks: it is brought up to date as
        // the pointer arrives, before the tooltip shows.
        listPane.statusBar.onHover = { [weak self] in self?.refreshSyncLine() }

        list.onSelectionChange = { [weak self] _ in self?.listSelectionDidChange() }
        list.onSelectionSetChange = { [weak self] _ in self?.listSelectionDidChange() }
        list.rowMenu = { [weak self] in self?.selectionContextMenu() }
        list.onRowAction = { [weak self] change, id in self?.rowAction(change, on: id) }
        conversation.messageMenu = { [weak self] in self?.selectionContextMenu() }
        list.onOpen = { [weak self] id in
            guard let self, !self.continuesEditing(id) else { return }
            self.showInReader(id)
        }
        list.onOpenInWindow = { [weak self] id in
            guard let self, !self.continuesEditing(id) else { return }
            // A message on its way is not a conversation a reader window could hold: ↩ and a double-click on an Outbox
            // row only show it, in the main window's reader, as → does (§5.53).
            if self.listView == .outbox {
                self.showInReader(id)
            } else {
                self.openInNewWindow(id)
            }
        }
        list.onRowsChange = { [weak self] in self?.listPane.listRowsDidChange() }
        // The UI never calls a provider: the engine searches, writes what it finds, and the list reads the store.
        let engine = environment.engine
        list.serverSearch.search = { words, scope in try await engine.searchServer(for: words, accountIDs: scope) }

        conversation.onAction = { [weak self] action in self?.handle(action) }
        conversation.onQuickSendChange = { UndoSendPanel.refreshUndoKeyOwner() }
        conversation.localDrafts = localDrafts
        conversation.isDraftInComposer = { ComposeWindowRegistry.shared.controller(holdingDraft: $0) != nil }
        list.localMessages = { [weak self] id in self?.localDrafts.messages(in: id) }
        localDrafts.onChange = { [weak self] in
            self?.showLocalDrafts()
            // Once per word of the outbox, after both views' sends are taken from it: a send leaving and another arriving
            // in one word never hide and show the Outbox's tile (§5.53).
            self?.applyOutboxAvailability()
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
        notifier.conversationOpenInKeyWindow = { [weak self] in
            guard let self else { return nil }
            if let reader = self.readerWindows.first(where: { $0.window?.isKeyWindow == true }) { return reader.conversationID }
            guard self.window?.isKeyWindow == true else { return nil }
            return self.conversation.currentConversationID
        }
        let store = environment.store
        notifier.newestUnreadInInbox = { ids in try? store.newestUnreadInboxMessages(in: ids) }
        activity.onChange = { [weak self] in self?.refreshSyncLine() }
        // Back online: check now rather than when the engine's backoff next allows.
        activity.onNetworkReturned = { [weak self] in self?.checkAllAccounts() }
        wireCalendar()
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
            // A removed account takes its conversations' windows with it, and its steps leave the undo history: ⌘Z reaches
            // every step the history holds, however old, and a removed account's would write to mail that is gone (§6.1).
            for reader in readerWindows where byID[reader.conversationID.accountID] == nil { reader.close() }
            let removed = previous.subtracting(byID.keys)
            if !removed.isEmpty {
                undoCenter.removeAccounts(removed)
                forgetGroupsGone()
                UndoSendPanel.refreshUndoKeyOwner()
            }
            for reader in readerWindows { reader.conversation.accountsByID = byID }
            calendarState.accounts = fresh
            localDrafts.accounts = fresh
            sendLaterOutbox.refresh()
            showLocalDrafts()
            inboxMonitor.updateAccounts(fresh.map(\.id))
            listPane.setSearchEnabled(!fresh.isEmpty)
            restoreSavedScope()
            selectAddedAccount(previous: previous)
            updateScopeDetails()
        }
        updateWelcome()
    }

    /// Opens on the scope an earlier launch saved, checked against the first accounts the window reads: normally
    /// its first read of the store, which comes before the list's first query, so the list never shows All Inboxes
    /// first. A saved account that is not among them (removed meanwhile) leaves All Inboxes, and the saved value is
    /// forgotten. A demo seeded after its window opens (its first launch, or after its data was wiped) always ends
    /// that way, since the seeder gives every account a new id. The tile is selected here but scrolled into view
    /// only when the rail appears, at the window's final size.
    private func restoreSavedScope() {
        guard let saved = scopeToRestore, !accounts.isEmpty else { return }
        scopeToRestore = nil
        guard case .account(let id) = saved else { return }
        guard accountsByID[id] != nil else {
            settings.saveAccountScope(nil, demo: environment.isDemo)
            return
        }
        strip.select(saved, notify: false)
        scope = saved
        scopeBaselinePending = true
        applyQuery()
    }

    /// Saves the scope for the next launch, the demo's under its own key.
    private func rememberScope() {
        guard remembersScope else { return }
        settings.saveAccountScope(scope, demo: environment.isDemo)
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

    /// Internal so tests apply statuses as the engine reports them.
    func statusesChanged(_ statuses: [AccountSyncStatus]) {
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
        // “retrying in 30 s” counts down: the line is chosen again each second while it shows one on screen. Under
        // Offline, Couldn't sync or Sign in required the line shows no count for a retry ahead, and during an outage
        // one is ahead almost all the time, so those keep no timer; an occluded window catches up when seen again.
        let countsDown = summary.countsDown && isSyncLineOnScreen
        if countsDown, retryLineTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSyncLine() }
            }
            RunLoop.main.add(timer, forMode: .common)
            retryLineTimer = timer
        } else if !countsDown {
            retryLineTimer?.invalidate()
            retryLineTimer = nil
        }
    }

    /// Internal so tests check that a line without a countdown keeps no timer.
    var isCountingDownRetry: Bool { retryLineTimer != nil }

    /// Tests stand in for the window server, which does not report a window parked off screen as visible.
    var syncLineVisibilityOverride: Bool?

    private var isSyncLineOnScreen: Bool {
        syncLineVisibilityOverride ?? (window?.occlusionState.contains(.visible) == true)
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
        // A scope chosen now wins over one still waiting to be restored.
        scopeToRestore = nil
        scopeBaselinePending = false
        rememberScope()
        updateScopeDetails()
        // The user chose this scope; an undo leaves them in it, even when the scope took Later or the Outbox away.
        viewLeftAsItEmptied = nil
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
        applyLaterAvailability()
        applyOutboxAvailability()
    }

    private func countsChanged(unified: Int, perAccount: [AccountID: Int]) {
        unifiedUnread = unified
        unreadByAccount = perAccount
        if scopeBaselinePending {
            scopeBaselinePending = false
            unreadAtScopeChange = perAccount
        }
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
            accounts: accounts.map { TitleMenu.AccountEntry(account: $0, monogram: monograms[$0.id] ?? "?", unread: unreadByAccount[$0.id] ?? 0) },
            showsLater: showsLater, showsOutbox: showsOutbox
        )
    }

    /// Picking a mailbox means "show me that mailbox", so it also ends a search that would otherwise keep
    /// overriding the view. Later and the Outbox only while they show: G L, G O and the View menu's Later and Outbox do
    /// nothing otherwise (§5.2).
    func setView(_ view: MailboxView) {
        guard view != .later || showsLater, view != .outbox || showsOutbox else { return }
        mailboxView = view
        viewLeftAsItEmptied = nil
        endSearch()
        applyQuery()
    }

    private func endSearch() {
        guard !searchText.isEmpty || !listPane.searchText.isEmpty else { return }
        listPane.clearSearch(notify: false)
        searchText = ""
    }

    func applyQuery() {
        let query = ShellQuery.make(scope: scope.accountIDs, view: mailboxView, searchText: searchText)
        conversation.mailboxView = query.view
        // The calendar is narrowed to the account the window is (⌘1…⌘9), as the list is (§5.54, “unified”).
        switch scope {
        case .unified: calendarState.scope = .all
        case .account(let id): calendarState.scope = .account(id)
        }
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
    func present(selection ids: [ConversationID]) {
        shownSelection = ids
        acknowledgeTimer?.invalidate()
        acknowledgeTimer = nil
        // The calendar reads the conversation's invitation and times off the main thread, and the column follows once
        // they land (§5.54, “It follows the mail”); several selected are about no one day, and a hidden calendar
        // follows nothing.
        selectInCalendar(ids)
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
        // Under the week the reader is hidden: its failed mark is acknowledged once it shows (§5.54).
        if !desk.isWeekShown, list.conversations.first(where: { $0.id == id })?.failedOperation != nil {
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
        guard let newest = list.conversations.first?.id else { return nil }
        #if DEBUG
        var first = newest
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--snapshot-state=") && $0.contains("newsletter") }) {
            // The newest conversation whose sender offers Unsubscribe, so a render shows the link (§5.14).
            let store = environment.store
            first = list.conversations.first { row in
                ((try? store.messages(in: row.id)) ?? []).contains { UnsubscribeMethod(message: $0) != nil }
            }?.id ?? newest
        }
        #else
        let first = newest
        #endif
        list.selectedConversationID = first
        present(selection: [first])
        #if DEBUG
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--snapshot-state=") && $0.contains("several") }) {
            let ids = Array(list.conversations.prefix(3).map(\.id))
            list.selectConversations(ids, lead: ids.last)
            present(selection: ids)
        }
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--snapshot-state=") && $0.contains("find") }) {
            // Find in conversation (§5.50): the bar over the demo's first conversation, its matches marked.
            conversation.whenShownRenderLands(timeout: 10) { [weak self] _ in self?.conversation.find.open(query: "the") }
        }
        applyDebugCalendarStates()
        #endif
        return list.selectedConversationID ?? first
    }

    var hasConversations: Bool { !list.conversations.isEmpty }

    func whenReaderSettles(timeout: TimeInterval, _ completion: @escaping (WKWebView?) -> Void) {
        conversation.whenShownRenderLands(timeout: timeout, completion)
    }

    /// Debug aid for `--snapshot-compose`.
    func openReplyComposer() -> Bool {
        composeReply(all: false)
    }

    // MARK: Notifications (§5.41)

    /// A click on a new-mail notification, or one of its actions, once this window has read its accounts. A click
    /// opens and selects the conversation. Archive and Mark as Read are the window's own changes, applied to the
    /// store and queued in one call, but with no toast and nothing in the undo history: the user is elsewhere, and
    /// an undo they never saw offered would only surprise them later. Reply opens a reply composer to the
    /// conversation's latest message from its account. An action on an account this window does not show (a
    /// demo notification once the real accounts are back, or the other way round), on a conversation that is
    /// gone, or one the change would leave as it is, does nothing.
    func answer(_ response: NewMailNotificationResponse) {
        switch response {
        case .open(let id):
            if let id { reveal(id) }
        case .archive(let id):
            notificationAction(.archive, on: id)
        case .markRead(let id):
            notificationAction(.setRead(true), on: id)
        case .reply(let id):
            beforeCompose?()
            guard let account = accountsByID[id.accountID], let latest = (try? environment.store.messages(in: id))?.last else { return }
            ComposeWindowController.present(client: environment.engine, account: account, accounts: accounts,
                                            mode: .reply(latest.id, all: false))
        }
    }

    private func notificationAction(_ change: MetadataChange, on id: ConversationID) {
        guard accountsByID[id.accountID] != nil else { return }
        let targets = actionRecords(change, on: [id]).flatMap(\.targets)
        guard !targets.isEmpty else { return }
        do {
            try environment.engine.perform(change, on: targets)
            Analytics.from(.notification) { reportMailAction(AnalyticsSignal.MailAction(change), conversations: 1) }
        } catch {
            Self.log.error("notification action failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Brings a conversation on screen from outside the list (a notification click).
    func reveal(_ id: ConversationID) {
        showWindow(nil)
        listPane.clearSearch(notify: false)
        searchText = ""
        strip.select(.unified, notify: false)
        scope = .unified
        // The window now shows All Inboxes, so the next launch opens there too.
        rememberScope()
        updateScopeDetails()
        mailboxView = .inbox
        viewLeftAsItEmptied = nil
        applyQuery()
        list.selectedConversationID = id
        present(selection: [id])
    }

    /// Puts the list on `view`, out of any search, and on All Inboxes when `unifying` (for a conversation of an account
    /// the window is not narrowed to), as a notification's click does; the calendar's Show the mail lands here.
    func showView(_ view: MailboxView, unifying: Bool) {
        if unifying {
            strip.select(.unified, notify: false)
            scope = .unified
            rememberScope()
            updateScopeDetails()
        }
        listPane.clearSearch(notify: false)
        searchText = ""
        mailboxView = view
        viewLeftAsItEmptied = nil
        applyQuery()
    }

    /// The window shows `account`'s mail: All Inboxes, or narrowed to it.
    func scopeIncludes(_ account: AccountID) -> Bool {
        if case .account(let id) = scope { return id == account }
        return true
    }

    private var selectedSummary: ConversationSummary? {
        guard let id = list.selectedConversationID else { return nil }
        return list.conversations.first { $0.id == id }
    }

    /// Every selected conversation in list order: what E, #, S, U, ⇧I and the Message menu act on.
    var selectedIDs: [ConversationID] { list.selectedConversationIDs }

    private var selectedSummaries: [ConversationSummary] {
        let ids = Set(selectedIDs)
        guard ids.count > 1 else { return selectedSummary.map { [$0] } ?? [] }
        return list.conversations.filter { ids.contains($0.id) }
    }

    /// Two or more conversations are selected: replies have no single target (§5.12).
    var isSeveralSelected: Bool { selectedIDs.count > 1 }

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

    func focusList() {
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
    func sequenceHUDWillAppear() { toasts.dismiss(in: listPane.toastView) }

    var isReaderFocused: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: conversationPane.view)
    }

    /// The list's table itself has the keyboard, not a control inside a row (the tail's Retry, the server search's link) or
    /// anywhere else in the window: only then does ↩ open the selection in a reader window (§5.49, §6).
    var isListFocused: Bool {
        window?.firstResponder === list.tableView
    }

    func perform(_ command: KeyCommand) -> Bool {
        // The router sees every key first; ↑/↓ and ↩ on a focused rail tile, sync line or menu button are that
        // control's own (§5.2, §5.11), so they go on to it instead of moving or opening the list.
        if focusedControlTakesCurrentKey { return false }
        if refusesInOutbox(command) {
            NSSound.beep()
            return true
        }
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
            // ↩ on a focused elision mark in the reader presses the mark in the page (§5.15) rather than opening again.
            if conversation.isMarkFocused { return false }
            // Several selected have nothing single to open; the key is spent all the same.
            guard !isSeveralSelected else { return true }
            guard let id = list.selectedConversationID else { return false }
            list.onOpen?(id)
            return true
        case .openInWindow:
            // As for Open: several selected have nothing single to open, and the key is spent all the same (§5.49).
            guard !isSeveralSelected else { return true }
            guard let id = list.selectedConversationID else { return false }
            list.onOpenInWindow?(id)
            return true
        case .archive:
            return archive()
        case .toggleStar:
            guard let change = starChangeForSelection else { return false }
            return mailAction(change)
        case .toggleRead:
            guard let change = readChangeForSelection else { return false }
            return mailAction(change)
        case .trash:
            // In Drafts, # is Discard Draft…, asked first (§5.12).
            if listView == .drafts {
                confirmDiscardDrafts(selectedIDs)
                return true
            }
            // In Trash the conversation is already there and v1 has no Delete Forever: # does nothing, quietly,
            // and never trashes the rest of a conversation only partly in Trash (§5.12).
            if listView == .trash { return true }
            return mailAction(.trash)
        case .markSpam:
            return markSpam()
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
        case .clearSearch, .escapeRepeat:
            // The main window never closes on Esc, so its repeat does what a press does (§6.1).
            return escape()
        case .back:
            // On a chip or its Download button ← moves along the files in the page (§5.17), in an open list of recipients
            // along the recipients (§5.14).
            if conversation.pageTakesArrows { return false }
            return escape()
        case .moveToInbox:
            return moveSelectionToInbox()
        case .later:
            return showLaterMenu()
        case .toggleMute:
            return toggleMute()
        case .undo:
            // The router acts only outside text, so typing is never ⌘Z's target here; Z never cancels a send.
            let commandZ = NSApp.currentEvent?.modifierFlags.contains(.command) == true
            performUndo(commandZ ? commandZTarget(textCanUndo: false) : zTarget)
            return true
        case .goTo(let view):
            setView(view)
            return true
        case .toggleDayColumn:
            // A held D or W would flip the column or the week on every repeat.
            if !isKeyRepeat { toggleDay() }
            return true
        case .toggleWeek:
            if !isKeyRepeat { toggleWeekView() }
            return true
        case .previousDay, .nextDay:
            // Only while the column (in full or over the reader's edge) or the week shows: there is nothing to turn else.
            guard desk.isCalendarShowing else { return false }
            let step = calendarState.span == .week ? 7 : 1
            turnDay(by: command == .nextDay ? step : -step)
            return true
        case .today:
            guard desk.isCalendarShowing else { return false }
            goToToday()
            return true
        case .blockTime:
            return blockTimeForSelection()
        }
    }

    /// The key being handled is held down (only a key event can say; asking any other raises).
    private var isKeyRepeat: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown else { return false }
        return event.isARepeat
    }

    /// A mail key on an Outbox row: a message on its way is not mail in the store, so E, S, U, #, !, L, M, ⇧I, R, A and F
    /// change nothing there and beep, as E does where it changes nothing (§5.53). With nothing selected they pass on, as
    /// anywhere; the keys that move, open, search, write and go are the list's own.
    private func refusesInOutbox(_ command: KeyCommand) -> Bool {
        guard listView == .outbox, list.selectedConversationID != nil else { return false }
        switch command {
        case .archive, .toggleStar, .toggleRead, .trash, .markSpam, .moveToInbox, .later, .toggleMute, .reply, .replyAll, .forward,
             .blockTime:
            return true
        case .next, .previous, .extendNext, .extendPrevious, .open, .openInWindow, .compose, .search, .clearSearch, .escapeRepeat, .back,
             .undo, .goTo, .toggleDayColumn, .toggleWeek, .previousDay, .nextDay, .today:
            return false
        }
    }

    private var focusedControlTakesCurrentKey: Bool {
        guard let event = NSApp.currentEvent, event.type == .keyDown,
              let control = window?.firstResponder as? ShellKeyHandling else { return false }
        return control.handlesKey(event)
    }

    /// Esc outside a text field, by the precedence of §6.1: an event's details in the calendar close first, then a visible
    /// toast goes (its undo keeps working for the grace period), then an open find bar closes while the reader has the
    /// keyboard, then an open list of recipients with focus in it folds, then the day column opened over the reader closes
    /// and the week's invitation card hides, then focus in the reader or the calendar returns to the list, then a kept
    /// search query clears. On the list with nothing to undo Esc does nothing, without a beep.
    private func escape() -> Bool {
        // An event's details in the column or the week come before everything else here (§6.1 row 4).
        if desk.column.dismissDetails() || desk.week.dismissDetails() { return true }
        // Only this window's toast: one in a reader window is that window's to dismiss.
        if toasts.isVisible(in: listPane.toastView) {
            toasts.dismiss()
            return true
        }
        // An open find bar closes before the reader gives the keyboard back to the list (§6.1).
        if isReaderFocused, conversation.closeFindForEscape() {
            return true
        }
        // Then an open list of recipients with focus in it folds, focus going to its toggle (§6.1, §5.14).
        if isReaderFocused, conversation.foldAddressesForEscape() {
            return true
        }
        // The column opened over the reader's edge closes back to its strip (row 11), then the week's invitation card
        // hides until the selection changes (row 12); the week itself stays until W or D.
        if closeCalendarOverlay() { return true }
        if desk.placement == .week, desk.week.hideInvitationCard() { return true }
        if isReaderFocused || isCalendarFocused {
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
        let records = actionRecords(change, on: targets)
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
        reportMailAction(AnalyticsSignal.MailAction(change), conversations: records.count)
        return true
    }

    /// A mail action the user took, for analytics: which, how many conversations, and where it came from (`Analytics`).
    private func reportMailAction(_ action: AnalyticsSignal.MailAction?, conversations: Int) {
        guard let action, conversations > 0 else { return }
        Analytics.send(.mailAction(action, Analytics.trigger, conversations: conversations))
    }

    /// A change to `ids`, some messages of one conversation rather than all of it (a sheet's star, More › Star Message, Mark
    /// as Unread from Here, §5.14): applied and recorded as a mail action on that conversation, so it gets the toast S or U
    /// would give in the view (none where the row shows the change, as for a star outside Starred) and ⌘Z reaches it
    /// however long after (§6.1).
    @discardableResult
    private func messageAction(_ change: MetadataChange, on ids: [MessageID]) -> Bool {
        let store = environment.store
        let messages = ids.compactMap { try? store.message($0) }
        guard let conversation = messages.first?.conversationID, accountsByID[conversation.accountID] != nil,
              let record = MailActionRecord.make(change, on: messages.filter { $0.conversationID == conversation },
                                                 conversation: conversation) else {
            NSSound.beep()
            return false
        }
        do {
            try environment.engine.perform(change, on: record.targets)
        } catch {
            Self.log.error("message action failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return false
        }
        recordUndo([record], change: change)
        reportMailAction(AnalyticsSignal.MailAction(change), conversations: 1)
        return true
    }

    /// What `change` does to each of `ids`, read from the store: one record per conversation it changes, so a
    /// conversation that is gone, or that the change would leave as it is, has none.
    private func actionRecords(_ change: MetadataChange, on ids: [ConversationID]) -> [MailActionRecord] {
        let store = environment.store
        // Back in the Inbox, or in the Trash or Spam, a conversation is no longer snoozed (the store ends it); out of the
        // Inbox it no longer sorts as back from Later (the refresh ends the mark). The undo puts either back.
        let endsSnooze = [.moveToInbox, .restoreFromTrash, .trash, .markSpam].contains(change)
        let snoozed = endsSnooze ? snoozedUntil : [:]
        let returned = [.archive, .trash, .markSpam].contains(change) ? returnMarks(of: ids) : [:]
        var records: [MailActionRecord] = []
        for id in ids {
            guard let all = try? store.messages(in: id), !all.isEmpty else { continue }
            let kind = accountsByID[id.accountID]?.kind ?? .gmail
            // A snoozed conversation moved to the Inbox (⇧I, a drop on Inbox) comes back now as it would at its time:
            // the mail the snooze put away, not a deleted message Move to Inbox's own rule would take out of the Trash.
            let messages = change == .moveToInbox && snoozed[id] != nil
                ? MailActionRecord.returnTargets(in: all, kind: kind)
                : MailActionRecord.targets(for: change, in: all, kind: kind)
            if var record = MailActionRecord.make(change, on: messages, conversation: id) {
                record.snoozedUntil = snoozed[id]
                record.returnedAt = returned[id]
                // Spam takes the summary row, and the mute on it, away; the undo mutes it again (`revert`).
                record.wasMuted = change == .markSpam && ((try? store.isMuted(id)) ?? false)
                records.append(record)
            }
        }
        return records
    }

    /// When each of `ids` came back from Later, as the list's rows say (`returnedAt`): Archive, Move to Trash, Mark as Spam
    /// and Snooze take the mark away with the conversation's place under Today, and their undo puts it back.
    private func returnMarks(of ids: [ConversationID]) -> [ConversationID: Date] {
        let wanted = Set(ids)
        var marks: [ConversationID: Date] = [:]
        for row in list.conversations where wanted.contains(row.id) {
            if let returnedAt = row.returnedAt { marks[row.id] = returnedAt }
        }
        // A reader window's conversation may have left the list since it opened; the window kept its row's mark.
        if let reader = actingReader, wanted.contains(reader.conversation), marks[reader.conversation] == nil {
            marks[reader.conversation] = reader.returnedAt
        }
        return marks
    }

    /// A toast's Undo reverts the group that toast offers, whatever happened since; Z and ⌘Z follow
    /// `UndoPrecedence`.
    private func recordUndo(_ records: [MailActionRecord], change: MetadataChange) {
        let now = undoCenter.now()
        defer { UndoSendPanel.refreshUndoKeyOwner() }
        actingReader?.tookStep = true
        if let group = undoHistory.coalesce(records, at: now, visibleToastID: undoCenter.coalescingToastID(in: actingPlace)) {
            let id = group.id
            toasts.show(MailActionCopy.toast(for: change, count: group.records.count), kind: .undoable,
                        symbol: symbol(for: change), actionTitle: "Undo", keycap: "Z",
                        updating: group.toastID, in: stepToastHost) { [weak self] in self?.undo(groupID: id) }
            return
        }
        // No toast for a change the row itself shows; Z still reaches it for the grace period, ⌘Z for as long as the history
        // holds it. The list's own query: while searching, its view is the one the search looks through. In a reader window
        // the conversation is the row: a step that closes the window always says so, and one that leaves it open as the list
        // would for its view.
        let toasted: Bool
        if let reader = actingReader {
            toasted = reader.isClosing || MailActionCopy.wantsToast(for: change, in: reader.view, count: records.count)
        } else {
            toasted = MailActionCopy.wantsToast(for: change, in: list.query.view, search: list.query.search, count: records.count)
        }
        let id = undoHistory.add(records, at: now, toasted: toasted)
        rememberPlace(of: id)
        guard toasted else { return }
        let toastID = toasts.show(MailActionCopy.toast(for: change, count: records.count), kind: .undoable, symbol: symbol(for: change),
                                  actionTitle: "Undo", keycap: "Z", in: stepToastHost) { [weak self] in self?.undo(groupID: id) }
        undoHistory.bindToast(toastID, to: id)
    }

    // MARK: Unsubscribe (§5.14)

    /// Unsubscribes with what `messageID`'s list headers offer, in one click and without asking: the request (a
    /// one-click POST or a mailto request, which the engine sends) and the conversation's archive go to the store in
    /// one transaction; a page is opened in the browser at once, the archive stored all the same. A snoozed
    /// conversation (in Later, or a search's result) is archived already: its snooze ends instead, as E ends it in
    /// Later, so the list's mail never comes back to the Inbox at its time. The toast says what became of the request
    /// and offers Undo for the archive or the snooze, which brings the row back; the request stays sent, so the group
    /// never takes in a later archive, nor E in Later (its toast would lose the request's words). Nothing to archive
    /// (the conversation already out of the Inbox and not snoozed) leaves the request's words alone, with nothing to
    /// undo. The undo's own confirmation says the request stays sent, which the undoable toast has no room for. The same
    /// request asked again while its toast is up does nothing (`shownUnsubscribe`).
    @discardableResult
    func unsubscribe(from messageID: MessageID) -> Bool {
        guard !showingWelcome, accountsByID[messageID.accountID] != nil,
              let message = try? environment.store.message(messageID), let method = UnsubscribeMethod(message: message) else {
            NSSound.beep()
            return false
        }
        if let shown = shownUnsubscribe, shown.toastID == toasts.visibleID, shown.accountID == messageID.accountID,
           shown.method == method {
            return true
        }
        let conversationID = message.conversationID
        let snoozedAt = snoozedUntil[conversationID]
        let records = snoozedAt == nil ? actionRecords(.archive, on: [conversationID]) : []
        do {
            try environment.engine.unsubscribe(method, accountID: messageID.accountID, archiving: records.flatMap(\.targets),
                                               endingSnoozesOf: snoozedAt == nil ? [] : [conversationID])
        } catch {
            Self.log.error("unsubscribe failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return false
        }
        if case .browser(let page) = method { openUnsubscribePage(page) }
        reportMailAction(.unsubscribe, conversations: 1)
        let archived = !records.isEmpty || snoozedAt != nil
        let words = MailActionCopy.unsubscribeToast(for: method, archived: archived)
        defer { UndoSendPanel.refreshUndoKeyOwner() }
        guard archived else {
            // Nothing was archived, so the glyph is the request's own: sent, or a page opened. Nothing left the desk either:
            // a reader window stays open, with the words in it.
            let toastID = toasts.show(words, kind: .confirmation, symbol: method.isRequest ? Quire.Icon.send : Quire.Icon.link,
                                      in: actingReader?.window?.toastView)
            shownUnsubscribe = (messageID.accountID, method, toastID)
            return true
        }
        let confirmation = MailActionCopy.unsubscribeUndoConfirmation(for: method)
        let id: Int
        actingReader?.tookStep = true
        if let snoozedAt {
            // Named Archive, as E in Later is, so Edit › Undo reads “Undo Archive” either way.
            id = undoHistory.addExternal(command: MailActionCopy.commandName(for: .archive), accounts: [messageID.accountID],
                                         at: undoCenter.now(), toasted: true, coalesces: false)
            externalUndos[id] = laterArchiveRevert([Snooze.Change(conversationID: conversationID, until: snoozedAt)],
                                                   inLater: actionView == .later, confirmation: confirmation)
        } else {
            id = undoHistory.add(records, at: undoCenter.now(), toasted: true, coalesces: false)
            unsubscribeUndoConfirmations[id] = confirmation
        }
        rememberPlace(of: id)
        let toastID = toasts.show(words, kind: .undoable, symbol: symbol(for: .archive), actionTitle: "Undo", keycap: "Z",
                                  in: stepToastHost) { [weak self] in
            self?.undo(groupID: id)
        }
        undoHistory.bindToast(toastID, to: id)
        shownUnsubscribe = (messageID.accountID, method, toastID)
        return true
    }

    /// Message › Unsubscribe (⇧⌘U): the open conversation's latest message that offers it.
    @objc func unsubscribeFromConversation(_ sender: Any?) {
        guard let target = conversation.unsubscribeTarget else {
            NSSound.beep()
            return
        }
        unsubscribe(from: target)
    }

    /// A step that is not a mail action, offered by its own toast and reverted by `revert` (§5.20). `accounts` are those
    /// the revert writes to: a removed one takes the step out of the history (`MailUndoCenter.removeAccounts`).
    @discardableResult
    func recordExternalUndo(command: String, accounts: Set<AccountID>, toast message: String, symbol: String,
                            revert: @escaping () -> Void) -> Int {
        let id = undoHistory.addExternal(command: command, accounts: accounts, at: undoCenter.now(), toasted: true)
        externalUndos[id] = revert
        actingReader?.tookStep = true
        rememberPlace(of: id)
        let toastID = toasts.show(message, kind: .undoable, symbol: symbol, actionTitle: "Undo", keycap: "Z", in: stepToastHost) { [weak self] in
            self?.undo(groupID: id)
        }
        undoHistory.bindToast(toastID, to: id)
        UndoSendPanel.refreshUndoKeyOwner()
        return id
    }

    /// Remembers where group `id` was taken: in which window (`MailUndoCenter`), and whether in this window's Later outside a
    /// search, forgetting the groups that fell out of the history.
    private func rememberPlace(of id: Int) {
        undoCenter.remember(actingPlace, for: id)
        forgetGroupsGone()
        if actingReader == nil, listView == .later { groupsFromLater.insert(id) }
    }

    /// Lets go of what this window keeps beside the history (external reverts, Later's snoozes, unsubscribe confirmations,
    /// the steps taken in Later) for the groups no longer in it: the oldest, dropped by the 51st step, and a removed
    /// account's.
    private func forgetGroupsGone() {
        let live = Set(undoHistory.groups.map(\.id))
        externalUndos = externalUndos.filter { live.contains($0.key) }
        laterArchiveRestores = laterArchiveRestores.filter { live.contains($0.key) }
        unsubscribeUndoConfirmations = unsubscribeUndoConfirmations.filter { live.contains($0.key) }
        groupsFromLater = groupsFromLater.filter { live.contains($0) }
    }

    // MARK: Undo order (§6.1)

    /// ⌘Z and Edit › Undo: typing, then the newest live send or toast, then the latest step in the history, however old.
    /// The order is the app's (`MailUndoCenter`), the same from a reader window.
    func commandZTarget(textCanUndo: Bool) -> UndoPrecedence.Target {
        undoCenter.commandZTarget(textCanUndo: textCanUndo)
    }

    /// Z and Message › Undo: only ever the latest toast's action.
    var zTarget: UndoPrecedence.Target { undoCenter.zTarget }

    /// Edit › Undo's title for `target`: “Undo Typing”, “Undo Send” (“Undo Send and Archive” when the send archived its
    /// conversation, which the undo brings back too), “Undo Archive”, “Can't Undo”.
    func undoMenuTitle(for target: UndoPrecedence.Target) -> String {
        undoCenter.undoMenuTitle(for: target, typing: window?.undoManager)
    }

    func performUndo(_ target: UndoPrecedence.Target) {
        undoCenter.perform(target, typing: window?.undoManager)
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

    // MARK: Mark as Spam (spec “Mark as spam”)

    /// Nothing is marked as spam from the Trash, where the mail is on its way out already and Mark as Spam leaves what is
    /// there (`MailActionRecord.targets`), or from Drafts, which holds the user's own mail; nor from `in:trash` or
    /// `in:drafts` results. A search typed there lists All Mail (`listView`), whose rows it takes.
    private var marksSpamInView: Bool { listView != .trash && listView != .drafts && listView != .outbox }

    /// ! and Mark as Spam: the selection leaves every view, as there is none for spam, with the toast, coalescing and
    /// undo of #. A snoozed conversation's snooze ends (the store's rule), and the undo puts it back. Where it does not
    /// apply it beeps, as L does there.
    @discardableResult
    private func markSpam() -> Bool {
        guard !showingWelcome, !selectedIDs.isEmpty else { return false }
        guard marksSpamInView else {
            NSSound.beep()
            return true
        }
        return mailAction(.markSpam)
    }

    // MARK: Later (§5.45)

    private func snoozesChanged(_ snoozes: [Snooze]) {
        self.snoozes = snoozes
        applyLaterAvailability()
    }

    /// The snoozes in the current scope: what the Later tile, G L, the title menu and the View menu go by.
    private var snoozesInScope: [Snooze] {
        guard case .account(let id) = scope else { return snoozes }
        return snoozes.filter { $0.conversationID.accountID == id }
    }

    /// Something in the scope is snoozed: Later shows in the rail, the title menu and the View menu (§5.2).
    var showsLater: Bool { !snoozesInScope.isEmpty }

    /// Each snoozed conversation's due time.
    private var snoozedUntil: [ConversationID: Date] {
        Dictionary(snoozes.map { ($0.conversationID, $0.dueAt) }, uniquingKeysWith: { first, _ in first })
    }

    private func applyLaterAvailability() {
        let shows = showsLater
        strip.setShowsLater(shows)
        // The last snooze in view ended while Later was shown, or the scope moved to an account with none: nothing is
        // left to show there, so the window goes back to the Inbox (§5.2). A search the user typed stays: it shows All
        // Mail or its `in:` view whatever the rail's, so its results, selection and reader stay too, and clearing it
        // lands in the Inbox.
        if mailboxView == .later, !shows {
            mailboxView = .inbox
            viewLeftAsItEmptied = .later
            applyQuery()
        }
    }

    /// What L acts on: the selection, less drafts kept on this Mac, which the store does not hold.
    private var snoozableSelection: [ConversationID] {
        selectedIDs.filter { !LocalDraftConversation.isLocal($0) }
    }

    /// Nothing is snoozed from the Trash (a trashed conversation ends its snooze) or from Drafts, nor from `in:trash` or
    /// `in:drafts` results; a search typed there lists All Mail (`listView`), whose rows L takes.
    private var canSnoozeSelection: Bool {
        !showingWelcome && listView != .trash && listView != .drafts && listView != .outbox && !snoozableSelection.isEmpty
    }

    /// The conversations of `ids` a snooze would hold, judged as snoozing leaves them (archived) by the store's own rule
    /// (`Snooze.canHold`). One whose mail from others is all in the Trash or Spam (# on Microsoft and ! on both leave the
    /// user's own copies in Sent Items and Drafts, so it still lists there, in All Mail and in a search) has nothing to
    /// bring back: the store would drop its snooze, and a toast saying it was snoozed would promise a return that never
    /// comes.
    private func snoozable(_ ids: [ConversationID]) -> [(id: ConversationID, messages: [MessageMetadata])] {
        ids.compactMap { id in
            guard let messages = try? environment.store.messages(in: id),
                  Snooze.canHold(messages.map { applying(.archive, to: $0) }) else { return nil }
            return (id, messages)
        }
    }

    /// L and Message › Later…: the Later menu, hung from the selected row, or from the reader's header when focus is not
    /// in the list. In the Trash and in Drafts it beeps, as archiving in the Trash does.
    @discardableResult
    func showLaterMenu() -> Bool {
        guard !selectedIDs.isEmpty, !showingWelcome else { return false }
        guard canSnoozeSelection, !snoozable(snoozableSelection).isEmpty else {
            NSSound.beep()
            return true
        }
        let menu = LaterMenu.build(now: laterNow(), formatter: laterFormatter, target: self,
                                   presetAction: #selector(snoozeSelectionUntil(_:)), pickAction: #selector(pickSnoozeDate(_:)))
        let anchor = laterMenuAnchor()
        popUpLaterMenu(menu, anchor.point, anchor.view)
        return true
    }

    /// The menu's top-leading corner, `layout.menu.titleMenuOffsetY` below what it hangs from: the lead row's text
    /// column under the row, or the reader header's Archive button.
    func laterMenuAnchor() -> (point: NSPoint, view: NSView) {
        let offset = Quire.Layout.Menu.titleMenuOffsetY
        let listFocused = window?.firstResponder === list.tableView
        if listFocused || !isReaderFocused, let id = list.selectedConversationID, let row = list.revealedRowRect(of: id) {
            let x = (settings.listDensity == .compact ? Quire.Layout.RowCompact.textX : Quire.Layout.Row.textX)
            return (NSPoint(x: x, y: row.maxY + offset), list.tableView)
        }
        let anchor = conversation.header.menuAnchor
        return (NSPoint(x: anchor.minX, y: anchor.maxY + offset), conversation.header)
    }

    /// The context menu's Later submenu: the same presets and Pick a Date…, for the selection.
    private func laterSubmenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Later", action: nil, keyEquivalent: "")
        item.image = QuireSymbol.image(Quire.Icon.later, size: .inText, accessibilityDescription: nil)
        let submenu = LaterMenu.build(now: laterNow(), formatter: laterFormatter, target: self,
                                      presetAction: #selector(snoozeSelectionUntil(_:)), pickAction: #selector(pickSnoozeDate(_:)))
        item.submenu = submenu
        item.isEnabled = canSnoozeSelection && !snoozable(snoozableSelection).isEmpty
        return item
    }

    /// Snoozes `ids` until `date` as one step: one store transaction writes the snoozes and archives what is in the
    /// Inbox (a conversation already out of it just gets its snooze), the rows leave the Inbox as after E, and the toast
    /// says when they come back. Its undo ends the snoozes, or puts back the times they had (a reschedule from Later), and
    /// moves the archived messages back through archive's own inverse. A conversation with nothing to put away is left
    /// as it is; with none to snooze it beeps, as E does when it changes nothing.
    func snooze(_ ids: [ConversationID], until date: Date) {
        let candidates = ids.filter { !LocalDraftConversation.isLocal($0) }
        let held = actionView == .trash || actionView == .drafts ? [] : snoozable(candidates)
        guard !held.isEmpty else {
            NSSound.beep()
            return
        }
        let ids = held.map(\.id)
        let prior = snoozedUntil
        // Archive's own records, from the messages just read: what is in the Inbox, and its inverse for the undo.
        let archived = held.compactMap { id, messages in
            MailActionRecord.make(.archive, on: MailActionRecord.targets(for: .archive, in: messages, kind: accountsByID[id.accountID]?.kind ?? .gmail),
                                  conversation: id)
        }
        // A conversation back from Later loses its mark as it is archived; the undo puts the mark back with it. Read from
        // the rows before the write, which may take them out of the list.
        let returned = returnMarks(of: ids)
        do {
            try environment.engine.setSnoozes(ids.map { Snooze.Change(conversationID: $0, until: date) },
                                              performing: archived.map { MailActionRecord.Step(change: .archive, targets: $0.targets) })
        } catch {
            Self.log.error("snooze failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return
        }
        let restore = ids.map { Snooze.Change(conversationID: $0, until: prior[$0], returnedAt: returned[$0]) }
        let inverse = archived.reversed().flatMap(\.inverse)
        let time = laterFormatter.dueTime(for: date, reference: laterFormatter.reference(now: laterNow()))
        let toasts = self.toasts
        let host = stepToastHost
        let toast = MailActionCopy.snoozed(until: time) { toasts.fits($0, symbol: Quire.Icon.later, actionTitle: "Undo", keycap: "Z", in: host) }
        let fromLater = actionView == .later
        let engine = environment.engine
        recordExternalUndo(command: MailActionCopy.snoozeCommand, accounts: Set(ids.map(\.accountID)), toast: toast,
                           symbol: Quire.Icon.later) { [weak self] in
            let back = self?.stillHeld(ids) ?? ids
            guard !back.isEmpty else {
                // Every conversation was deleted since (a deeper ⌘Z, §6.1): nothing to put back, so nothing to confirm.
                NSSound.beep()
                return
            }
            do {
                try engine.setSnoozes(restore, performing: self?.restorable(inverse) ?? inverse)
            } catch {
                Self.log.error("undoing a snooze failed: \(String(describing: error), privacy: .public)")
                NSSound.beep()
                return
            }
            self?.confirmUndo(of: MailActionCopy.snoozeCommand)
            self?.reselect(back, inLater: fromLater)
        }
        reportMailAction(.later, conversations: ids.count)
    }

    /// E and Archive: in Later, where everything is archived already, it ends the snoozes and leaves the conversations
    /// archived; everywhere else the ordinary archive.
    @discardableResult
    private func archive(_ ids: [ConversationID]? = nil) -> Bool {
        guard actionView == .later else { return mailAction(.archive, on: ids) }
        let targets = (ids ?? selectedIDs).filter { snoozedUntil[$0] != nil }
        guard !targets.isEmpty else { return mailAction(.archive, on: ids) }
        let prior = snoozedUntil
        do {
            try environment.engine.setSnoozes(targets.map { Snooze.Change(conversationID: $0, until: nil) }, performing: [])
        } catch {
            Self.log.error("ending a snooze failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return true
        }
        recordLaterArchive(targets.map { Snooze.Change(conversationID: $0, until: prior[$0]) })
        reportMailAction(.archive, conversations: targets.count)
        return true
    }

    /// E in Later's toast and undo. Another E within the coalescing window while its toast shows joins that step, as E does
    /// everywhere (§5.30): the toast counts every conversation, and one Z puts back every snooze the presses ended.
    private func recordLaterArchive(_ restore: [Snooze.Change]) {
        let command = MailActionCopy.commandName(for: .archive)
        actingReader?.tookStep = true
        let accounts = Set(restore.map(\.conversationID.accountID))
        guard let group = undoHistory.coalesceExternal(command: command, accounts: accounts, at: undoCenter.now(),
                                                       visibleToastID: undoCenter.coalescingToastID(in: actingPlace)) else {
            let id = recordExternalUndo(command: command, accounts: accounts,
                                        toast: MailActionCopy.toast(for: .archive, count: restore.count),
                                        symbol: Quire.Icon.archive, revert: laterArchiveRevert(restore))
            laterArchiveRestores[id] = restore
            return
        }
        let id = group.id
        let all = laterArchiveRestores[id, default: []] + restore
        laterArchiveRestores[id] = all
        externalUndos[id] = laterArchiveRevert(all)
        toasts.show(MailActionCopy.toast(for: .archive, count: all.count), kind: .undoable, symbol: Quire.Icon.archive,
                    actionTitle: "Undo", keycap: "Z", updating: group.toastID, in: stepToastHost) { [weak self] in self?.undo(groupID: id) }
        UndoSendPanel.refreshUndoKeyOwner()
    }

    /// Puts back the snoozes E ended in Later (or an unsubscribe ended, `inLater` false when it was a search's result),
    /// in one write, confirms the undo, and selects their conversations again.
    private func laterArchiveRevert(_ restore: [Snooze.Change], inLater: Bool = true,
                                    confirmation: String = MailActionCopy.undoConfirmation(for: .archive)) -> () -> Void {
        let engine = environment.engine
        return { [weak self] in
            let ids = restore.map(\.conversationID)
            let back = self?.stillHeld(ids) ?? ids
            guard !back.isEmpty else {
                // Deleted since (a deeper ⌘Z, §6.1): no snooze to put back, so nothing to confirm.
                NSSound.beep()
                return
            }
            do {
                try engine.setSnoozes(restore, performing: [])
            } catch {
                Self.log.error("undoing an archive in Later failed: \(String(describing: error), privacy: .public)")
                NSSound.beep()
                return
            }
            self?.confirmUndo(confirmation)
            self?.reselect(back, inLater: inLater)
        }
    }

    /// “Undid Snooze”: the confirmation an undo of a Later step shows, as a mail action's does.
    func confirmUndo(of command: String) {
        confirmUndo("Undid \(command)")
    }

    /// An undo's confirmation, in the window where the step was taken (§5.49).
    private func confirmUndo(_ words: String) {
        toasts.show(words, kind: .confirmation, symbol: Quire.Icon.undone, in: stepToastHost)
    }

    // MARK: Mute (Q3.7)

    /// What M acts on: the selection, less drafts kept on this Mac, which the store does not hold.
    private var muteSelection: [ConversationID] {
        selectedIDs.filter { !LocalDraftConversation.isLocal($0) }
    }

    /// M mutes the selection unless every conversation in it is muted already, then it unmutes, as S stars or unstars.
    private var mutesSelection: Bool {
        let selected = Set(muteSelection)
        let rows = list.conversations.filter { selected.contains($0.id) }
        return rows.isEmpty || rows.contains { !$0.isMuted }
    }

    /// M and Message › Mute: mutes the selection, archiving what is in the Inbox as E would, in one store transaction, so
    /// the rows leave the Inbox with E's toast and undo; mail arriving in a muted conversation is archived as it arrives
    /// (the store's arrival rules). Unmuting moves nothing. Out of the Inbox the row stays and its glyph says it, so a
    /// single mute there has no toast, as a star has none; Z still reaches it for the grace period.
    @discardableResult
    func toggleMute() -> Bool {
        let ids = muteSelection
        guard !showingWelcome, !ids.isEmpty else { return false }
        return toggleMute(ids, muting: mutesSelection)
    }

    /// M in a reader window (spec, Reader window (Q3.5)): its conversation muted, or unmuted when it is muted, by the
    /// rules of the view it was opened from. A mute that archives what the Inbox holds takes the conversation off the
    /// desk, as E does: the window closes and the main window comes forward with the toast, whose Undo opens it again. One
    /// that moves nothing (an unmute, a mute in All Mail) keeps the window open.
    func toggleMute(from reader: ReaderWindowController) {
        let id = reader.conversationID
        guard !showingWelcome, !LocalDraftConversation.isLocal(id) else {
            NSSound.beep()
            return
        }
        let muting = !isMuted(id)
        let archives = muting && !actionRecords(.archive, on: [id]).isEmpty
        act(in: reader, closing: archives) { toggleMute([id], muting: muting) }
    }

    /// Whether `id` is muted, read from the store: a reader window's conversation may have left the list.
    func isMuted(_ id: ConversationID) -> Bool {
        (try? environment.store.isMuted(id)) ?? false
    }

    @discardableResult
    private func toggleMute(_ ids: [ConversationID], muting: Bool) -> Bool {
        let rows = Dictionary(list.conversations.map { ($0.id, $0.isMuted) }, uniquingKeysWith: { first, _ in first })
        // Only those it changes, so the undo puts back exactly what M changed.
        let changing = ids.filter { rows[$0].map { $0 != muting } ?? true }
        guard !changing.isEmpty else {
            NSSound.beep()
            return true
        }
        let archived = muting ? actionRecords(.archive, on: changing) : []
        let engine = environment.engine
        do {
            try engine.setMuted(muting, conversations: changing,
                                performing: archived.map { MailActionRecord.Step(change: .archive, targets: $0.targets) })
        } catch {
            Self.log.error("mute failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return true
        }
        let command = MailActionCopy.muteCommand(muting: muting)
        let inverse = archived.reversed().flatMap(\.inverse)
        // A conversation back from Later loses its mark with the archive; the undo puts it back, as Z after E does.
        var returnMarks: [ConversationID: Date] = [:]
        for record in archived {
            if let id = record.conversation, let returnedAt = record.returnedAt { returnMarks[id] = returnedAt }
        }
        let fromLater = actionView == .later
        let revert: () -> Void = { [weak self] in
            let back = self?.stillHeld(changing) ?? changing
            guard !back.isEmpty else {
                // Deleted since (a deeper ⌘Z, §6.1): the mute went with its conversation, so nothing to confirm.
                NSSound.beep()
                return
            }
            do {
                try engine.setMuted(!muting, conversations: back, performing: self?.restorable(inverse) ?? inverse,
                                    returnMarks: returnMarks)
            } catch {
                Self.log.error("undoing a mute failed: \(String(describing: error), privacy: .public)")
                NSSound.beep()
                return
            }
            self?.confirmUndo(of: command)
            if !archived.isEmpty { self?.reselect(back, inLater: fromLater) }
        }
        // The list's own query: while searching, its view is the one the search looks through. In a reader window the
        // conversation is the row: a mute that closes the window says so, and one that leaves it open as the list would.
        let leaves: Bool
        if let reader = actingReader {
            leaves = !archived.isEmpty && (reader.isClosing || MailActionCopy.wantsToast(for: .archive, in: reader.view))
        } else {
            leaves = !archived.isEmpty && MailActionCopy.wantsToast(for: .archive, in: list.query.view, search: list.query.search)
        }
        if leaves || changing.count > 1 {
            recordExternalUndo(command: command, accounts: Set(changing.map(\.accountID)),
                               toast: MailActionCopy.muted(muting, count: changing.count),
                               symbol: muting ? Quire.Icon.mute : Quire.Icon.unmute, revert: revert)
        } else {
            recordQuietExternalUndo(command: command, accounts: Set(changing.map(\.accountID)), revert: revert)
        }
        reportMailAction(muting ? .mute : .unmute, conversations: changing.count)
        return true
    }

    /// A step the row itself shows (one mute on a row that stays): no toast, and Z reaches it for the grace period, as
    /// a star's undo does; ⌘Z reaches it as long as it is in the history.
    private func recordQuietExternalUndo(command: String, accounts: Set<AccountID>, revert: @escaping () -> Void) {
        let id = undoHistory.addExternal(command: command, accounts: accounts, at: undoCenter.now(), toasted: false)
        externalUndos[id] = revert
        actingReader?.tookStep = true
        rememberPlace(of: id)
        UndoSendPanel.refreshUndoKeyOwner()
    }

    // MARK: Sender rules (Q4.2)

    /// The rule the account has for mail from the message's sender.
    private func senderRule(for message: MessageMetadata) -> SenderRule.Action? {
        conversation.senderRule(for: message)
    }

    /// Sets the rule for `messageID`'s sender from a message's menu, in one store transaction with what the rule would
    /// have done to that sender's mail in the conversation had it come after the rule (Block: theirs out of the Trash;
    /// Always Archive: theirs in the Inbox), so the row leaves as it will for the next one. The toast always shows, since
    /// no row shows a rule; its Undo puts back the rule the sender had (none, or the other one) and the mail it moved.
    /// The rule is listed and removed in Settings › Accounts › Senders…, and nowhere else.
    @discardableResult
    func setSenderRule(_ action: SenderRule.Action, from messageID: MessageID) -> Bool {
        guard !showingWelcome, accountsByID[messageID.accountID] != nil, let message = (try? environment.store.message(messageID)) ?? nil,
              conversation.offersSenderRule(message), let address = message.from?.address else {
            NSSound.beep()
            return false
        }
        let previous = senderRule(for: message)
        guard previous != action else { return true }
        let sender = SenderRule.normalizedAddress(address)
        let theirs = ((try? environment.store.messages(in: message.conversationID)) ?? []).filter { other in
            other.from.map { SenderRule.normalizedAddress($0.address) == sender } ?? false
                && ArrivalRule.change(for: other, inMutedConversation: false, senderRule: action) == action.change
        }
        let record = MailActionRecord.make(action.change, on: theirs, conversation: message.conversationID)
        let engine = environment.engine
        let accountID = messageID.accountID
        do {
            try engine.setSenderRule(action, for: address, accountID: accountID,
                                     performing: record.map { [MailActionRecord.Step(change: action.change, targets: $0.targets)] } ?? [])
        } catch {
            Self.log.error("setting a sender rule failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            return false
        }
        reportMailAction(action == .trash ? .blockSender : .alwaysArchiveSender, conversations: 1)
        let command = MailActionCopy.senderRuleCommand(action)
        let inverse = record?.inverse ?? []
        let conversationID = message.conversationID
        let fromLater = actionView == .later
        recordExternalUndo(command: command, accounts: [accountID], toast: MailActionCopy.senderRuleSet(action, address: sender),
                           symbol: action == .trash ? Quire.Icon.blockSender : Quire.Icon.alwaysArchiveSender) { [weak self] in
            do {
                try engine.setSenderRule(previous, for: address, accountID: accountID, performing: self?.restorable(inverse) ?? inverse)
            } catch {
                Self.log.error("undoing a sender rule failed: \(String(describing: error), privacy: .public)")
                NSSound.beep()
                return
            }
            self?.confirmUndo(of: command)
            // The rule comes back whatever became of the mail; the conversation is selected only while it is still there.
            if record != nil, self?.stillHeld([conversationID]).isEmpty == false { self?.reselect([conversationID], inLater: fromLater) }
        }
        return true
    }

    /// Message › Always Archive Mail from This Sender, Block Sender and the context menu's items: the sender of the open
    /// conversation's target message, or of its newest mail from someone else (`senderRuleTarget`).
    private func setSenderRuleFromMenu(_ action: SenderRule.Action) {
        guard let target = conversation.senderRuleTarget else {
            NSSound.beep()
            return
        }
        setSenderRule(action, from: target.id)
    }

    // MARK: Rows dropped on the rail (§5.2)

    /// Whether the rail's folder `tile` takes these dragged conversations. `RailDrop` decides from the rows as
    /// the list holds them, so a drag over the rail reads nothing from the store; the list's own query says
    /// whether they are search results, since a blank search shows the view, and which view they are rows of
    /// (`listView`, as for the keys), so the Trash refuses `in:trash` results as # leaves them be and takes a
    /// search's All Mail results from the Trash as # trashes them.
    func acceptsDrop(of ids: [ConversationID], onto tile: MailboxView) -> Bool {
        guard !showingWelcome else { return false }
        let dragged = Set(ids)
        return RailDrop.accepts(tile, rows: list.conversations.filter { dragged.contains($0.id) }, selectedView: listView,
                                isSearching: list.query.searchText != nil)
    }

    /// Rows dropped on a rail folder take the path of the key that folder stands for (⇧I, S, #, E): one change
    /// on all of them, applied to the store and queued in one call, with that key's toast and undo. They need
    /// not be the selection. In Drafts, Trash is Discard Draft…, asked first, as # is there (§5.12).
    @discardableResult
    func drop(_ ids: [ConversationID], onto tile: MailboxView) -> Bool {
        guard acceptsDrop(of: ids, onto: tile), let change = RailDrop.change(for: tile) else { return false }
        if change == .trash, listView == .drafts {
            confirmDiscardDrafts(ids)
            return true
        }
        return Analytics.from(.drag) { mailAction(change, on: ids.filter { !LocalDraftConversation.isLocal($0) }) }
    }

    // MARK: Swipe (§5.7)

    /// A swipe on a row, or the row's VoiceOver action: the key's change on that one conversation, whatever is selected,
    /// through the key's own path (E's in Later, where it ends the snooze), so the toast, the coalescing, the undo and
    /// the selection moving on are the key's. The list offers only what the key would change (`RowSwipe`).
    private func rowAction(_ change: MetadataChange, on id: ConversationID) {
        guard !showingWelcome else { return }
        Analytics.from(.swipe) {
            if change == .archive {
                archive([id])
            } else {
                mailAction(change, on: [id])
            }
        }
    }

    /// Reverts group `groupID` where it was taken (§5.49): a step taken in a reader window confirms itself there, and one
    /// that closed its window opens it again where it was, so the conversation comes back where the user left it. A mail
    /// action's window opens once its revert has brought the mail back, so the window never shows (or is named after) a
    /// conversation still in Spam or the archive; any other step's opens first, for that step's undo to act in.
    ///
    /// A deeper ⌘Z (§6.1), once the step's toast and grace are over, opens no window again: the step may be minutes old,
    /// and a window springing up where the user left it then would come as a surprise, in the middle of a run of ⌘Z. A
    /// reader window's step whose window has gone is then undone as the main window's own: the conversation comes back
    /// selected in the list, with the confirmation there. A step whose window is still open is undone in it, however old.
    /// What can no longer be put back (mail deleted since) is left out; a step with nothing left goes with a beep, and the
    /// next ⌘Z reaches the step before it.
    @discardableResult
    private func undo(groupID: Int) -> Bool {
        let recent = undoHistory.isRecent(groupID, at: undoCenter.now())
        let taken = undoCenter.place(of: groupID).reader
        guard let group = undoHistory.remove(groupID) else {
            NSSound.beep()
            return true
        }
        Analytics.send(.undo(Analytics.trigger))
        defer {
            forgetGroupsGone()
            undoCenter.forgetPlacesOfGroupsGone()
            UndoSendPanel.refreshUndoKeyOwner()
        }
        // Where the undo lands: the step's window while Z still reaches the step, as ever; for a deeper ⌘Z only a window
        // still open (the place holds it weakly), else the main window.
        let place = recent ? taken : taken.flatMap { $0.window != nil ? $0 : nil }
        let reopenIfClosed = { [weak self] in
            if let place, place.window == nil, let frame = place.closedFrame { self?.reopen(place, at: frame) }
        }
        let records = restorable(group.records)
        if group.change != nil, records.isEmpty {
            // Every message it changed is gone (deleted, or its account removed): nothing to put back, and no window to open.
            Self.log.info("undo: nothing left of the step to put back")
            unsubscribeUndoConfirmations.removeValue(forKey: groupID)
            taken?.viewsBeforeMove.removeValue(forKey: groupID)
            NSSound.beep()
            return true
        }
        if group.change == nil { reopenIfClosed() }
        let previous = actingReader
        actingReader = place
        defer { actingReader = previous }
        // A Move to Inbox taken in a reader window made it treat its conversation as an Inbox row; the undo puts the view it
        // was opened from back, so its keys, menus and header agree with where the conversation is again.
        if let taken, let view = taken.viewsBeforeMove.removeValue(forKey: groupID) {
            if let window = taken.window { window.conversationMoved(to: view) } else { taken.view = view }
        }
        guard let change = group.change else {
            groupsFromLater.remove(groupID)
            externalUndos.removeValue(forKey: groupID)?()
            return true
        }
        let fromLater = groupsFromLater.remove(groupID) != nil
        do {
            try revert(records)
        } catch {
            Self.log.error("undo failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            reopenIfClosed()
            return true
        }
        reopenIfClosed()
        let words = unsubscribeUndoConfirmations.removeValue(forKey: groupID) ?? MailActionCopy.undoConfirmation(for: change)
        confirmUndo(words)
        let restored = records.compactMap(\.conversation)
        if !restored.isEmpty, [.archive, .trash, .markSpam, .moveToInbox, .restoreFromTrash].contains(change) {
            // The rows come back; put the selection on them so the user sees what was restored.
            reselect(restored, inLater: fromLater)
        }
        return true
    }

    /// What of `records` can still be put back, read from the store now: ⌘Z can come long after the step (§6.1), when a
    /// message may have been deleted or its account removed. Mail that arrived since is in no step and stays where it is.
    /// One read per conversation.
    private func restorable(_ records: [MailActionRecord]) -> [MailActionRecord] {
        let store = environment.store
        return records.compactMap { record in
            guard let account = record.accountID, accountsByID[account] != nil else { return nil }
            guard let conversation = record.conversation else {
                return record.keeping { (try? store.message($0)) != nil }
            }
            let held = Set(((try? store.messages(in: conversation)) ?? []).map(\.id))
            return record.keeping(held.contains)
        }
    }

    /// The conversations of `ids` the store still holds mail in, for accounts still here: an external step's revert (a
    /// snooze, Later's archive, a mute, a sender rule) can come as late as a mail action's (§6.1), and one with none left has
    /// nothing to put back, to confirm or to select, which would only open an emptied reader.
    private func stillHeld(_ ids: [ConversationID]) -> [ConversationID] {
        let store = environment.store
        return ids.filter { accountsByID[$0.accountID] != nil && !((try? store.messages(in: $0)) ?? []).isEmpty }
    }

    /// The part of `steps` on messages the store still holds, for accounts still here: an external step's revert (a
    /// snooze, a mute, a sender rule, discarded drafts) can come as late as a mail action's.
    private func restorable(_ steps: [MailActionRecord.Step]) -> [MailActionRecord.Step] {
        let store = environment.store
        return steps.compactMap { step in
            let kept = step.targets.filter { accountsByID[$0.accountID] != nil && (try? store.message($0)) != nil }
            return kept.isEmpty ? nil : MailActionRecord.Step(change: step.change, targets: kept)
        }
    }

    /// Applies the inverse of `records`, newest first. A Move to Inbox, Move to Trash or Mark as Spam that ended a snooze puts
    /// it back with the inverse steps, in one transaction, so the conversation never shows in the Inbox between the two; an
    /// Archive, Move to Trash or Mark as Spam of a conversation back from Later puts its return mark back, so the row returns
    /// under Today with its Back tag. A Mark as Spam of a muted conversation mutes it again (the mute went with its summary
    /// row): with the inverse steps, in one transaction, when nothing else is put back; right after the snoozes and marks
    /// otherwise, which take a transaction of their own.
    private func revert(_ records: [MailActionRecord]) throws {
        let engine = environment.engine
        let snoozes = records.compactMap { record -> Snooze.Change? in
            guard let id = record.conversation, record.snoozedUntil != nil || record.returnedAt != nil else { return nil }
            return Snooze.Change(conversationID: id, until: record.snoozedUntil, returnedAt: record.returnedAt)
        }
        let muted = records.filter(\.wasMuted).compactMap(\.conversation)
        let inverse = records.reversed().flatMap(\.inverse)
        if !snoozes.isEmpty {
            try engine.setSnoozes(snoozes, performing: inverse)
            if !muted.isEmpty { try engine.setMuted(true, conversations: muted, performing: []) }
        } else if !muted.isEmpty {
            try engine.setMuted(true, conversations: muted, performing: inverse)
        } else {
            for step in inverse {
                try engine.perform(step.change, on: step.targets)
            }
        }
    }

    // MARK: Send and Archive (§5.23)

    /// Archives the conversation `original` belongs to right after a send answering it was queued, as E would: what is in
    /// the Inbox is archived, a conversation back from Later keeps its return mark for the undo, and a snoozed one, archived
    /// already, has its snooze ended and stays archived, as E ends it in Later. Nothing joins the undo history and no toast
    /// shows: the send's own undo (its panel, the quick reply's strip, ⌘Z) puts the conversation back with the send, as Z
    /// after E would, so there is one undo for both. Only this window's mail, through its own engine.
    func archiveConversation(answering original: MessageID, client: MailClient) -> SendArchive? {
        guard client === environment.engine, !showingWelcome, accountsByID[original.accountID] != nil,
              let message = try? environment.store.message(original) else { return nil }
        let id = message.conversationID
        let engine = environment.engine
        // Where the user was: an undo selects the conversation again only if the archive took it off the screen, and in
        // Later only if Later emptied meanwhile (`reselect`), as Z after E does.
        let wasShown = shownSelection == [id]
        let inLater = listView == .later
        let snoozedAt = ((try? environment.store.snoozes()) ?? []).first { $0.conversationID == id }?.dueAt
        if let snoozedAt {
            do {
                try engine.setSnoozes([Snooze.Change(conversationID: id, until: nil)], performing: [])
            } catch {
                Self.log.error("ending a snooze after a send failed: \(String(describing: error), privacy: .public)")
                return nil
            }
            return SendArchive(conversation: id) { [weak self] in
                do {
                    try engine.setSnoozes([Snooze.Change(conversationID: id, until: snoozedAt)], performing: [])
                } catch {
                    Self.log.error("putting a snooze back after an undone send failed: \(String(describing: error), privacy: .public)")
                    return
                }
                if wasShown { self?.reselect([id], inLater: inLater) }
            }
        }
        let records = actionRecords(.archive, on: [id])
        guard !records.isEmpty else { return nil }
        do {
            try engine.perform(.archive, on: records.flatMap(\.targets))
        } catch {
            Self.log.error("archiving after a send failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        return SendArchive(conversation: id) { [weak self] in
            guard let self else { return }
            do {
                try self.revert(records)
            } catch {
                Self.log.error("bringing a conversation back after an undone send failed: \(String(describing: error), privacy: .public)")
                return
            }
            if wasShown { self.reselect([id], inLater: inLater) }
        }
    }

    /// Puts the selection on conversations an undo brought back. Back in Later when the action was taken there and Later
    /// emptied meanwhile, sending the window to the Inbox: the snooze is restored, so Later shows again. Not when the user
    /// has since picked a view or a scope, or typed a search, which the undo leaves as they are.
    private func reselect(_ restored: [ConversationID], inLater: Bool) {
        // A step taken in a reader window is undone there: its window shows the conversation, and the list is left as the
        // user has it.
        guard !restored.isEmpty, actingReader == nil else { return }
        if inLater, viewLeftAsItEmptied == .later, mailboxView != .later, searchText.isEmpty {
            // Read now rather than on the observation's next delivery, so the tile and the view agree at once.
            if let current = try? environment.store.snoozes() { snoozesChanged(current) }
            setView(.later)
        }
        list.selectConversations(restored, lead: restored.last)
        present(selection: restored.count > 1 ? restored : [restored[0]])
    }

    /// The provider refused an action and the store put the row back (§5.7): say so.
    private func operationsFailed(_ failures: [(ConversationID, OperationKind)]) {
        guard let kind = failures.last?.1 else { return }
        toasts.show(MailActionCopy.failure(for: kind), kind: .error)
    }

    private func symbol(for change: MetadataChange) -> String {
        switch change {
        case .archive: return Quire.Icon.archive
        case .trash: return Quire.Icon.trash
        case .moveToInbox, .restoreFromTrash, .markNotSpam: return Quire.Icon.moveToInbox
        case .markSpam: return Quire.Icon.spam
        case .setRead(true): return Quire.Icon.markRead
        case .setRead(false): return Quire.Icon.markUnread
        case .setStarred: return Quire.Icon.star
        // Its toast offers Undo for the archive beside it, so it wears the archive's symbol.
        case .unsubscribe: return Quire.Icon.archive
        case .answerInvitation: return Quire.Icon.invitation
        }
    }

    /// The reader's actions (`ConversationViewController.onAction`); internal so the app's tests can send them. They come
    /// from its header's and the page's buttons, or from a key in a reader window (`Analytics.trigger` tells a key).
    func handle(_ action: ConversationAction) {
        Analytics.from(.toolbar) { take(action) }
    }

    private func take(_ action: ConversationAction) {
        switch action {
        case .reply(let id):
            compose(.reply(id, all: false), accountID: id.accountID)
        case .replyAll(let id):
            compose(.reply(id, all: true), accountID: id.accountID)
        case .forward(let id):
            compose(.forward(id), accountID: id.accountID)
        case .archive(let id):
            archive([id])
        case .star(let id, let starred):
            mailAction(.setStarred(starred), on: [id])
        case .changeMessages(let change, let ids):
            messageAction(change, on: ids)
        case .trash(let id):
            mailAction(.trash, on: [id])
        case .moveToInbox(let id):
            mailAction(.moveToInbox, on: [id])
        case .applyToSelection(let change, let ids):
            if change == .archive { archive(ids) } else { mailAction(change, on: ids) }
        case .openAttachment:
            // The reader already opened Quick Look.
            break
        case .attachmentsSaved(let outcome):
            showSaved(outcome)
        case .continueDraft(let id):
            continueDraft(id)
        case .discardDrafts(let ids):
            confirmDiscardDrafts(ids)
        case .reveal(let id):
            reveal(id)
        case let .replyInComposer(id, all, body, attach):
            beforeCompose?()
            guard let account = accounts.first(where: { $0.id == id.accountID }) ?? accounts.first else { return }
            ComposeWindowController.present(client: environment.engine, account: account, accounts: accounts, mode: .reply(id, all: all),
                                            body: body, attach: attach)
        case .cancelSendLater(let id):
            cancelSendLater(id)
        case .quickReplyFailed(let draft):
            // §5.18: the bar is not involved; the draft is already kept, so this toast only points at it.
            let engine = environment.engine
            toasts.show("Couldn\u{2019}t send your reply", kind: .error, symbol: Quire.Icon.error, actionTitle: "Open draft",
                        in: stepToastHost) { [weak self] in
                guard let self else { return }
                ComposeWindowController.present(client: engine, accounts: self.accounts, draft: draft)
            }
        case .unsubscribe(let id):
            unsubscribe(from: id)
        case .senderRule(let action, let id):
            setSenderRule(action, from: id)
        case .escapeQuickReply:
            // §6.1: a visible toast takes the first Esc; the next returns to the list, the bar keeping its text.
            if toasts.isVisible(in: listPane.toastView) {
                toasts.dismiss()
            } else {
                focusList()
            }
        case .reconnect(let id):
            // The engine adds the permission the account waits for to the sign-in it starts (§5.44).
            if let account = accountsByID[id] { requestReconnect(account) }
        case let .newMessage(address, accountID):
            // From the conversation's account, as the composer token's New Message writes from its window's (§5.14).
            beforeCompose?()
            guard let account = accountsByID[accountID] ?? newMessageAccount else { return }
            ComposeWindowController.presentNew(client: environment.engine, account: account, accounts: accounts, to: address)
        case .showMail(let address):
            showMail(from: address)
        }
    }

    /// Show Mail from This Person (spec §5.14): the search field takes `from:` the address and runs it as if typed, and
    /// the list takes the keyboard with the query kept. A search looks through all the mail but the Trash from any view,
    /// so this is all of theirs. From a reader window this window comes forward first.
    func showMail(from address: String) {
        guard !showingWelcome else { return }
        if actingReader != nil { comeForward() }
        listPane.runSearch(HeaderAddress.fromQuery(address))
    }

    // MARK: Reader windows (§5.49)

    /// The view the step being taken treats its conversations as rows of: the list's, or the acting reader window's.
    private var actionView: MailboxView { actingReader?.view ?? listView }

    private var actingPlace: UndoPlace { actingReader.map(UndoPlace.reader) ?? .main }

    /// Where the toast of the step being taken (or undone) shows: the reader window it was taken in while that stays open,
    /// else the main window's list (nil).
    var stepToastHost: ToastView? {
        guard let reader = actingReader, !reader.isClosing else { return nil }
        return reader.window?.toastView
    }

    /// The conversation ⌘O opens: the one selected, outside Drafts (a draft opens in its composer), the Outbox (a message on
    /// its way is no conversation, §5.53) and the welcome screen.
    private var conversationToOpenInWindow: ConversationID? {
        guard !showingWelcome, !isSeveralSelected, listView != .drafts, listView != .outbox,
              let id = list.selectedConversationID, !LocalDraftConversation.isLocal(id) else { return nil }
        return id
    }

    /// File › Open in New Window (⌘O): the selected conversation in a reader window. With several selected, in Drafts, in
    /// the Outbox or with nothing selected it beeps.
    @objc func openSelectionInNewWindow(_ sender: Any?) {
        guard let id = conversationToOpenInWindow else {
            NSSound.beep()
            return
        }
        openInNewWindow(id)
    }

    /// Opens `id` in a reader window, or brings forward the one already showing it (⌘O; ↩ on the list and a double-click on
    /// a row, outside Drafts and the Outbox). The window treats the conversation as a row of the list's view, as the keys
    /// here do.
    @discardableResult
    func openInNewWindow(_ id: ConversationID) -> ReaderWindowController? {
        guard !showingWelcome, accountsByID[id.accountID] != nil, !LocalDraftConversation.isLocal(id), listView != .drafts,
              listView != .outbox else {
            NSSound.beep()
            return nil
        }
        if let open = readerWindows.first(where: { $0.conversationID == id }) {
            bringForward(open)
            return open
        }
        let place = ReaderWindowPlace(conversation: id, view: listView)
        place.returnedAt = list.conversations.first { $0.id == id }?.returnedAt
        Analytics.send(.readerWindowOpened(Analytics.trigger))
        return present(place, at: nil)
    }

    /// Opens a step's reader window again where the step closed it: its undo brings the conversation back there.
    private func reopen(_ place: ReaderWindowPlace, at frame: NSRect) {
        place.closedFrame = nil
        if let open = readerWindows.first(where: { $0.conversationID == place.conversation }) {
            bringForward(open)
            return
        }
        present(place, at: frame)
    }

    @discardableResult
    private func present(_ place: ReaderWindowPlace, at frame: NSRect?) -> ReaderWindowController {
        let reader = ReaderWindowController(place: place, client: environment.engine, accountsByID: accountsByID,
                                            drafts: quickReplyDrafts, findSession: findSession, settings: settings,
                                            undoCenter: undoCenter, opener: self)
        readerWindows.append(reader)
        reader.place(at: frame, cascadingFrom: readerWindows.dropLast().last?.window ?? window)
        bringForward(reader)
        return reader
    }

    /// A G-sequence typed in a reader window: this window comes forward on that view.
    func goTo(_ view: MailboxView) {
        comeForward()
        setView(view)
    }

    /// This window becomes key in front of a reader window: for a search, a G-sequence, or a step that closed the window.
    func comeForward() {
        bringForward(self)
    }

    /// A reader window closed (⌘W, the close button, or a step that took its conversation away). This window's reader goes
    /// on watching the window's replies past their undo window (`sends`), so a failure still shows its error toast, here
    /// (§5.18). Closed by the user while this window shows the same conversation, the text the window's quick reply held
    /// comes into this one's; closed by a step, it stays parked for the window that step's undo opens again.
    func readerWindowDidClose(_ reader: ReaderWindowController, watching sends: [String: ComposeDraft]) {
        readerWindows.removeAll { $0 === reader }
        conversation.watch(sends)
        if reader.place.closedFrame == nil { conversation.takeParkedQuickReply() }
        UndoSendPanel.refreshUndoKeyOwner()
    }

    /// Send and Archive in a reader window's quick reply took the conversation off the desk, as E does: the window closes,
    /// its countdown moving to an undo-send panel (§5.18) whose Undo brings back the reply and the conversation, and this
    /// window comes forward with the panel. On the next turn of the run loop, after the send's key has been handled in the
    /// window it closes.
    func quickReplyArchived(in reader: ReaderWindowController) {
        DispatchQueue.main.async { [weak self, weak reader] in
            MainActor.assumeIsolated {
                guard let self, let reader, self.readerWindows.contains(where: { $0 === reader }) else { return }
                reader.close()
                self.comeForward()
            }
        }
    }

    /// A reader window's action on its conversation (spec §5.49), from its keys, header, menus or page: taken here, by the
    /// rules of the view the window was opened from, with its toast in that window. Archive, Move to Trash, Unsubscribe and
    /// a confirmed Discard Draft… take the conversation off the desk: the window closes as the step is taken, and the main
    /// window comes forward with the toast, whose Undo opens the window again.
    func perform(_ action: ConversationAction, from reader: ReaderWindowController) {
        let closes: Bool
        switch action {
        case .archive, .trash, .unsubscribe: closes = true
        // Mark as Spam takes the conversation out of every view, as # takes it to the Trash.
        case .applyToSelection(let change, _): closes = change == .archive || change == .trash || change == .markSpam
        case .discardDrafts(let ids):
            // Asked on this window, and the confirmed discard is its step: the conversation goes to the Trash, and the
            // window with it, as after #.
            confirmDiscardDrafts(ids, from: reader)
            return
        default: closes = false
        }
        let view = reader.place.view
        let tookStep = act(in: reader, closing: closes) { handle(action) }
        if tookStep, case .moveToInbox = action {
            // Its undo puts the view back (`undo(groupID:)`); a press that joined an earlier one keeps that one's.
            if let id = undoHistory.groups.last?.id, reader.place.viewsBeforeMove[id] == nil { reader.place.viewsBeforeMove[id] = view }
            reader.conversationMoved(to: .inbox)
        }
    }

    /// L in a reader window: the Later menu for its conversation, hung from its header (§5.45). In the Trash it beeps.
    @discardableResult
    func showLaterMenu(for reader: ReaderWindowController) -> Bool {
        guard reader.place.view != .trash, reader.place.view != .drafts, !snoozable([reader.conversationID]).isEmpty else {
            NSSound.beep()
            return true
        }
        let anchor = reader.conversation.header.menuAnchor
        let offset = Quire.Layout.Menu.titleMenuOffsetY
        popUpLaterMenu(laterMenu(target: reader), NSPoint(x: anchor.minX, y: anchor.maxY + offset), reader.conversation.header)
        return true
    }

    /// The Later menu's presets and Pick a Date…, acting through `target`'s `snoozeSelectionUntil(_:)` and
    /// `pickSnoozeDate(_:)`.
    func laterMenu(target: AnyObject) -> NSMenu {
        LaterMenu.build(now: laterNow(), formatter: laterFormatter, target: target,
                        presetAction: #selector(snoozeSelectionUntil(_:)), pickAction: #selector(pickSnoozeDate(_:)))
    }

    /// Whether L applies to a reader window's conversation, for its menus.
    func canSnooze(in reader: ReaderWindowController) -> Bool {
        reader.place.view != .trash && reader.place.view != .drafts && !snoozable([reader.conversationID]).isEmpty
    }

    /// A Later preset chosen in a reader window: its conversation snoozed, and the window closed with it.
    func snooze(from reader: ReaderWindowController, until date: Date) {
        act(in: reader, closing: true) { snooze([reader.conversationID], until: date) }
    }

    /// Pick a Date… in a reader window: the sheet on that window, for its conversation.
    func pickSnoozeDate(for reader: ReaderWindowController) {
        guard canSnooze(in: reader) else {
            NSSound.beep()
            return
        }
        let picker = LaterDatePicker(count: 1, now: laterNow)
        presentLaterDatePicker(picker, reader.window) { [weak self, weak reader] date in
            guard let self, let reader, let date else { return }
            self.snooze(from: reader, until: date)
        }
    }

    /// Takes `step` as `reader`'s, and closes the window after it when `closing` and the step changed something (it joined
    /// the undo history): the main window comes forward with its toast, and the window's frame is kept for the undo.
    /// Returns whether the step changed anything.
    @discardableResult
    func act(in reader: ReaderWindowController, closing: Bool, _ step: () -> Void) -> Bool {
        let place = reader.place
        let previous = actingReader
        actingReader = place
        place.isClosing = closing
        place.tookStep = false
        step()
        actingReader = previous
        place.isClosing = false
        let tookStep = place.tookStep
        if closing, tookStep {
            place.closedFrame = reader.window?.frame
            reader.close()
            comeForward()
        }
        return tookStep
    }

    // MARK: Drafts (§5.19)

    /// The Drafts view lists the kept drafts beside the provider's; a provider's draft that a kept one continues
    /// gives way to it.
    private func showLocalDrafts() {
        list.localDrafts = localDrafts.summaries
        list.outboxRows = localDrafts.outboxSummaries
        let store = environment.store
        list.hiddenDrafts = Set(localDrafts.continuedDrafts.compactMap { try? store.message($0)?.conversationID })
    }

    // MARK: Outbox (§5.53)

    /// A send in the scope (all accounts, or the narrowed one) waits to go: one of the sends the Outbox lists, of the
    /// accounts this window knows. The Outbox shows in the rail, the title menu and the View menu, and G O opens it, only
    /// while this holds (§5.2, §5.53).
    var showsOutbox: Bool { localDrafts.listsOutboxSends(of: scope.accountIDs) }

    /// Shows or hides the Outbox's tile, from each word of the outbox and each change of scope or accounts. The last send in
    /// view went (taken by the provider, kept in Drafts as failed, cancelled, taken back) while the Outbox was shown, or the
    /// scope moved to an account with none: nothing is left to show there, so the window goes back to the Inbox, as from
    /// Later. A search the user typed stays: it shows All Mail or its `in:` view whatever the rail's, so its results,
    /// selection and reader stay too, and clearing it lands in the Inbox.
    private func applyOutboxAvailability() {
        let shows = showsOutbox
        strip.setShowsOutbox(shows)
        if mailboxView == .outbox, !shows {
            mailboxView = .inbox
            viewLeftAsItEmptied = .outbox
            applyQuery()
        }
    }

    /// In Drafts, ↩, → and a double-click on a row are Continue Editing (§5.19): the draft opens in its composer, never in
    /// the reader or a reader window. In the Outbox they are too on a Send Later message still held (§5.53), which is the
    /// same row as in Drafts; a message on its way only shows. False elsewhere, where they open the conversation.
    private func continuesEditing(_ id: ConversationID) -> Bool {
        switch listView {
        case .drafts:
            break
        case .outbox:
            guard localDrafts.outboxSend(for: id).flatMap(OutboxState.init)?.isHeld == true else { return false }
        default:
            return false
        }
        if let draft = draftMessageID(in: id) { continueDraft(draft) }
        return true
    }

    /// ↩ and → outside Drafts, and anything that opens an Outbox row: the conversation in the main window's reader, which
    /// takes the keyboard.
    private func showInReader(_ id: ConversationID) {
        if conversation.currentConversationID != id { conversation.show(id) }
        focusReader()
    }

    /// The draft a Drafts row stands for: a kept draft's own message, or the conversation's newest draft.
    private func draftMessageID(in id: ConversationID) -> MessageID? {
        if let sendID = SendLaterConversation.sendID(of: id) {
            return SendLaterConversation.messageID(sendID: sendID, account: id.accountID)
        }
        if let draftID = LocalDraftConversation.draftID(of: id) {
            return LocalDraftConversation.messageID(draftID: draftID, account: id.accountID)
        }
        let messages = (try? environment.store.messages(in: id)) ?? []
        return (messages.last { $0.roles.contains(.drafts) } ?? messages.last)?.id
    }

    /// Continue Editing: a kept draft reopens as it was left (its window comes forward if open), so sending it
    /// leaves nothing behind; a provider's draft goes through `DraftReopener`. A Send Later message's schedule is
    /// cancelled first (§5.19): what is being changed must not go at the old time.
    private func continueDraft(_ id: MessageID) {
        if let sendID = SendLaterConversation.sendID(of: id) {
            guard let send = localDrafts.laterSends.first(where: { $0.id == sendID }), let draft = sendLaterOutbox.cancel(send) else {
                NSSound.beep()
                return
            }
            sendLaterOutbox.refresh()
            ComposeWindowController.present(client: environment.engine, accounts: accounts, draft: draft)
            return
        }
        if let draftID = LocalDraftConversation.draftID(of: id) {
            if !ComposeWindowController.reopenKeptDraft(id: draftID, client: environment.engine, accounts: accounts) { NSSound.beep() }
            return
        }
        if !DraftReopener.present(id, client: environment.engine, accounts: accounts) { NSSound.beep() }
    }

    /// “Discard this draft?” (or “Discard 3 drafts?”), the reader's form (§5.33), from the header, the sheet's
    /// footer or #. From a reader window (`reader`) it asks on that window, and the confirmed discard is that window's
    /// step: its toast and undo place are the window's, and the window closes with its conversation, as after # (§5.49).
    private func confirmDiscardDrafts(_ ids: [ConversationID], from reader: ReaderWindowController? = nil) {
        guard !ids.isEmpty else { return }
        let recipient = ids.count == 1 ? draftMessageID(in: ids[0]).flatMap(draftRecipient(of:)) : nil
        presentAlert(AppAlert.discardDrafts(count: ids.count, recipient: recipient), reader?.window ?? window) { [weak self, weak reader] choice in
            guard choice == 1, let self else { return }
            if let reader, self.readerWindows.contains(where: { $0 === reader }) {
                self.act(in: reader, closing: true) { self.discardDrafts(ids) }
            } else {
                self.discardDrafts(ids)
            }
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
        // Send Later messages discarded: their schedules come back with their drafts on Undo, while their times are ahead.
        var rescheduled: [(draft: ComposeDraft, date: Date)] = []
        for id in ids {
            if SendLaterConversation.sendID(of: id) != nil {
                guard let send = localDrafts.laterSend(for: id), let draft = sendLaterOutbox.cancel(send) else { continue }
                kept.append(draft)
                rescheduled.append((draft, send.sendAfter))
                ComposeDraftStore.shared.remove(id: draft.id)
            } else if let draftID = LocalDraftConversation.draftID(of: id) {
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
        let now = laterNow
        let outbox = sendLaterOutbox
        recordExternalUndo(command: "Discard Draft", accounts: Set(ids.map(\.accountID)),
                           toast: count == 1 ? "Draft discarded" : "Discarded \(count) drafts", symbol: Quire.Icon.trash) { [weak self] in
            for draft in kept { ComposeDraftStore.shared.saveNow(draft) }
            // A time that passed meanwhile is not sent on an Undo: the message comes back as a draft to send by hand.
            for item in rescheduled where item.date > now() {
                outbox.schedule(item.draft, at: item.date) { if $0 == nil { NSSound.beep() } }
            }
            do {
                // Only what is still there: a deeper ⌘Z can come after a draft was deleted for good.
                for record in self?.restorable(records).reversed() ?? [] {
                    for step in record.inverse { try engine.perform(step.change, on: step.targets) }
                }
            } catch {
                Self.log.error("bringing back drafts failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    // MARK: Send Later (§5.23)

    /// Cancel beside a Send Later message's time: the schedule goes and the message stays in Drafts as the draft it was
    /// written in, selected in place of the row, with “Send Later cancelled · Undo”; Undo schedules that draft again for
    /// the same time while that is ahead.
    ///
    /// The draft is free to change once cancelled, so Undo schedules it as it is then, as the composer would, not the
    /// message as it was cancelled; and not at all once it has gone (sent or discarded) or while a composer holds it,
    /// where the message would be both scheduled and open for sending.
    func cancelSendLater(_ id: ConversationID) {
        guard let send = localDrafts.laterSend(for: id), let draft = sendLaterOutbox.cancel(send) else {
            NSSound.beep()
            return
        }
        // Read before the rows change: cancelling the last send in view takes the window out of the Outbox.
        let inOutbox = listView == .outbox
        // The rows change now rather than at the observation, so the draft can take the selection.
        sendLaterOutbox.refresh()
        let row = LocalDraftConversation.conversationID(draftID: draft.id, account: draft.account.id)
        // In Drafts the draft takes the row's place and the selection; in the Outbox the row just leaves (§5.53).
        if listView == .drafts, list.selectedConversationID == id { list.selectConversations([row], lead: row) }
        let now = laterNow
        let date = send.sendAfter
        recordExternalUndo(command: SendLaterCopy.command, accounts: [id.accountID], toast: SendLaterCopy.command + " cancelled",
                           symbol: Quire.Icon.later) { [weak self] in
            guard let self, date > now(),
                  !ComposeWindowRegistry.shared.openControllers.contains(where: { $0.draftID == draft.id }),
                  let current = ComposeDraftStore.shared.draft(id: draft.id, accounts: self.accounts) else {
                NSSound.beep()
                return
            }
            self.sendLaterOutbox.schedule(current, at: date) { [weak self] sendID in
                guard let self, let sendID else {
                    NSSound.beep()
                    return
                }
                self.sendLaterOutbox.refresh()
                let restored = SendLaterConversation.conversationID(sendID: sendID, account: current.account.id)
                if inOutbox, self.viewLeftAsItEmptied == .outbox, self.mailboxView != .outbox, self.searchText.isEmpty {
                    // Cancelled from the Outbox, which emptied and sent the window to the Inbox, and the user has gone
                    // nowhere since: the message waits again, so the Outbox shows and the window goes back to it, on the
                    // row, as an undo of a step in Later brings Later back (§5.45, §5.53).
                    self.setView(.outbox)
                    self.list.selectConversations([restored], lead: restored)
                    self.present(selection: [restored])
                } else if self.list.selectedConversationID == row {
                    self.list.selectConversations([restored], lead: restored)
                }
                self.confirmUndo(of: SendLaterCopy.command)
            }
        }
    }

    /// Times missed while the app was closed (§5.23): asked once, on the window, Keep in Drafts (the default, as the safe
    /// choice is, §5.33) or Send Now. Nothing goes until the user says so; Keep in Drafts leaves each as the draft it was
    /// written in.
    private func askAboutMissedSends(_ sends: [PendingSendSummary]) {
        let time = sends.count == 1
            ? laterFormatter.dueTime(for: sends[0].sendAfter, reference: laterFormatter.reference(now: laterNow())) : nil
        let first = sends[0]
        let recipient = (first.to.first ?? first.cc.first ?? first.bcc.first).map(QuotedReply.authorName)
        let alert = AppAlert.missedSends(count: sends.count, subject: first.subject, recipient: recipient, time: time)
        presentMissedSends(alert) { [weak self] choice in
            guard let self else { return }
            let ids = sends.map(\.id)
            if choice == 1 {
                do {
                    try self.environment.engine.sendNow(ids)
                } catch {
                    Self.log.error("sending missed messages failed: \(String(describing: error), privacy: .public)")
                    NSSound.beep()
                }
            } else {
                let current = (try? self.environment.store.pendingSendSummaries()) ?? []
                for send in current where ids.contains(send.id) { self.sendLaterOutbox.cancel(send) }
                self.sendLaterOutbox.refresh()
            }
        }
    }

    /// A send nobody else answered for failed (a Send Later message when its time came, one whose panel or quick reply had
    /// gone, one the app quit while handing over): its draft is kept with the reason (the composer opens with the banner)
    /// and its row has left the Outbox, and the toast offers it once, as a quick reply's failure does (§5.18, §5.53). One
    /// that may have gone says so instead of “Couldn't send” (`SendFailureWording.notice`).
    private func sendFailed(_ draft: ComposeDraft, lastError: String?) {
        let engine = environment.engine
        let words = SendFailureWording.notice(subject: draft.subject, lastError: lastError)
        toasts.show(words, kind: .error, symbol: Quire.Icon.error, actionTitle: "Open draft") { [weak self] in
            guard let self else { return }
            ComposeWindowController.present(client: engine, accounts: self.accounts, draft: draft)
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

    /// The account a new message starts from: the one the window is scoped to, else the first in rail order.
    private var newMessageAccount: Account? {
        if case .account(let id) = scope, let account = accountsByID[id] { return account }
        return accounts.first
    }

    func composeNew() {
        guard let account = newMessageAccount else {
            onAddAccount?(nil)
            return
        }
        compose(.new, accountID: account.id)
    }

    /// A mail link another app opened (`mailto:`, spec §5.20): a new composer, filled from the link, from the account
    /// a new message starts from. With no account the window comes forward on the welcome screen and nothing opens.
    @discardableResult
    func openMailLink(_ link: MailtoLink) -> ComposeWindowController? {
        openNewMessage { ComposeWindowController.present(client: environment.engine, account: $0, accounts: accounts, link: link) }
    }

    /// A Services menu item used in another app, or in this one (spec §5.20 Services): a new composer from the account a
    /// new message starts from, with the selected text as its body or the files attached. With no account the window
    /// comes forward on the welcome screen and nothing opens, as for a mail link.
    @discardableResult
    func openServiceRequest(_ request: ServiceRequest) -> ComposeWindowController? {
        openNewMessage { ComposeWindowController.present(client: environment.engine, account: $0, accounts: accounts, service: request) }
    }

    /// What another app asked to write opens from the account a new message starts from; with none there is nobody to
    /// write as, so the welcome screen comes forward instead.
    private func openNewMessage(_ present: (Account) -> ComposeWindowController) -> ComposeWindowController? {
        beforeCompose?()
        guard let account = newMessageAccount else {
            showWindow(nil)
            NSApp.activate()
            return nil
        }
        return present(account)
    }

    private func compose(_ mode: ComposeMode, accountID: AccountID) {
        beforeCompose?()
        guard let account = accounts.first(where: { $0.id == accountID }) ?? accounts.first else { return }
        ComposeWindowController.present(client: environment.engine, account: account, accounts: accounts, mode: mode)
    }

    // MARK: Context menu (§5.35)

    /// Rows and messages share one menu acting on the selection: Reply · Reply All · Forward · — · Archive · Later ›
    /// · Star · Mark as Unread · Move to Inbox · — · Move to Trash · Mark as Spam, each with its symbol and shortcut. Items
    /// that do not apply stay visible, disabled, through the same validation as the Message menu, so the two
    /// never disagree. Unsubscribe follows, after a separator, only when the open conversation offers it (§5.14):
    /// most mail is not a list's, and a right-click on a row selects and opens it first, so the reader knows.
    func selectionContextMenu() -> NSMenu {
        let menu = NSMenu(title: "Conversation")
        let items: [NSMenuItem] = [
            MainMenu.item("Reply", #selector(replyToSelection(_:)), "r", [], symbol: Quire.Icon.reply, target: self),
            MainMenu.item("Reply All", #selector(replyAllToSelection(_:)), "a", [], symbol: Quire.Icon.replyAll, target: self),
            MainMenu.item("Forward", #selector(forwardSelection(_:)), "f", [], symbol: Quire.Icon.forward, target: self),
            .separator(),
            MainMenu.item("Archive", #selector(archiveSelection(_:)), "e", [], symbol: Quire.Icon.archive, target: self),
            laterSubmenuItem(),
            MainMenu.item("Star", #selector(toggleStarSelection(_:)), "s", [], symbol: Quire.Icon.star, target: self),
            MainMenu.item("Mark as Unread", #selector(markSelectionUnread(_:)), "u", [], symbol: Quire.Icon.markUnread, target: self),
            MainMenu.item("Mute", #selector(toggleMuteSelection(_:)), "m", [], symbol: Quire.Icon.mute, target: self),
            MainMenu.item("Move to Inbox", #selector(moveSelectionToInbox(_:)), "I", [.shift], symbol: Quire.Icon.moveToInbox, target: self),
            .separator(),
            MainMenu.item("Move to Trash", #selector(trashSelection(_:)), "#", [], symbol: Quire.Icon.trash, target: self),
            MainMenu.item("Mark as Spam", #selector(markSelectionSpam(_:)), "!", [], symbol: Quire.Icon.spam, target: self),
        ]
        items.forEach(menu.addItem)
        let unsubscribes = !isSeveralSelected && conversation.unsubscribeTarget != nil
        // Only where someone other than the user wrote, as Unsubscribe shows only where a list did.
        let setsRules = !isSeveralSelected && conversation.senderRuleTarget != nil
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

    // MARK: Menu actions (first responder)

    @objc func archiveSelection(_ sender: Any?) { archive() }
    /// Message › Later… (L): the Later menu at the selection, as the key shows it.
    @objc func laterSelection(_ sender: Any?) { showLaterMenu() }
    /// A preset of the Later menu, or of the context menu's Later submenu: its time is the item's.
    @objc func snoozeSelectionUntil(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let date = LaterMenu.date(of: item) else { return }
        snooze(selectedIDs, until: date)
    }
    /// Pick a Date…: the sheet, for the conversations selected now.
    @objc func pickSnoozeDate(_ sender: Any?) {
        // The sheet counts what would be snoozed (“these 3”), not a conversation with nothing to put away.
        let ids = snoozable(snoozableSelection).map(\.id)
        guard !ids.isEmpty else {
            if !snoozableSelection.isEmpty { NSSound.beep() }
            return
        }
        let picker = LaterDatePicker(count: ids.count, now: laterNow)
        presentLaterDatePicker(picker, window) { [weak self] date in
            guard let self, let date else { return }
            self.snooze(ids, until: date)
        }
    }
    @objc func trashSelection(_ sender: Any?) { mailAction(.trash) }
    @objc func markSelectionSpam(_ sender: Any?) { markSpam() }
    @objc func moveSelectionToInbox(_ sender: Any?) { moveSelectionToInbox() }
    @objc func toggleStarSelection(_ sender: Any?) {
        if let change = starChangeForSelection { mailAction(change) }
    }
    @objc func markSelectionUnread(_ sender: Any?) {
        if let change = readChangeForSelection { mailAction(change) }
    }
    /// Message › Mute (M), Unmute for a selection that is all muted.
    @objc func toggleMuteSelection(_ sender: Any?) { toggleMute() }
    @objc func alwaysArchiveSender(_ sender: Any?) { setSenderRuleFromMenu(.archive) }
    @objc func blockSender(_ sender: Any?) { setSenderRuleFromMenu(.trash) }
    @objc func replyToSelection(_ sender: Any?) { _ = composeReply(all: false) }
    @objc func replyAllToSelection(_ sender: Any?) { _ = composeReply(all: true) }
    @objc func forwardSelection(_ sender: Any?) { _ = composeForward() }
    /// Message › Undo (Z): the latest toast's action, never a send (§6.1).
    @objc func undoMailAction(_ sender: Any?) { performUndo(zTarget) }
    @objc func focusSearchField(_ sender: Any?) { listPane.focusSearch() }
    /// Edit › Search Gmail for More (§5.10; ↩ in the search field does the same, §5.6): words still waiting out the field's debounce
    /// go to the list first, and the search runs once their local results are all listed.
    @objc func searchServer(_ sender: Any?) {
        listPane.sendPendingSearch()
        list.requestServerSearch()
    }

    /// The search belongs to the search field, the list and the row, so the item is disabled while any other place to
    /// type, or the reader, has focus.
    private var serverSearchKeyApplies: Bool {
        guard let responder = window?.firstResponder else { return true }
        if listPane.isSearchFocused { return true }
        if KeyboardRouter.isTextInput(responder) { return false }
        guard let view = responder as? NSView else { return true }
        return !view.isDescendant(of: conversationPane.view)
    }

    // The reader's menu commands (§5.35) answer from anywhere in the main window, not only while focus is in
    // the reader, whose controller is in the responder chain only then. Validation is the reader's.
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

    /// ⌘+ and ⌘−: the reader's own Text size, one size up or down (§4.15). The reader follows the setting's change;
    /// a key past Larger or Small finds its item disabled.
    @objc func makeReaderTextBigger(_ sender: Any?) { settings.stepReaderTextSize(larger: true) }
    @objc func makeReaderTextSmaller(_ sender: Any?) { settings.stepReaderTextSize(larger: false) }

    private static let readerCommands: Set<Selector> = [
        #selector(nextMessage(_:)), #selector(previousMessage(_:)), #selector(toggleQuotedText(_:)), #selector(loadImages(_:)),
        #selector(toggleOriginalColors(_:)), #selector(saveAttachments(_:)), #selector(downloadAttachments(_:)),
        #selector(printConversation(_:)), #selector(findInConversation(_:)), #selector(findNextMatch(_:)),
        #selector(findPreviousMatch(_:)),
    ]

    /// The Message menu's and the context menu's mail items: what the keys `refusesInOutbox` names do from a menu.
    private static let mailCommands: Set<Selector> = [
        #selector(archiveSelection(_:)), #selector(laterSelection(_:)), #selector(snoozeSelectionUntil(_:)), #selector(pickSnoozeDate(_:)),
        #selector(toggleStarSelection(_:)), #selector(trashSelection(_:)), #selector(markSelectionSpam(_:)),
        #selector(moveSelectionToInbox(_:)), #selector(markSelectionUnread(_:)), #selector(replyToSelection(_:)),
        #selector(replyAllToSelection(_:)), #selector(forwardSelection(_:)), #selector(toggleMuteSelection(_:)),
        #selector(unsubscribeFromConversation(_:)), #selector(alwaysArchiveSender(_:)), #selector(blockSender(_:)),
        #selector(blockTimeForSelection(_:)),
    ]

    /// The toast after a save to Downloads (spec §5.17, §5.30): what was saved, with Show in Finder, which selects the
    /// copies. It is bound to no undo group, so Z still reaches the last undoable action in its grace (§6.1). A save
    /// that wrote nothing says so; a file that could not be fetched is told by its chip, not here.
    private func showSaved(_ outcome: AttachmentSaveOutcome) {
        // The app's one toast (`MailUndoCenter`), in the window whose reader saved: a reader window's own, or this one's.
        let toasts = self.toasts
        let host = stepToastHost
        let action = AttachmentSaveOutcome.showInFinder
        let toast = outcome.toast { words in
            toasts.fits(words, symbol: Quire.Icon.download, actionTitle: action, keycap: nil, in: host)
        }
        switch toast {
        case .saved(let words)?:
            let files = outcome.saved
            toasts.show(words, kind: .notice, symbol: Quire.Icon.download, actionTitle: action, in: host) {
                NSWorkspace.shared.activateFileViewerSelecting(files)
            }
        case .failed(let words)?:
            toasts.show(words, kind: .error, symbol: Quire.Icon.error, in: host)
        case nil:
            break
        }
    }

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
            // The reader under the week is hidden: what acts on its page (find, next message, quoted text…) waits for it.
            return !showingWelcome && desk.placement != .week && conversation.validateMenuItem(menuItem)
        }
        // A message on its way in the Outbox is not mail in the store: the mail items are disabled there (§5.53).
        if listView == .outbox, let action = menuItem.action, Self.mailCommands.contains(action) { return false }
        switch menuItem.action {
        case #selector(archiveSelection(_:)):
            // Plain-letter and ⌘⌫ equivalents must not fire while the user is typing.
            return !showingWelcome && !typing && list.selectedConversationID != nil
        case #selector(laterSelection(_:)), #selector(snoozeSelectionUntil(_:)), #selector(pickSnoozeDate(_:)):
            // Nothing is snoozed from the Trash or Drafts (§5.45).
            return !showingWelcome && !typing && canSnoozeSelection
        case #selector(toggleStarSelection(_:)):
            if case .setStarred(let star)? = starChangeForSelection { menuItem.title = star ? "Star" : "Unstar" }
            return !showingWelcome && !typing && list.selectedConversationID != nil
        case #selector(trashSelection(_:)):
            // Already in Trash (§5.12): Message › Move to Trash is disabled there.
            return !showingWelcome && !typing && list.selectedConversationID != nil && listView != .trash
        case #selector(markSelectionSpam(_:)):
            return !showingWelcome && !typing && list.selectedConversationID != nil && marksSpamInView
        case #selector(moveSelectionToInbox(_:)):
            // Everything in the Inbox view is in the Inbox already.
            return !showingWelcome && !typing && list.selectedConversationID != nil && listView != .inbox
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
            let view = MailboxView.allCases.indices.contains(menuItem.tag) ? MailboxView.allCases[menuItem.tag] : nil
            menuItem.state = view == mailboxView ? .on : .off
            // Later and the Outbox only while their rail tiles show, as G L and G O (§5.2).
            if view == .later { return !showingWelcome && showsLater }
            if view == .outbox { return !showingWelcome && showsOutbox }
            return !showingWelcome
        case #selector(toggleAccountStrip(_:)):
            menuItem.title = stripItem.isCollapsed ? "Show Account Rail" : "Hide Account Rail"
            return !showingWelcome
        case #selector(focusSearchField(_:)):
            return !showingWelcome
        case #selector(makeReaderTextBigger(_:)):
            return !showingWelcome && settings.readerSize.larger != nil
        case #selector(makeReaderTextSmaller(_:)):
            return !showingWelcome && settings.readerSize.smaller != nil
        case #selector(searchServer(_:)):
            menuItem.title = ServerSearchRow.menuTitle(for: ServerSearchRow.target(scope: scope.accountIDs, accounts: accounts))
            let words = !listPane.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return !showingWelcome && words && serverSearchKeyApplies && (listPane.hasPendingSearch || list.canRequestServerSearch)
        case #selector(unsubscribeFromConversation(_:)):
            // One conversation open, whose messages offer it; the reader knows without a store read.
            return !showingWelcome && !isSeveralSelected && conversation.unsubscribeTarget != nil
        case #selector(toggleMuteSelection(_:)):
            menuItem.title = MailActionCopy.muteCommand(muting: mutesSelection)
            return !showingWelcome && !typing && !muteSelection.isEmpty
        case #selector(alwaysArchiveSender(_:)), #selector(blockSender(_:)):
            // One conversation open with mail from someone else; the rule its sender has is checked and has nothing to do.
            let action: SenderRule.Action = menuItem.action == #selector(blockSender(_:)) ? .trash : .archive
            guard !showingWelcome, !isSeveralSelected, let target = conversation.senderRuleTarget else {
                menuItem.state = .off
                return false
            }
            let current = senderRule(for: target)
            menuItem.state = current == action ? .on : .off
            return current != action
        case #selector(openSelectionInNewWindow(_:)):
            // One conversation, outside Drafts and the Outbox (§5.49, §5.53).
            return conversationToOpenInWindow != nil
        case #selector(toggleDayColumn(_:)), #selector(toggleWeek(_:)), #selector(previousCalendarDay(_:)),
             #selector(nextCalendarDay(_:)), #selector(calendarToday(_:)), #selector(blockTimeForSelection(_:)):
            return !showingWelcome && validateCalendarItem(menuItem)
        default:
            return true
        }
    }

    // MARK: NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        if !showingWelcome, window?.firstResponder === window { focusList() }
    }

    /// Minimised, hidden, covered or on another Space: the sync line's countdown stops, and starts again, up to date,
    /// when the window is seen.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        refreshSyncLine()
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
    /// focus-action,hover-demo,hover-masthead,many-accounts,ic,graphite,snoozed,later,back,later-menu,later-sheet,
    /// server-offer,server-searching,server-found,server-nothing,server-failed,server-empty` (debug builds; `several` and
    /// `find`, the find bar over the first conversation, are applied where the first selection is made):
    /// puts the window in the named states before `--snapshot` captures it, so every state of the chrome can be
    /// compared with the specimen without a screen recording.
    fileprivate func applyDebugSnapshotStates() {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot-state=") }) else { return }
        let states = Set(argument.dropFirst("--snapshot-state=".count).split(separator: ",").map(String.init))
        let second = accounts.dropFirst().first
        applyDebugLaterStates(states)
        applyDebugMuteStates(states)
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
            toasts.show(MailActionCopy.toast(for: .archive, count: 3), kind: .undoable, symbol: Quire.Icon.archive,
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
        applyDebugServerSearchState(states)
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
        if states.contains("later-menu") || states.contains("later-sheet") {
            // The menu and the sheet open over this window once it is written; it must be on screen and in front.
            window?.orderFrontRegardless()
            NSApp.activate()
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

    /// `back`: an older Inbox conversation came back from Later just now, so it sorts under Today with its Back tag.
    /// `snoozed`: three Inbox conversations are snoozed (Later Today or This Evening, Tomorrow, Next Week), so the
    /// Later tile shows. `later`: the same, in the Later view. Written to the demo store through its own calls, as the
    /// window and the snooze runner write them, before the first selection.
    fileprivate func applyDebugLaterStates(_ states: Set<String>) {
        let wantsSnoozes = states.contains("snoozed") || states.contains("later") || states.contains("later-menu")
            || states.contains("later-sheet")
        guard states.contains("back") || wantsSnoozes else { return }
        let store = environment.store
        let now = Date()
        func archive(_ id: ConversationID) -> [SSCore.Operation] {
            let targets = ((try? store.messages(in: id)) ?? []).filter(\.isInInbox).map(\.id)
            return targets.isEmpty ? [] : [SSCore.Operation(accountID: id.accountID, change: .archive, targets: targets, createdAt: now)]
        }
        if states.contains("back") {
            let inbox = list.conversations
            if inbox.count > 6 {
                let id = inbox[6].id
                try? store.setSnoozes([Snooze.Change(conversationID: id, until: now.addingTimeInterval(-60))], enqueueing: archive(id),
                                      at: now.addingTimeInterval(-3_600))
                _ = try? store.returnDueSnoozes(at: now, limit: 1) { conversation, messages in
                    var operations = [SSCore.Operation(accountID: conversation.accountID, change: .moveToInbox, targets: messages.map(\.id),
                                                       createdAt: now)]
                    if let latest = messages.last {
                        operations.append(SSCore.Operation(accountID: conversation.accountID, change: .setRead(false), targets: [latest.id],
                                                           createdAt: now))
                    }
                    return operations
                }
            }
        }
        if wantsSnoozes {
            let inbox = list.conversations.filter { $0.returnedAt == nil }
            let times = LaterPreset.offered(at: now, calendar: .autoupdatingCurrent).map(\.date)
            for (index, row) in inbox.dropFirst(1).prefix(3).enumerated() {
                let due = times.indices.contains(index + 1) ? times[index + 1] : now.addingTimeInterval(Double(index + 1) * 86_400)
                try? store.setSnoozes([Snooze.Change(conversationID: row.id, until: due)], enqueueing: archive(row.id), at: now)
            }
        }
        // The observation would bring these on the next turn; the first selection is made now.
        if let current = try? store.snoozes() { snoozesChanged(current) }
        if states.contains("later") { setView(.later) }
    }

    /// `muted`: three demo conversations muted as M mutes them (archived with it), and the window on All Mail, where their
    /// rows show the muted glyph.
    fileprivate func applyDebugMuteStates(_ states: Set<String>) {
        guard states.contains("muted") else { return }
        let store = environment.store
        for row in list.conversations.dropFirst(1).prefix(3) {
            let targets = ((try? store.messages(in: row.id)) ?? []).filter(\.isInInbox).map(\.id)
            let archive = targets.isEmpty ? [] : [SSCore.Operation(accountID: row.id.accountID, change: .archive, targets: targets)]
            try? store.setMuted(true, conversations: [row.id], enqueueing: archive)
        }
        setView(.all)
    }

    /// `later-menu` and `later-sheet`, once `path`'s window snapshot is written: opens the Later menu at the first row,
    /// or Pick a Date…, on screen, and writes the window's frame in screen points from the top-left (`x y w h`) to
    /// `path` + `.rect`, so `screencapture -R` can take the window with the system's menu or sheet over it.
    func openDebugLaterSurfaces(besides path: String) {
        guard let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--snapshot-state=") }) else { return }
        let states = Set(argument.dropFirst("--snapshot-state=".count).split(separator: ",").map(String.init))
        guard states.contains("later-menu") || states.contains("later-sheet"), let window else { return }
        window.orderFrontRegardless()
        NSApp.activate()
        let screenHeight = NSScreen.screens.first?.frame.height ?? window.frame.maxY
        let frame = window.frame
        let rect = "\(Int(frame.minX)) \(Int(screenHeight - frame.maxY)) \(Int(frame.width)) \(Int(frame.height))\n"
        try? rect.write(toFile: path + ".rect", atomically: true, encoding: .utf8)
        if states.contains("later-sheet") {
            pickSnoozeDate(nil)
        } else {
            window.makeFirstResponder(list.tableView)
            showLaterMenu()
        }
    }

    /// `server-offer`, `server-searching`, `server-found`, `server-nothing`, `server-failed`, `server-empty`: a search
    /// whose list ends with the server row in that state (§5.10), or the empty search's offer. `server-found` really
    /// searches the demo's server, whose archive the download never lists; the others are shown without asking it.
    private func applyDebugServerSearchState(_ states: Set<String>) {
        guard let state = states.first(where: { $0.hasPrefix("server-") }) else { return }
        let words = state == "server-empty" ? "porto" : "lisbon"
        listPane.header.search.query = words
        listPane.header.search.onQueryChange?(words)
        listPane.sendPendingSearch()
        // The search's rows arrive off the main thread; the state is set once they are in.
        func whenListed(_ tries: Int = 0, _ then: @escaping () -> Void) {
            if (list.hasReceivedFirstPage && list.query.searchText == words) || tries > 50 { return then() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { MainActor.assumeIsolated { whenListed(tries + 1, then) } }
        }
        whenListed { [weak self] in
            guard let self else { return }
            let listed = Set(self.list.conversations.map(\.id))
            let scope = self.scope.accountIDs
            switch state {
            case "server-searching":
                self.list.serverSearch.force(.searching, words: words, scope: scope, before: listed)
            case "server-nothing":
                self.list.serverSearch.force(.finished, words: words, scope: scope, before: listed)
            case "server-failed":
                self.list.serverSearch.force(.failed, words: words, scope: scope, before: listed,
                                             failedAccounts: self.accounts.suffix(1).map(\.id))
            case "server-found":
                self.list.requestServerSearch()
            default:
                break
            }
            // The row is the list's last: a capture shows it with the results above it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                MainActor.assumeIsolated {
                    let rows = self.list.tableView.numberOfRows
                    if rows > 0 { self.list.tableView.scrollRowToVisible(rows - 1) }
                }
            }
        }
    }
}
#endif
