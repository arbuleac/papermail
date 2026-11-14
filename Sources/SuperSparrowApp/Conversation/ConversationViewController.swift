import AppKit
import QuickLookUI
import SSCore
import SSDesign
import WebKit
import os

/// The conversation reader: the 92 pt header, the pooled web view on the desk, and the quick reply drawn
/// over it (spec §5.12–5.19).
///
/// Reads only from `client.store`; every command goes through `onAction` or `MailClient`. Opening a
/// conversation is a view swap when it was pre-rendered, otherwise one `ss.render` into a free slot.
@MainActor
final class ConversationViewController: NSViewController, NSMenuItemValidation {
    /// What the reader shows: the header, the desk and the quick reply all follow it (spec §5.12, §5.18, §5.19).
    enum Selection: Equatable {
        case none
        case one(ConversationID)
        case several([ConversationID])
    }

    let client: MailClient
    /// Used for "me" in recipient lists, reply recipients, the kicker and the quick reply's face.
    var accountsByID: [AccountID: Account] {
        didSet { if oldValue != accountsByID { refreshChrome() } }
    }
    var onAction: ((ConversationAction) -> Void)?
    /// The conversation context menu for a right-click on a message's chrome (spec §5.35), from the window.
    var messageMenu: (() -> NSMenu?)?
    /// Drafts kept on this Mac, which the Drafts view lists beside the store's: shown read-only like any draft,
    /// but read from here and never fetched, observed or acted on through the engine.
    var localDrafts: LocalDrafts?
    /// Whether a composer window holds this draft; its sheet then reads “Open in a composer window” instead of
    /// the body being changed there (spec §5.19).
    var isDraftInComposer: (MessageID) -> Bool = { _ in false }
    /// The mailbox the selection comes from; it decides the header's actions and whether the quick reply shows.
    var mailboxView: MailboxView = .inbox {
        didSet { if oldValue != mailboxView { refreshChrome() } }
    }

    private(set) var selection: Selection = .none
    private(set) var currentConversationID: ConversationID?
    private(set) var currentMessages: [MessageMetadata] = [] {
        didSet { onMessagesChange?() }
    }
    /// The conversation's messages were read again (a show, a store refresh): a reader window names itself after them.
    var onMessagesChange: (() -> Void)?
    /// The target message (spec §5.14): R, A, F and Space act on it. The last expanded message on open, then
    /// the one last clicked or reached with N, P or Tab. The quick reply answers it, so its placeholder and
    /// Reply all follow it.
    private(set) var selectedMessageID: MessageID? {
        didSet { if oldValue != selectedMessageID, selectedMessageID != nil { targetDidChange() } }
    }

    private static let showDebounce: TimeInterval = 0.03
    /// Pre-rendering neighbours costs a store read, a payload build and a render per slot; while `j` is
    /// held each one would be evicted unseen by the next repeat, so it waits for the selection to rest.
    private static let prerenderDelay: TimeInterval = 0.15
    private static let markReadDelay: TimeInterval = 0.5
    /// A conversation counts as seen, and its failed-operation mark is acknowledged, after 150 ms (spec §8.5).
    private static let acknowledgeDelay: TimeInterval = 0.15
    /// Seconds a quick reply is held for undo. The shell sets it from the "Undo send" preference.
    static var undoWindow: TimeInterval = 5
    /// The "Load remote images" preference, set by `AppSettings`; a change posts `remoteImagesPolicyChanged`.
    static var loadRemoteImages = false
    static let remoteImagesPolicyChanged = Notification.Name("SSRemoteImagesPolicyChanged")

    /// Internal, not private, so the reader's tests can ask the pooled shells what they were told.
    let pool: WebViewPool
    /// File › Print… (spec §5.48): a web view of its own for each print, none between prints.
    private(set) lazy var printer = ConversationPrinter(client: client)
    private let preview: AttachmentPreviewController
    private let builder = RenderPayloadBuilder()
    /// Internal so tests can read the headline as set.
    let header = ReaderHeaderView()
    /// Find in conversation's bar and its shell traffic (spec §5.50).
    let find: ReaderFind
    private let webContainer = NSView()
    private let quickReply = QuickReplyView()
    private let emptyState = QuireEmptyStateView(sentence: "No conversation selected")
    private lazy var moreMenu = MessageMoreMenu { [weak self] command in self?.performMore(command) }
    /// The chip a context menu was opened for: its commands act on it.
    private var menuAttachment: (message: MessageID, attachment: String)?
    private lazy var attachmentMenu = AttachmentMenu { [weak self] command in self?.performAttachment(command) }

    private var observation: StoreObservation?
    private var statusObservation: StoreObservation?
    private var showTimer: Timer?
    private var prerenderTimer: Timer?
    private var pendingShow: (id: ConversationID, messages: [MessageMetadata])?
    private var lastShowAt: TimeInterval = -.infinity
    private var markReadTimer: Timer?
    private var acknowledgeTimer: Timer?
    private var bodyFetches: Set<MessageID> = []
    /// What stands in for a body the store does not have yet (spec §5.14): loading, offline or failed.
    private var bodyStates: [MessageID: RenderPayload.BodyState] = [:]
    private var offlineAccounts: Set<AccountID> = []
    private var focusedAttachment: (message: MessageID, attachment: String)?
    /// What each chip shows of its fetch, and each message's count line of its Download all.
    private var downloads = AttachmentDownloadBoard()
    /// Saves to Downloads under way: one chip's file, or every file of a message (`Chip.allAttachments`), which holds
    /// each of its files too. A second press while one runs does nothing, so a file is never saved twice.
    private var savesUnderWay: Set<AttachmentDownloadBoard.Chip> = []
    /// When each save last ended, in system uptime. A file already on this Mac is saved within one turn, before a
    /// double-click's second click arrives; a press on the same control that soon is still that double-click.
    private var savesEnded: [AttachmentDownloadBoard.Chip: TimeInterval] = [:]
    /// Where Download, Download all and Save to Downloads save (spec §5.17). Tests point it at a folder of their own.
    var downloadsFolder: URL? = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    /// Messages the shell shows in Original colors this session, for View › Original Colors' checkmark.
    private var originalColorsShown: Set<MessageID> = []
    /// The quick-reply text parked under each conversation, shared with the mailbox's other readers (§5.49).
    private let draftShelf: QuickReplyDraftShelf
    private var drafts: QuickReplyDrafts {
        get { draftShelf.drafts }
        set { draftShelf.drafts = newValue }
    }
    private var quickSend: QuickSend?
    private var quickSendTimer: Timer?
    /// Quick replies whose undo window has ended, watched until they leave: a failure then becomes the error
    /// toast of §5.18 (“Couldn't send your reply · Open draft”). Keyed by send id.
    private var watchedSends: [String: ComposeDraft] = [:]
    /// Replies on their way out (scheduled or sending, not forwards): the open conversation shows the ones that
    /// answer it as pending sheets (spec §5.14). Read on events and as the outbox changes, never per selection.
    private var outbox: [PendingSendSummary] = []
    /// The store's word of each change to the outbox (`observePendingSends`, read off the main thread), followed only
    /// while a send is watched or a reply is on its way, and dropped as soon as neither is. No reader polls the outbox:
    /// a once-a-second tick in each reader, a reader window's too, ran for as long as a reply waited (offline, say).
    private var outboxObservation: StoreObservation?
    private var notificationTokens: [NSObjectProtocol] = []
    private var keyMonitor: Any?
    private var motionFinisher: ShellMotionFinisher?
    private var showSignpost: OSSignpostIntervalState?
    /// Called each time a show's render has landed and its web view is on screen.
    private var showLandedWaiters: [(WKWebView?) -> Void] = []

    /// A quick reply inside its undo window.
    private struct QuickSend {
        let sendID: String
        let text: String
        let conversation: ConversationID
        let subject: String
        let startedAt: Date
        let endsAt: Date
        /// The reply as a composer would hold it, for an undo-send panel the countdown may move to (§5.18).
        let draft: ComposeDraft
        /// What Send and Archive archived as the reply was queued: Undo brings it back with the reply (§5.23).
        let archive: SendArchive?
    }

    /// Called whenever a quick reply's undo window opens or closes, so the main window can re-rank ⌘Z (§6.1).
    var onQuickSendChange: (() -> Void)?

    /// Called once a quick reply sent with Send and Archive has archived its conversation, its countdown running: a
    /// reader window closes then, as after E (§5.49).
    var onQuickSendArchived: (() -> Void)?

    /// The quick reply's send while ⌘Z can still cancel it.
    var liveQuickSend: UndoPrecedence.LiveSend? {
        quickSend.map { UndoPrecedence.LiveSend(id: $0.sendID, startedAt: $0.startedAt) }
    }

    /// Edit › Undo's title for the quick reply's live send: “Undo Send and Archive” while it holds an archive to put back.
    var liveQuickSendUndoTitle: String {
        SendAction.undoMenuTitle(archived: quickSend?.archive?.isArchived ?? false)
    }

    /// Where the reader's own Text size comes from (spec §4.15): the app's settings, or a test's throwaway ones.
    private let appSettings: AppSettings

    /// `poolSize` 1 is a reader window's (§5.49): it shows one conversation and pre-renders nothing. A pool of its own
    /// rather than a slot of the main window's, which that reader hands to whatever neighbour it pre-renders next.
    /// `drafts` is the mailbox's quick-reply text, which every reader of it shares; a reader alone keeps its own.
    /// `findSession` holds Find in conversation's words for the session, shared with the mailbox's other readers.
    init(client: MailClient, poolSize: Int = 3, drafts: QuickReplyDraftShelf? = nil, settings: AppSettings? = nil,
         findSession: FindSession? = nil) {
        appSettings = settings ?? AppSettings.shared
        find = ReaderFind(session: findSession ?? FindSession())
        self.client = client
        self.draftShelf = drafts ?? QuickReplyDraftShelf()
        self.pool = WebViewPool(client: client, size: poolSize)
        self.preview = AttachmentPreviewController(client: client)
        var accounts: [AccountID: Account] = [:]
        for account in (try? client.accounts()) ?? [] { accounts[account.id] = account }
        self.accountsByID = accounts
        broadcastTextSize = appSettings.readerSize
        super.init(nibName: nil, bundle: nil)
        header.textSize = appSettings.readerSize
        pool.onMessage = { [weak self] slot, message in self?.handle(message, from: slot) }
        pool.onViewRecreated = { [weak self] slot in self?.slotWasRecreated(slot) }
        let center = NotificationCenter.default
        // Block observers stay registered until removed, so their tokens are kept for deinit.
        notificationTokens.append(center.addObserver(forName: Self.remoteImagesPolicyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.renderAgain() }
        })
        notificationTokens.append(center.addObserver(forName: AppSettings.displayPreferencesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayPreferencesDidChange() }
        })
        // The Font setting and Text size live in the Quire environment: every shell, the pre-rendered ones too, is
        // told in place. The reader's own size (⌘+, ⌘−) is the settings'.
        notificationTokens.append(center.addObserver(forName: QuireEnvironment.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readerTypeMayHaveChanged() }
        })
        notificationTokens.append(center.addObserver(forName: AppSettings.readerTextSizeChanged, object: appSettings, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.readerTypeMayHaveChanged() }
        })
        // A drop-down here or in any composer changes what the quick reply's Send does (§5.23).
        notificationTokens.append(center.addObserver(forName: SendActionPreference.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quickReply.sendAction = SendActionPreference.current }
        })
        statusObservation = client.observeStatus { [weak self] statuses in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.statusesChanged(statuses) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.statusesChanged(statuses) } }
            }
        }
    }

    /// Everything rendered under an old preference is stale: pre-rendered slots are dropped and the
    /// conversation on screen is rendered again, so turning images off stops them at once.
    private func renderAgain() {
        pool.clearAll(except: pool.current)
        guard let id = currentConversationID, let current = pool.current, current.renderedID == id else { return }
        let prepared = prepare(currentMessages)
        pool.render(prepared.payload, inputs: prepared.inputs, id: id, into: current)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        observation?.cancel()
        statusObservation?.cancel()
        showTimer?.invalidate()
        prerenderTimer?.invalidate()
        markReadTimer?.invalidate()
        acknowledgeTimer?.invalidate()
        quickSendTimer?.invalidate()
        outboxObservation?.cancel()
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: View

    override func loadView() {
        let root = ReaderRootView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false
        root.onEndLiveResize = { [weak self] in self?.liveResizeEnded() }

        webContainer.translatesAutoresizingMaskIntoConstraints = false
        emptyState.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(webContainer)
        root.addSubview(emptyState)
        root.addSubview(quickReply)
        root.addSubview(header)

        // The web view always fills the reader below the header; the quick reply is drawn over it and the
        // shell is told its height as a bottom inset, so the web view's frame never changes (spec §5.18).
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyState.topAnchor.constraint(equalTo: header.bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Quire.Layout.Reader.narrowColumnMargin),
            emptyState.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Quire.Layout.Reader.narrowColumnMargin),
            emptyState.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            quickReply.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            quickReply.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            quickReply.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: Quire.Layout.Window.readerMinWidth),
        ])

        header.onAction = { [weak self] action in self?.headerAction(action) }
        quickReply.onSend = { [weak self] text, mode, action in self?.sendQuickReply(text, mode: mode, action: action) }
        quickReply.onChooseSendAction = { SendActionPreference.choose($0) }
        quickReply.onSendLater = { [weak self] text, mode, date in self?.sendQuickReplyLater(text, mode: mode, at: date) }
        quickReply.sendAction = SendActionPreference.current
        quickReply.onEscape = { [weak self] in self?.quickReplyEscape() }
        quickReply.onHeightChange = { [weak self] _ in self?.applyBottomInset() }
        quickReply.onOpenInComposer = { [weak self] text, mode in self?.openQuickReplyInComposer(text: text, mode: mode, attach: false) }
        quickReply.onAttach = { [weak self] text, mode in self?.openQuickReplyInComposer(text: text, mode: mode, attach: true) }
        quickReply.onDisabledClick = { [weak self] in self?.bringReplyComposerForward() }
        quickReply.onUndo = { [weak self] in self?.undoQuickSend() }
        quickReply.onShowDraft = { [weak self] in
            guard let self, let conversation = self.quickSendShown else { return }
            self.onAction?(.reveal(conversation))
        }
        // The bar floats over the page under the header, so the web view's frame never changes (spec §5.50).
        find.host = root
        find.header = header
        find.currentSlot = { [weak self] in self?.searchableSlot }
        find.selectedConversation = { [weak self] in
            guard case .one(let id)? = self?.selection else { return nil }
            return id
        }
        find.focusReader = { [weak self] in self?.focusWebView() }

        view = root
        refreshChrome()
        // Replies a previous session left in the outbox (offline sends) show from the first render.
        outboxTick()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installKeyMonitor()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        removeKeyMonitor()
    }

    // MARK: Showing

    /// Selection moved. The subject updates at once; rendering is coalesced while calls arrive faster
    /// than 30 ms (key repeat) so a held `j` never queues renders it will not show.
    func show(_ id: ConversationID?) {
        guard let id else {
            cancelPendingShow()
            showNothing(.none)
            return
        }
        // One metadata read serves the header now and the show that follows; the observation set up
        // by the show brings anything that changes in between.
        let messages = visibleMessages(for: id)
        selection = .one(id)
        currentMessages = messages
        if currentConversationID != id { selectedMessageID = nil }
        refreshChrome(for: id, messages: messages)
        let now = ProcessInfo.processInfo.systemUptime
        let tooSoon = now - lastShowAt < Self.showDebounce
        lastShowAt = now
        pendingShow = (id, messages)
        if tooSoon || showTimer != nil {
            showTimer?.invalidate()
            showTimer = Timer.scheduledTimer(withTimeInterval: Self.showDebounce, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushPendingShow() }
            }
        } else {
            flushPendingShow()
        }
    }

    /// Two or more conversations are selected (spec §5.19): the header offers what applies to all of them and
    /// the desk says what the keys do. Nothing is rendered.
    func showSelection(_ ids: [ConversationID]) {
        guard ids.count > 1 else {
            show(ids.first)
            return
        }
        cancelPendingShow()
        showNothing(.several(ids))
    }

    /// Renders `ids` into free slots once the selection has rested for `prerenderDelay`; a newer call
    /// replaces a pending one, so a held key never pays for neighbours it moves past.
    func prerender(_ ids: [ConversationID]) {
        prerenderTimer?.invalidate()
        prerenderTimer = Timer.scheduledTimer(withTimeInterval: Self.prerenderDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.prerenderTimer = nil
                self.prerenderNow(ids)
            }
        }
    }

    /// Renders `ids` into free slots in order, skipping ones already held, until the pool runs out.
    private func prerenderNow(_ ids: [ConversationID]) {
        var reserved: [PooledConversationView] = []
        // The slot rendering the current conversation may still be in flight and not yet on screen;
        // evicting it would leave the show waiting on a render that lands another conversation. While a
        // show is debounced (key repeat) the conversation it will put up is the one to protect too, or
        // each repeat evicts the slot already holding it and the stop lands on a full render.
        let protected = [currentConversationID, pendingShow?.id].compactMap { $0 }
        for id in protected {
            if let held = pool.slot(rendering: id) {
                pool.touch(held)
                reserved.append(held)
            }
        }
        let wanted = ids.filter { !protected.contains($0) }
        for id in wanted {
            if let held = pool.slot(rendering: id) {
                pool.touch(held)
                reserved.append(held)
            }
        }
        for id in wanted where pool.slot(rendering: id) == nil {
            guard let slot = pool.acquire(excluding: reserved) else { break }
            reserved.append(slot)
            let messages = visibleMessages(for: id)
            let prepared = prepare(messages)
            let state = ConversationSignposts.begin(ConversationSignposts.prerender)
            pool.render(prepared.payload, inputs: prepared.inputs, id: id, into: slot) { _ in
                ConversationSignposts.end(ConversationSignposts.prerender, state)
            }
            requestMissingBodies(messages, rendered: prepared.inputs)
        }
    }

    private func cancelPendingShow() {
        showTimer?.invalidate()
        showTimer = nil
        pendingShow = nil
        prerenderTimer?.invalidate()
        prerenderTimer = nil
    }

    private func flushPendingShow() {
        showTimer = nil
        guard let pending = pendingShow else { return }
        pendingShow = nil
        performShow(pending.id, messages: pending.messages)
    }

    private func performShow(_ id: ConversationID, messages: [MessageMetadata]) {
        if let previous = showSignpost {
            ConversationSignposts.end(ConversationSignposts.show, previous)
        }
        showSignpost = ConversationSignposts.begin(ConversationSignposts.show)
        if currentConversationID != id {
            // The find bar belongs to the conversation it searched (spec §5.50); one opened for this conversation while
            // its show waited stays.
            if find.conversation != id { find.close(returningFocus: false) }
            // The box shows one thread at a time: its text is parked under the thread it was written for
            // and the new thread's draft, if any, takes its place.
            let draft = drafts.move(boxText: quickReply.text, from: currentConversationID, to: id)
            if draft.isEmpty {
                quickReply.clear()
            } else {
                quickReply.restoreDraft(draft)
            }
            focusedAttachment = nil
        }
        currentConversationID = id
        preview.closePanel()
        // The quick reply's strip stays up: its own timer ends the undo window, not the selection.

        applyMessages(messages, for: id)
        present(id, messages: messages)
        observe(id)
        scheduleMarkRead(for: id)
        scheduleAcknowledge(for: id)
        requestMissingBodies(messages, rendered: pool.slot(rendering: id)?.renderedInputs)
    }

    /// Puts `id` on screen: a swap when a slot already holds it, a swap once an in-flight render lands,
    /// otherwise a render into a free slot. Only a missing or stale slot pays for a payload.
    private func present(_ id: ConversationID, messages: [MessageMetadata]) {
        if let held = pool.slot(rendering: id) {
            guard held.renderInFlight else {
                swap(in: held)
                refreshIfStale(held, messages: messages, id: id)
                return
            }
            // Whoever started the render (a show, a pre-render or a refresh), the swap waits for it.
            pool.whenRenderLands(in: held) { [weak self] rendered in
                guard let self, self.currentConversationID == id else { return }
                if rendered, held.renderedID == id {
                    self.swap(in: held)
                    self.refreshIfStale(held, messages: self.currentMessages, id: id)
                } else {
                    // Cleared, evicted or recreated before it landed: start over.
                    self.present(id, messages: self.currentMessages)
                }
            }
        } else if let slot = pool.acquire() {
            if slot.renderedID == nil {
                // A blank shell is better than another conversation's cards while the render lands.
                swap(in: slot)
            }
            let prepared = prepare(messages)
            pool.render(prepared.payload, inputs: prepared.inputs, id: id, into: slot) { [weak self] rendered in
                guard let self, rendered, self.currentConversationID == id else { return }
                self.swap(in: slot)
            }
        }
    }

    /// Nothing, or several conversations: no conversation is rendered and the quick reply hides.
    private func showNothing(_ selection: Selection) {
        if let id = currentConversationID {
            drafts.leave(quickReply.text, under: id)
        }
        self.selection = selection
        currentConversationID = nil
        currentMessages = []
        selectedMessageID = nil
        focusedAttachment = nil
        observation?.cancel()
        observation = nil
        markReadTimer?.invalidate()
        markReadTimer = nil
        acknowledgeTimer?.invalidate()
        acknowledgeTimer = nil
        preview.closePanel()
        quickReply.clear()
        if let current = pool.current {
            current.webView.removeFromSuperview()
            pool.current = nil
        }
        refreshChrome()
    }

    private func swap(in slot: PooledConversationView) {
        if let current = pool.current, current !== slot {
            current.webView.removeFromSuperview()
        }
        if slot.webView.superview !== webContainer {
            slot.webView.frame = webContainer.bounds
            slot.webView.autoresizingMask = [.width, .height]
            webContainer.addSubview(slot.webView)
        }
        pool.current = slot
        pool.touch(slot)
        applyBottomInset()
        pushBodyStates(to: slot)
        find.slotDidChange()
        if let target = selectedMessageID { evaluate("window.ss.target(\(ConversationShellAssets.jsStringLiteral(RenderPayload.messageKey(for: target))))", in: slot) }
        if let state = showSignpost {
            ConversationSignposts.end(ConversationSignposts.show, state)
            showSignpost = nil
        }
        refreshChrome()
        if slot.renderedID == currentConversationID, !slot.renderInFlight {
            let waiters = showLandedWaiters
            showLandedWaiters = []
            for waiter in waiters { waiter(slot.webView) }
        }
    }

    /// Debug aid for `--snapshot`: runs `completion` with the reader's web view once the shown
    /// conversation's render has landed, or with nil after `timeout`.
    func whenShownRenderLands(timeout: TimeInterval, _ completion: @escaping (WKWebView?) -> Void) {
        if let current = pool.current, current.renderedID != nil, current.renderedID == currentConversationID, !current.renderInFlight {
            completion(current.webView)
            return
        }
        var finished = false
        let once: (WKWebView?) -> Void = { webView in
            guard !finished else { return }
            finished = true
            completion(webView)
        }
        showLandedWaiters.append(once)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { once(nil) }
    }

    private func slotWasRecreated(_ slot: PooledConversationView) {
        // A waiter released by the reset may already have re-rendered the current conversation into it.
        guard slot === pool.current, let id = currentConversationID, slot.renderedID != id else { return }
        let prepared = prepare(visibleMessages(for: id))
        pool.render(prepared.payload, inputs: prepared.inputs, id: id, into: slot) { [weak self] rendered in
            // A new shell holds no search: an open find bar makes it again.
            if rendered, slot === self?.pool.current { self?.find.slotDidChange(restarted: true) }
        }
    }

    // MARK: Chrome: header, desk and quick reply

    /// The reader's state as the header, the desk and the quick reply read it.
    private enum ReaderState {
        case nothing
        case several([ConversationID])
        case one(ConversationID, inTrash: Bool, emptied: Bool)
    }

    private var readerState: ReaderState {
        switch selection {
        case .none: return .nothing
        case .several(let ids): return .several(ids)
        case .one(let id):
            let inTrash = !currentMessages.isEmpty && currentMessages.allSatisfy { $0.roles.contains(.trash) }
            return .one(id, inTrash: inTrash, emptied: currentMessages.isEmpty)
        }
    }

    private func refreshChrome() {
        if case .one(let id) = selection {
            refreshChrome(for: id, messages: currentMessages)
        } else {
            refreshChrome(for: nil, messages: [])
        }
    }

    private func refreshChrome(for id: ConversationID?, messages: [MessageMetadata]) {
        guard isViewLoaded else { return }
        let state = readerState
        header.apply(headerContent(state, messages: messages))
        let showsWeb: Bool
        let showsReply: Bool
        switch state {
        case .nothing:
            emptyState.sentence = "No conversation selected"
            emptyState.hint = [.keys(["J", "K"]), .text("to move \u{00b7}"), .keys(["\u{21a9}"]), .text("to open")]
            showsWeb = false
            showsReply = false
        case .several(let ids):
            emptyState.sentence = Self.severalSentence(ids.count)
            if mailboxView == .trash {
                emptyState.hint = [.keys(["\u{21e7}I"]), .text("moves them to Inbox \u{00b7}"), .keys(["S"]), .text("stars them")]
            } else if mailboxView == .drafts {
                // The header offers only Discard Draft here (§5.19), so the hint names only that.
                emptyState.hint = [.keys(["#"]), .text("discards them")]
            } else {
                emptyState.hint = [.keys(["E"]), .text("archives them \u{00b7}"), .keys(["#"]), .text("moves them to Trash \u{00b7}"),
                                   .keys(["S"]), .text("stars them")]
            }
            showsWeb = false
            showsReply = false
        case let .one(_, inTrash, emptied):
            emptyState.sentence = "No messages to show"
            emptyState.hint = [.text("They were deleted or moved on another device.")]
            showsWeb = !emptied
            showsReply = !emptied && !inTrash && mailboxView != .trash && mailboxView != .drafts
        }
        emptyState.isHidden = showsWeb
        webContainer.isHidden = !showsWeb
        // Nothing, several or an emptied conversation leaves nothing to search.
        if !showsWeb { find.close(returningFocus: false) }
        let wasVisible = !quickReply.isHidden
        quickReply.isHidden = !showsReply
        if showsReply {
            configureQuickReply(messages: messages)
        } else if wasVisible, quickReply.isFocused {
            view.window?.makeFirstResponder(nil)
        }
        if !showsReply, let send = quickSend { moveQuickSendToPanel(send) }
        if wasVisible != showsReply { applyBottomInset() }
    }

    /// The bar hides mid-countdown (Trash, Drafts, nothing or several selected): the countdown moves to an
    /// undo-send panel for its remaining seconds, so Undo is never lost (§5.18). The panel's Undo reopens the
    /// reply in a composer, as a composer send's does (§5.31).
    private func moveQuickSendToPanel(_ send: QuickSend) {
        quickSendTimer?.invalidate()
        quickSendTimer = nil
        quickSend = nil
        quickReply.hideStrip()
        quickReply.status = .none
        let remaining = send.endsAt.timeIntervalSinceNow
        if remaining > 0 {
            let accounts = accountsByID.values.sorted { $0.addedAt < $1.addedAt }
            UndoSendPanel.show(client: client, accounts: accounts, sendID: send.sendID, draft: send.draft, undoWindow: Self.undoWindow,
                               remaining: remaining, startedAt: send.startedAt, archive: send.archive)
        }
        onQuickSendChange?()
    }

    private func headerContent(_ state: ReaderState, messages: [MessageMetadata]) -> ReaderHeaderView.Content {
        switch state {
        case .nothing:
            return .init(kicker: nil, headline: nil, placeholder: "No subject", actions: .make(.nothing))
        case .several(let ids):
            let allStarred = ids.allSatisfy(isStarred)
            return .init(kicker: .init(inkSlot: nil, lead: "Selection", accountName: nil, trail: nil),
                         headline: "\(ids.count) conversations selected", placeholder: "No subject",
                         actions: .make(.several(count: ids.count, view: mailboxView, allStarred: allStarred)))
        case let .one(id, inTrash, emptied):
            let account = accountsByID[id.accountID]
            let multipleAccounts = accountsByID.count > 1
            let name = multipleAccounts ? account.map(AccountLabels.name(for:)) : nil
            let slot = multipleAccounts ? account?.inkSlot : nil
            let drafts = mailboxView == .drafts
            let count = messages.count == 1 ? "1 message" : "\(messages.count) messages"
            let kicker = drafts
                ? ReaderHeaderView.Kicker(inkSlot: slot, lead: "Draft", accountName: name, trail: nil)
                : ReaderHeaderView.Kicker(inkSlot: slot, lead: nil, accountName: name, trail: emptied ? nil : count)
            let target = replyTarget(in: messages)
            let replyAll = target.map { QuickReplyComposer.replyAllAvailable(for: $0, accounts: accountsByID) } ?? false
            let actions = ReaderActionSet.make(.one(view: mailboxView, inTrash: inTrash, emptied: emptied,
                                                    starred: messages.contains(where: \.isStarred), replyAllAvailable: replyAll))
            let subject = emptied ? (header.content.headline ?? "") : RenderPayloadBuilder.subject(of: messages)
            return .init(kicker: kicker, headline: subject, placeholder: drafts ? "New Message" : "No subject", actions: actions)
        }
    }

    /// A conversation is starred when one of its messages is, as the header reads one conversation. One indexed
    /// read per selected conversation, never a page of the whole view: ⇧J extends the selection at key repeat.
    private func isStarred(_ id: ConversationID) -> Bool {
        visibleMessages(for: id).contains(where: \.isStarred)
    }

    /// "Three conversations, one keystroke." (spec §5.19), the count spelled out in the locale.
    static func severalSentence(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .spellOut
        let words = formatter.string(from: NSNumber(value: count)) ?? String(count)
        return words.prefix(1).uppercased() + words.dropFirst() + " conversations, one keystroke."
    }

    /// The message R, A and the quick reply answer: the target (spec §5.14), else the latest.
    private func replyTarget(in messages: [MessageMetadata]) -> MessageMetadata? {
        if let id = selectedMessageID, let target = messages.first(where: { $0.id == id }) { return target }
        return messages.last
    }

    /// N, P, a click or Tab moved the target: the header's Reply All and the quick reply's names follow it.
    private func targetDidChange() {
        guard isViewLoaded, case .one = selection else { return }
        header.apply(headerContent(readerState, messages: currentMessages))
        if !quickReply.isHidden { configureQuickReply(messages: currentMessages) }
    }

    private func configureQuickReply(messages: [MessageMetadata]) {
        quickReply.isComposerOpen = replyComposer(for: messages) != nil
        guard let latest = replyTarget(in: messages) else { return }
        quickReply.replyName = QuickReplyComposer.replyTargetName(for: latest, accounts: accountsByID)
        quickReply.replyAllName = QuickReplyComposer.replyAllTargetName(for: latest, accounts: accountsByID)
        quickReply.replyAllAvailable = QuickReplyComposer.replyAllAvailable(for: latest, accounts: accountsByID)
        if let account = accountsByID[latest.id.accountID] {
            let monogram = AccountLabels.monogram(for: account, among: Array(accountsByID.values))
            quickReply.face = (monogram, account.inkSlot)
        } else {
            quickReply.face = nil
        }
    }

    /// How far the quick reply covers the reader from its bottom edge: 0 while the bar is hidden. A reader window's toast
    /// sits that far up (§5.49).
    var bottomOverlayHeight: CGFloat {
        guard isViewLoaded, !quickReply.isHidden else { return 0 }
        return quickReply.barHeight
    }

    /// Called when `bottomOverlayHeight` may have changed.
    var onBottomOverlayChange: (() -> Void)?

    /// The shell pads the conversation by the bar's height + 12, once per height change (spec §8.4).
    private func applyBottomInset() {
        onBottomOverlayChange?()
        guard let current = pool.current else { return }
        let inset = quickReply.isHidden ? 0 : quickReply.barHeight
        evaluate("window.ss && window.ss.setBottomInset(\(Int(inset)))", in: current)
    }

    // MARK: Store

    private func visibleMessages(for id: ConversationID) -> [MessageMetadata] {
        if let local = localDrafts?.messages(in: id) { return local }
        return RenderPayloadBuilder.visibleMessages((try? client.store.messages(in: id)) ?? [])
    }

    private func showsDraftInComposer(_ message: MessageMetadata) -> Bool {
        message.roles.contains(.drafts) && isDraftInComposer(message.id)
    }

    /// The body a render shows for `message`: none while its draft is open in a composer, a kept draft's from
    /// this Mac, otherwise the store's.
    private func renderableBody(_ message: MessageMetadata) -> StoredBody? {
        if showsDraftInComposer(message) { return nil }
        if LocalDraftConversation.isLocal(message.id) { return localDrafts?.body(for: message.id) }
        return try? client.store.body(for: message.id)
    }

    /// The payload for one render and the inputs it was built from. The only place bodies are read in bulk.
    private func prepare(_ messages: [MessageMetadata]) -> (payload: RenderPayload, inputs: RenderInputs) {
        // What this renders stays whole for the run, marked before any body is read: a Keep mail clean-up reads the marks
        // inside its write, so it leaves the bodies on screen, and a backfill fetching a message shown without one
        // stores it whole, so the next refresh shows it.
        let shown = messages.map(\.id).filter { !LocalDraftConversation.isLocal($0) }
        if !shown.isEmpty { client.keepBodies(of: shown) }
        var bodies: [MessageID: StoredBody] = [:]
        var states = bodyStates
        for message in messages {
            if let body = renderableBody(message) { bodies[message.id] = body }
            if showsDraftInComposer(message) { states[message.id] = .inComposer }
        }
        // Replies still in the outbox follow as the newest sheets; they are never the target and never fetched.
        let sheets = pendingSheets(answering: messages)
        for sheet in sheets { bodies[sheet.metadata.id] = sheet.body }
        let all = messages + sheets.map(\.metadata)
        let settings = AppSettings.shared
        // A Send Later message's sheet says when it sends (§5.19); only the drafts on screen are passed, so the inputs of
        // every other conversation stay as they were.
        let laterStates = localDrafts?.sendLaterStates.filter { state in messages.contains { $0.id == state.key } } ?? [:]
        let payload = builder.build(
            messages: all, bodies: bodies, accounts: accountsByID, bodyStates: states,
            loadRemoteImages: Self.loadRemoteImages, readingSans: QuireEnvironment.typeface == .sfPro,
            textSize: appSettings.readerSize.rawValue,
            colorsNoticeDismissed: settings.originalColorsNoticeDismissed, pending: Set(sheets.map(\.metadata.id)),
            invitationPermissionNeeded: invitationPermissionNeeded, sendLater: laterStates
        )
        return (payload, RenderInputs(messages: all, sendLater: laterStates) { bodies[$0] != nil })
    }

    private func applyMessages(_ messages: [MessageMetadata], for id: ConversationID) {
        currentMessages = messages
        if let selected = selectedMessageID, messages.contains(where: { $0.id == selected }) {
            // Keep the user's pick across refreshes of the same conversation.
        } else {
            selectedMessageID = messages.last?.id
        }
        refreshChrome(for: id, messages: messages)
    }

    private func observe(_ id: ConversationID) {
        observation?.cancel()
        observation = nil
        // A kept draft is not in the store; `draftsDidChange()` brings its edits.
        guard !LocalDraftConversation.isLocal(id) else { return }
        // The store contract delivers on the main thread; the dispatch branch only guards a store that does not.
        observation = client.store.observeConversation(id) { [weak self] messages in
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.conversationDidChange(id, messages: messages)
                }
            } else {
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.conversationDidChange(id, messages: messages)
                    }
                }
            }
        }
    }

    private func conversationDidChange(_ id: ConversationID, messages: [MessageMetadata]) {
        guard currentConversationID == id else { return }
        let visible = RenderPayloadBuilder.visibleMessages(messages)
        let known = Set(currentMessages.map(\.id))
        applyMessages(visible, for: id)
        // Emptied while open (its last message deleted or moved elsewhere): the desk says so (spec §5.9).
        guard !visible.isEmpty else { return }
        refreshCurrentIfStale(visible, id: id)
        // A message that joins the open conversation without a body (an older one the backfill lists) is fetched at
        // once, as opening the conversation would have.
        requestMissingBodies(visible.filter { !known.contains($0.id) }, rendered: pool.current?.renderedInputs)
    }

    private func refreshCurrentIfStale(_ messages: [MessageMetadata], id: ConversationID) {
        guard let current = pool.current else { return }
        refreshIfStale(current, messages: messages, id: id)
    }

    /// Re-renders `slot` in place only when the metadata or the set of available bodies moved on since
    /// it was rendered. The check compares inputs, never body bytes the slot already holds.
    private func refreshIfStale(_ slot: PooledConversationView, messages: [MessageMetadata], id: ConversationID) {
        guard slot.renderedID == id else { return }
        let rendered = slot.renderedInputs ?? .empty
        let all = messages + pendingSheets(answering: messages).map(\.metadata)
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let fresh = rendered.refreshed(with: all) { [weak self] id in
            guard let self, let message = byID[id] else { return false }
            return PendingSheet.isPending(id) || self.renderableBody(message) != nil
        }
        guard fresh != rendered else { return }
        // Mark-read and star are the common changes; they patch the headers without reading a body.
        if let patches = rendered.flagPatches(to: fresh), pool.patchFlags(patches, inputs: fresh, id: id, in: slot) {
            return
        }
        let prepared = prepare(messages)
        pool.refresh(prepared.payload, inputs: prepared.inputs, id: id, into: slot)
    }

    // MARK: Bodies

    /// Fetches bodies the slot rendered without; `rendered` says which ones it had, so those are never looked up.
    private func requestMissingBodies(_ messages: [MessageMetadata], rendered: RenderInputs?) {
        for message in messages where bodyFetches.contains(message.id) == false {
            if rendered?.hasBody(message.id) == true { continue }
            // A kept draft has no provider copy, and a draft open in a composer shows no body.
            if LocalDraftConversation.isLocal(message.id) || showsDraftInComposer(message) { continue }
            guard (try? client.store.body(for: message.id)) == nil else { continue }
            fetchBody(message.id, conversation: message.conversationID)
        }
    }

    private func fetchBody(_ id: MessageID, conversation: ConversationID) {
        bodyFetches.insert(id)
        setBodyState(.loading, for: id)
        let client = self.client
        Task { [weak self] in
            var outcome: RenderPayload.BodyState = .ready
            do {
                _ = try await client.ensureBody(for: id)
            } catch {
                outcome = Self.isOffline(error) ? .offline : .failed
            }
            guard let self else { return }
            self.bodyFetches.remove(id)
            if outcome == .ready {
                self.bodyStates[id] = nil
            } else {
                if outcome == .offline { self.offlineAccounts.insert(id.accountID) }
                self.setBodyState(outcome, for: id)
            }
            guard self.currentConversationID == conversation else { return }
            self.refreshCurrentIfStale(self.currentMessages, id: conversation)
        }
    }

    /// A fetch that failed for want of a network waits for the connection; anything else is a failure with Retry.
    private static func isOffline(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dataNotAllowed, .internationalRoamingOff, .dnsLookupFailed:
            return true
        default:
            return false
        }
    }

    /// What stands in for the message's body, nil once it has one or when none was asked for; internal so the app's
    /// tests can see a fetch start.
    func bodyState(of id: MessageID) -> RenderPayload.BodyState? {
        bodyStates[id]
    }

    private func setBodyState(_ state: RenderPayload.BodyState, for id: MessageID) {
        guard bodyStates[id] != state else { return }
        bodyStates[id] = state
        guard let current = pool.current else { return }
        let patch = [RenderPayload.BodyStatePatch(id: RenderPayload.messageKey(for: id), bodyState: state)]
        guard let data = try? JSONEncoder().encode(patch) else { return }
        evaluate("window.ss && window.ss.bodyStates(\(String(decoding: data, as: UTF8.self)))", in: current)
    }

    /// A pre-rendered slot was built with the states of its time; the shown one gets today's.
    private func pushBodyStates(to slot: PooledConversationView) {
        let patches = currentMessages.compactMap { message -> RenderPayload.BodyStatePatch? in
            guard let state = bodyStates[message.id] else { return nil }
            return RenderPayload.BodyStatePatch(id: RenderPayload.messageKey(for: message.id), bodyState: state)
        }
        guard !patches.isEmpty, let data = try? JSONEncoder().encode(patches) else { return }
        evaluate("window.ss && window.ss.bodyStates(\(String(decoding: data, as: UTF8.self)))", in: slot)
    }

    /// When the connection returns, bodies that waited for it start by themselves (spec §5.14). An account starting or
    /// ending a wait for calendar permission changes what invitation cards say: shown again from the store.
    private func statusesChanged(_ statuses: [AccountSyncStatus]) {
        let needingPermission = Set(statuses.filter { $0.permissionsNeeded.contains(.calendar) }.map(\.accountID))
        if needingPermission != invitationPermissionNeeded {
            invitationPermissionNeeded = needingPermission
            invitationsMayHaveChanged()
        }
        let stillOffline = Set(statuses.filter { $0.phase == .error && ($0.message ?? "").hasPrefix("network") }.map(\.accountID))
        let back = offlineAccounts.subtracting(stillOffline)
        guard !back.isEmpty else { return }
        offlineAccounts = stillOffline
        let waiting = currentMessages.filter { bodyStates[$0.id] == .offline && back.contains($0.id.accountID) }
        for message in waiting where !bodyFetches.contains(message.id) {
            fetchBody(message.id, conversation: message.conversationID)
        }
    }

    // MARK: Read state and failed marks

    private func scheduleMarkRead(for id: ConversationID) {
        markReadTimer?.invalidate()
        markReadTimer = nil
        guard currentMessages.contains(where: { !$0.isRead }) else { return }
        markReadTimer = Timer.scheduledTimer(withTimeInterval: Self.markReadDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.markRead(id) }
        }
    }

    private func markRead(_ id: ConversationID) {
        markReadTimer = nil
        guard currentConversationID == id, currentMessages.contains(where: { !$0.isRead }) else { return }
        do {
            try client.perform(.setRead(true), on: id)
        } catch {
            ConversationSignposts.log.error("mark read failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Opening a conversation for 150 ms acknowledges its failed-operation mark (spec §8.5): the row's triangle
    /// has been seen. Selections that only pass through it on `j`/`k` leave the mark alone.
    private func scheduleAcknowledge(for id: ConversationID) {
        acknowledgeTimer?.invalidate()
        acknowledgeTimer = nil
        guard !LocalDraftConversation.isLocal(id) else { return }
        acknowledgeTimer = Timer.scheduledTimer(withTimeInterval: Self.acknowledgeDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.acknowledgeTimer = nil
                guard self.currentConversationID == id else { return }
                do {
                    try self.client.store.acknowledgeFailedOperation(conversationID: id)
                } catch {
                    ConversationSignposts.log.error("acknowledging a failed operation failed: \(String(describing: error), privacy: .public)")
                }
            }
        }
    }

    // MARK: Preferences, modes and resizing

    /// The Font setting and the colours notice change what bodies and avatars look like, never what they hold:
    /// every shell is told in place, and the payloads built from now on carry the new values.
    private func displayPreferencesDidChange() {
        broadcastPreferences()
    }

    /// The typeface and reader Text size last told to the shells. Graphite and contrast changes post the same
    /// notification; they reach the shells through the pool's modes, so only these are broadcast here.
    private var broadcastTypeface = QuireEnvironment.typeface
    /// Every payload carries the reader's size, so the shells start at the one the reader has when it is built.
    private var broadcastTextSize: QuireFont.TextSize

    /// A Text size change's progress through the shells (tests read it; the `conversation.textSize` interval spans it).
    enum TextSizeEvent: Equatable {
        /// Told to every ready shell.
        case began(QuireFont.TextSize)
        /// Every shell told has measured its bodies again at it (the follow-up pass 50 ms later aside).
        case measured(QuireFont.TextSize)
    }

    /// For tests: every Text size broadcast and its end. Nil in the app.
    var onTextSizeEvent: ((TextSizeEvent) -> Void)?

    private func readerTypeMayHaveChanged() {
        header.textSize = appSettings.readerSize
        guard QuireEnvironment.typeface != broadcastTypeface || appSettings.readerSize != broadcastTextSize else { return }
        broadcastPreferences()
    }

    /// `readingSans` is the Font setting (spec §4.4): the shell sets plain and unstyled bodies in `readingSans`
    /// and toggles `html.ss-sf`, which puts the avatar initials in `monogramSans`. `textSize` is the reader's own
    /// size (spec §4.15): the shell's `html.ss-text-*` class, which measures every body again.
    private func broadcastPreferences() {
        let settings = AppSettings.shared
        let size = appSettings.readerSize
        let sizeChanged = size != broadcastTextSize
        broadcastTypeface = QuireEnvironment.typeface
        broadcastTextSize = size
        let sans = broadcastTypeface == .sfPro
        let script = "window.ss && window.ss.preferences({readingSans: \(sans), textSize: '\(size.rawValue)', "
            + "colorsNoticeDismissed: \(settings.originalColorsNoticeDismissed)})"
        guard sizeChanged else {
            pool.broadcastPreferences(script)
            return
        }
        // A new size measures every body of every ready shell again inside the script itself, so the interval (the
        // Text size budget in docs/ARCHITECTURE.md) ends once the last shell has run it.
        let interval = ConversationSignposts.begin(ConversationSignposts.textSize)
        onTextSizeEvent?(.began(size))
        pool.broadcastPreferences(script) { [weak self] in
            ConversationSignposts.end(ConversationSignposts.textSize, interval)
            self?.onTextSizeEvent?(.measured(size))
        }
    }

    /// Wide HTML is refitted once a live resize ends, never per frame (spec §5.14).
    private func liveResizeEnded() {
        guard let current = pool.current else { return }
        evaluate("window.ss && window.ss.refit()", in: current)
    }

    // MARK: Shell messages

    private func handle(_ message: ConversationScriptMessage, from slot: PooledConversationView) {
        if case .focusMark(let on, let arrows) = message {
            slot.markFocused = on
            slot.arrowsFocused = arrows
            return
        }
        guard slot === pool.current else { return }
        switch message {
        case .ready, .focusMark:
            break
        case .motion:
            // The registry holds animators weakly; this one lives until the next motion replaces it.
            let finisher = ShellMotionFinisher(slot: slot)
            motionFinisher = finisher
            Quire.Motion.register(finisher)
        case .select(let id):
            setTarget(id)
            if focusedAttachment?.message != id { focusedAttachment = nil }
        case .focusAttachment(let id, let attachment):
            focusedAttachment = (id, attachment)
        case let .originalColors(id, on):
            if on { originalColorsShown.insert(id) } else { originalColorsShown.remove(id) }
        case .find(let result):
            find.received(result, from: slot)
        case let .action(type, messageID, attachmentID, on, point, value):
            guard let messageID else { return }
            selectedMessageID = messageID
            switch type {
            case "reply": onAction?(.reply(messageID))
            case "replyAll": onAction?(.replyAll(messageID))
            case "forward": onAction?(.forward(messageID))
            case "openAttachment":
                if let attachmentID { openAttachment(id: attachmentID, of: messageID) }
            case "openAttachmentWithApp":
                // A double click: the first click's Quick Look gives way to the default app (spec §5.17).
                if let attachmentID {
                    preview.cancel()
                    performAttachment(.open, attachmentID, of: messageID)
                }
            case "attachmentMenu":
                guard let attachmentID else { return }
                menuAttachment = (messageID, attachmentID)
                attachmentMenu.menu().popUp(positioning: nil, at: point ?? .zero, in: slot.webView)
            case "downloadAttachment":
                guard let attachmentID, let info = attachments(of: messageID).first(where: { $0.id == attachmentID }) else { return }
                downloadAttachment(info, of: messageID)
            case "downloadAllAttachments":
                downloadAllAttachments(of: messageID)
            case "star":
                performOnMessage(.setStarred(on ?? true), messageID)
            case "more":
                showMoreMenu(for: messageID, at: point ?? .zero, in: slot)
            case "messageMenu":
                // The selection's menu (§5.35): the reader shows one conversation, which is the selection.
                messageMenu?()?.popUp(positioning: nil, at: point ?? .zero, in: slot.webView)
            case "retryBody":
                guard let conversation = currentConversationID, !bodyFetches.contains(messageID) else { return }
                fetchBody(messageID, conversation: conversation)
            case "dismissColorsNotice":
                AppSettings.shared.originalColorsNoticeDismissed = true
                broadcastPreferences()
            case "unsubscribe":
                onAction?(.unsubscribe(messageID))
            case "continueDraft":
                onAction?(.continueDraft(messageID))
            case "discardDraft":
                if let id = currentConversationID { onAction?(.discardDrafts([id])) }
            case "cancelSendLater":
                if let id = currentConversationID { onAction?(.cancelSendLater(id)) }
            case "answerInvitation":
                guard let response = value.flatMap(InvitationResponse.init(rawValue:)) else { return }
                answerInvitation(response, messageID)
            case "openInCalendar":
                openInCalendar(messageID)
            case "openInvitationLink":
                if let value { openInvitationLink(value) }
            case "reconnectForInvitation":
                onAction?(.reconnect(messageID.accountID))
            default:
                ConversationSignposts.log.debug("unknown shell action \(type, privacy: .public)")
            }
        }
    }

    // MARK: Invitations (spec §5.14)

    /// Recorded in the store at once and queued for the engine; the card re-renders from the store, already showing the
    /// answer the shell marked as chosen.
    private func answerInvitation(_ response: InvitationResponse, _ id: MessageID) {
        do {
            try client.answerInvitation(response, to: id)
        } catch {
            ConversationSignposts.log.error("answering an invitation failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
            // The shell marked the answer before asking; the store's state puts the card back.
            invitationsMayHaveChanged()
        }
    }

    /// The cards of the conversation on screen are brought up to the store and the accounts' permissions; pre-rendered
    /// neighbours are dropped, as they were built with the old state.
    private func invitationsMayHaveChanged() {
        pool.clearAll(except: pool.current)
        guard let id = currentConversationID, let current = pool.current, current.renderedID == id else { return }
        let prepared = prepare(currentMessages)
        pool.refresh(prepared.payload, inputs: prepared.inputs, id: id, into: current)
    }

    /// Hands the invitation's calendar file to Calendar, which shows it and offers to add it: no EventKit, so no
    /// calendar permission. The file is written to this run's own temporary folder, off the main thread.
    private func openInCalendar(_ id: MessageID) {
        guard let text = (try? client.store.body(for: id))?.invitation?.calendarText else {
            NSSound.beep()
            return
        }
        let subject = currentMessages.first { $0.id == id }?.subject
        Task.detached(priority: .userInitiated) {
            let file = InvitationFiles.write(text, named: subject)
            await MainActor.run {
                guard let file else { return NSSound.beep() }
                InvitationFiles.openInCalendar(file)
            }
        }
    }

    /// A location or meeting link on the card: only web addresses, in the browser.
    private func openInvitationLink(_ value: String) {
        guard let url = CalendarInvitationReader.webAddress(value) else { return }
        NSWorkspace.shared.open(url)
    }

    /// The accounts whose answered invitations wait for permission to update the calendar, as the cards show them.
    private var invitationPermissionNeeded: Set<AccountID> = []

    private func performOnMessage(_ change: MetadataChange, _ id: MessageID) {
        // A kept draft lives only on this Mac: there is nothing to star or mark on a provider.
        guard !LocalDraftConversation.isLocal(id) else {
            NSSound.beep()
            return
        }
        do {
            try client.perform(change, on: [id])
        } catch {
            ConversationSignposts.log.error("message action failed: \(String(describing: error), privacy: .public)")
            NSSound.beep()
        }
    }

    // MARK: More menu

    private func showMoreMenu(for id: MessageID, at point: CGPoint, in slot: PooledConversationView) {
        slot.webView.evaluateJavaScript("window.ss.targetState()") { [weak self] result, _ in
            guard let self, slot === self.pool.current else { return }
            self.makeMoreMenu(for: id, shellState: result as? [String: Any] ?? [:]).popUp(positioning: nil, at: point, in: slot.webView)
        }
    }

    /// The More menu of message `id` as it stands; `state` is the shell's `targetState()` (images blocked, original
    /// colours offered or shown). Its items act on the target message, which the click on More has just made `id`.
    func makeMoreMenu(for id: MessageID, shellState state: [String: Any]) -> NSMenu {
        let message = currentMessages.first { $0.id == id }
        return moreMenu.menu(MessageMoreMenu.Options(
            isStarred: message?.isStarred ?? false,
            imagesBlocked: state["imagesBlocked"] as? Bool ?? false,
            offersOriginal: state["offersOriginal"] as? Bool ?? false,
            showsOriginal: state["original"] as? Bool ?? false,
            hasSenderAddress: !(message?.from?.address ?? "").isEmpty,
            canUnsubscribe: message.map(Self.offersUnsubscribe) ?? false,
            offersSenderRules: message.map(offersSenderRule) ?? false,
            senderRule: message.flatMap(senderRule(for:))
        ))
    }

    private func performMore(_ command: MessageMoreMenu.Command) {
        guard let id = selectedMessageID, let current = pool.current else { return }
        switch command {
        case .reply: onAction?(.reply(id))
        case .replyAll: onAction?(.replyAll(id))
        case .forward: onAction?(.forward(id))
        case .toggleStar:
            let starred = currentMessages.first { $0.id == id }?.isStarred ?? false
            performOnMessage(.setStarred(!starred), id)
        case .markUnreadFromHere:
            guard let index = currentMessages.firstIndex(where: { $0.id == id }) else { return }
            markReadTimer?.invalidate()
            markReadTimer = nil
            do {
                try client.perform(.setRead(false), on: currentMessages[index...].map(\.id))
            } catch {
                ConversationSignposts.log.error("mark unread failed: \(String(describing: error), privacy: .public)")
            }
        case .loadImages:
            evaluate("window.ss.loadImages(null)", in: current)
        case .toggleOriginal:
            evaluate("window.ss.toggleOriginal()", in: current)
        case .unsubscribe:
            onAction?(.unsubscribe(id))
        case .alwaysArchiveSender:
            onAction?(.senderRule(.archive, id))
        case .blockSender:
            onAction?(.senderRule(.trash, id))
        case .copySenderAddress:
            guard let address = currentMessages.first(where: { $0.id == id })?.from?.address else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
        }
    }

    // MARK: Unsubscribe

    /// What Message › Unsubscribe (⇧⌘U) acts on: the open conversation's latest message whose list headers offer a
    /// way to unsubscribe (spec §5.14). Nil with nothing or several selected, and in a conversation with none, which
    /// is how the menu item knows to be disabled without reading the store.
    var unsubscribeTarget: MessageID? {
        guard case .one = selection else { return nil }
        return currentMessages.last(where: Self.offersUnsubscribe)?.id
    }

    /// The rule the shell's link follows (`RenderPayload.Message.unsubscribe`), drafts left out.
    private static func offersUnsubscribe(_ message: MessageMetadata) -> Bool {
        !message.roles.contains(.drafts) && UnsubscribeMethod(message: message) != nil
    }

    // MARK: Sender rules

    /// Whose mail the context menu's and the Message menu's sender rules take (spec, Sender rules (Q4.2)): with one
    /// conversation open, the target message when someone other than the user sent it, else the newest message someone
    /// else sent. Nil with nothing or several selected and for a conversation of the user's own mail alone, which is how
    /// those items know to be disabled without reading the store.
    var senderRuleTarget: MessageMetadata? {
        guard case .one = selection else { return nil }
        if let id = selectedMessageID, let target = currentMessages.first(where: { $0.id == id }), offersSenderRule(target) {
            return target
        }
        return currentMessages.last(where: offersSenderRule)
    }

    /// A rule is set from mail someone else sent: never the user's own sent mail or drafts (which a rule would never
    /// take), nor mail from the account's own address, which a rule would turn on everything the user sends themselves.
    func offersSenderRule(_ message: MessageMetadata) -> Bool {
        guard !LocalDraftConversation.isLocal(message.id), message.roles.isDisjoint(with: [.sent, .drafts]),
              let from = message.from?.address, !SenderRule.normalizedAddress(from).isEmpty else { return false }
        guard let own = accountsByID[message.id.accountID]?.email else { return true }
        return SenderRule.normalizedAddress(own) != SenderRule.normalizedAddress(from)
    }

    /// The rule the message's sender has now, read when a menu opens (the rules are a handful of rows).
    func senderRule(for message: MessageMetadata) -> SenderRule.Action? {
        guard let from = message.from?.address else { return nil }
        let address = SenderRule.normalizedAddress(from)
        return (try? client.store.senderRules())?.first { $0.accountID == message.id.accountID && $0.address == address }?.action
    }

    // MARK: Header actions

    private func headerAction(_ action: ReaderActionSet.Action) {
        Quire.Motion.finishAll()
        switch selection {
        case .none:
            return
        case .several(let ids):
            switch action {
            case .star: onAction?(.applyToSelection(.setStarred(!header.content.actions.starOn), ids))
            case .archive: onAction?(.applyToSelection(.archive, ids))
            case .trash: onAction?(.applyToSelection(.trash, ids))
            case .moveToInbox: onAction?(.applyToSelection(.moveToInbox, ids))
            case .discardDraft: onAction?(.discardDrafts(ids))
            default: break
            }
        case .one(let id):
            let target = selectedMessageID ?? currentMessages.last?.id
            switch action {
            case .star: onAction?(.star(id, !header.content.actions.starOn))
            case .archive: onAction?(.archive(id))
            case .trash: onAction?(.trash(id))
            case .moveToInbox: onAction?(.moveToInbox(id))
            case .reply: if let target { onAction?(.reply(target)) }
            case .replyAll: if let target { onAction?(.replyAll(target)) }
            case .forward: if let target { onAction?(.forward(target)) }
            case .continueEditing:
                let draft = currentMessages.last { $0.roles.contains(.drafts) } ?? currentMessages.last
                if let draft { onAction?(.continueDraft(draft.id)) }
            case .discardDraft: onAction?(.discardDrafts([id]))
            }
        }
    }

    /// A composer opened or closed, or a kept draft changed on disk: the draft on screen renders again with its
    /// body or with “Open in a composer window”, and a kept draft that is gone (sent, discarded) empties the
    /// reader as a conversation emptied elsewhere does.
    func draftsDidChange() {
        guard isViewLoaded, case .one(let id) = selection, mailboxView == .drafts || LocalDraftConversation.isLocal(id) else { return }
        let messages = visibleMessages(for: id)
        applyMessages(messages, for: id)
        guard !messages.isEmpty, let current = pool.current, current.renderedID == id else { return }
        let prepared = prepare(messages)
        guard prepared.inputs != current.renderedInputs else { return }
        pool.refresh(prepared.payload, inputs: prepared.inputs, id: id, into: current)
    }

    // MARK: Attachments and Quick Look

    /// Space: Quick Look for the target message's attachments, starting from the focused chip, else the
    /// first, or close the panel if it is up. Returns false when there was nothing to do, so the key can go
    /// on to the web view and page down.
    @discardableResult
    func openQuickLookForSelectedMessage() -> Bool {
        let messageID = selectedMessageID ?? currentMessages.last?.id
        var parts = messageID.flatMap { try? client.store.attachments(of: $0) } ?? []
        if let focused = focusedAttachment, focused.message == messageID,
           let index = parts.firstIndex(where: { $0.id == focused.attachment }) {
            parts.insert(parts.remove(at: index), at: 0)
        }
        switch ReaderShortcuts.spaceOutcome(previewVisible: preview.isPanelVisible, markFocused: isMarkFocused, attachments: parts) {
        case .closePreview:
            preview.closePanel()
            return true
        case .preview(let info):
            guard let messageID else { return false }
            openAttachment(info, of: messageID)
            return true
        case .passThrough:
            return false
        }
    }

    /// Keyboard focus is on an elision mark in the conversation on screen (quoted text, or the message under an
    /// invitation card), or on a Download button or Download all: Space and ↩ press it in the page (spec §5.15, §5.17),
    /// so neither Quick Look nor the router's Open takes them. Only while the page itself has the window's focus; the
    /// shell says where focus is inside it.
    var isMarkFocused: Bool {
        guard let current = pool.current, current.markFocused else { return false }
        return pageHasFocus(current)
    }

    /// Keyboard focus is on an attachment chip or its Download button in the conversation on screen: ← and → move along
    /// the files there (spec §5.17), so ← does not take the keyboard back to the list.
    var isAttachmentRowFocused: Bool {
        guard let current = pool.current, current.arrowsFocused else { return false }
        return pageHasFocus(current)
    }

    /// The page on screen has the window's focus; the shell says where focus is inside it.
    private func pageHasFocus(_ current: PooledConversationView) -> Bool {
        guard !webContainer.isHidden, let responder = view.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: current.webView)
    }

    /// Read apart from the body, which a clean-up may have evicted in the instant this conversation went on screen.
    private func attachments(of messageID: MessageID) -> [AttachmentInfo] {
        ((try? client.store.attachments(of: messageID)) ?? []).filter { !$0.isInline }
    }

    private func openAttachment(id attachmentID: String, of messageID: MessageID) {
        guard let info = attachments(of: messageID).first(where: { $0.id == attachmentID }) else { return }
        openAttachment(info, of: messageID)
    }

    private func openAttachment(_ info: AttachmentInfo, of messageID: MessageID) {
        onAction?(.openAttachment(messageID, info))
        let siblings = attachments(of: messageID)
        setAttachmentFailed(false, info.id, of: messageID)
        let download = beginDownload(info.id, of: messageID)
        Task { [weak self] in
            guard let self else { return }
            let opened = await self.preview.preview(info, of: messageID, siblings: siblings, progress: download.progress) { [weak self] in
                self?.endDownload(download.ticket)
            }
            if !opened { self.setAttachmentFailed(true, info.id, of: messageID) }
        }
    }

    /// The attachment as a file, its chip showing the download while it is fetched; nil, with the chip marked,
    /// when the fetch failed.
    func fetchAttachmentFile(_ info: AttachmentInfo, of messageID: MessageID) async -> URL? {
        setAttachmentFailed(false, info.id, of: messageID)
        let download = beginDownload(info.id, of: messageID)
        let fetched = await preview.file(for: info, of: messageID, progress: download.progress)
        endDownload(download.ticket)
        if fetched == nil { setAttachmentFailed(true, info.id, of: messageID) }
        return fetched
    }

    /// Starts showing a fetch on its chip (spec §5.17). The chip shows it only once the fetch outlasts a cached file
    /// (150 ms, as spinners wait), so opening a file already on this Mac never flashes it; then determinate at the
    /// fraction the download reports, sweeping while its size is unknown. `progress` is the fetch's handler: the
    /// engine calls it at most about ten times a second, on any thread, and it hops to the main thread.
    private func beginDownload(_ attachmentID: String, of messageID: MessageID)
        -> (ticket: AttachmentDownloadBoard.Ticket, progress: @Sendable (Double) -> Void) {
        beginDownload(AttachmentDownloadBoard.Chip(message: messageID, attachmentID: attachmentID))
    }

    /// As above for any place a download shows: a chip, or a message's count line for Download all.
    private func beginDownload(_ chip: AttachmentDownloadBoard.Chip)
        -> (ticket: AttachmentDownloadBoard.Ticket, progress: @Sendable (Double) -> Void) {
        let ticket = downloads.begin(chip)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: AttachmentDownloadBoard.revealDelay)
            guard let self, let display = self.downloads.reveal(ticket) else { return }
            self.setAttachmentProgress(display, ticket.chip)
        }
        let progress: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor [weak self] in
                guard let self, let display = self.downloads.progress(fraction, for: ticket) else { return }
                self.setAttachmentProgress(display, ticket.chip)
            }
        }
        return (ticket, progress)
    }

    private func endDownload(_ ticket: AttachmentDownloadBoard.Ticket) {
        guard let display = downloads.end(ticket) else { return }
        setAttachmentProgress(display, ticket.chip)
    }

    private func setAttachmentProgress(_ display: AttachmentDownloadBoard.Display, _ chip: AttachmentDownloadBoard.Chip) {
        guard let slot = slot(showing: chip.message) else { return }
        let key = ConversationShellAssets.jsStringLiteral(RenderPayload.messageKey(for: chip.message))
        let value: String
        switch display {
        case .sweeping: value = "null"
        case .fraction(let fraction): value = String(max(0, min(1, fraction)))
        case .done: value = "-1"
        }
        if chip.isAllAttachments {
            evaluate("window.ss && window.ss.attachmentsProgress(\(key), \(value))", in: slot)
        } else {
            evaluate("window.ss && window.ss.attachmentProgress(\(key), \(ConversationShellAssets.jsStringLiteral(chip.attachmentID)), \(value))",
                     in: slot)
        }
    }

    /// The slot whose page holds `messageID`'s card: the one on screen, or one kept warm in the pool. A download that
    /// ends while another conversation is on screen must still give its chip and its control back, and mark a file
    /// it could not fetch, since coming back to that conversation is a swap with no render.
    private func slot(showing messageID: MessageID) -> PooledConversationView? {
        pool.slots.first { $0.renderedInputs?.messages.contains { $0.id == messageID } ?? false }
    }

    // MARK: Download and Download all (spec §5.17)

    /// The chip's Download and its menu's Save to Downloads: the file, fetched with the chip showing it, copied into
    /// Downloads under a free name and still quarantined; then the saved toast. A fetch that fails marks the chip.
    func downloadAttachment(_ info: AttachmentInfo, of messageID: MessageID) {
        let chip = AttachmentDownloadBoard.Chip(message: messageID, attachmentID: info.id)
        guard let folder = downloadsFolder else { return NSSound.beep() }
        guard !ignoresSave(chip) else { return }
        savesUnderWay.insert(chip)
        Task { [weak self] in
            guard let self else { return }
            let outcome = await AttachmentSaver.save([info], into: folder) { info, _ in
                await self.fetchAttachmentFile(info, of: messageID)
            }
            self.endSave(chip)
            self.onAction?(.attachmentsSaved(outcome))
        }
    }

    /// Download all and File › Download Attachments: every file of the message, one after another, with one progress
    /// on its count line rather than on each chip; a file that cannot be fetched marks its chip and the rest are saved.
    /// One file is that chip's Download, since a message with one file has no count line to show it. A file whose own
    /// Download is under way is left to it, so no file is saved twice.
    func downloadAllAttachments(of messageID: MessageID) {
        let infos = attachments(of: messageID)
        if infos.count == 1, let only = infos.first { return downloadAttachment(only, of: messageID) }
        guard !infos.isEmpty, let folder = downloadsFolder else { return NSSound.beep() }
        let chip = AttachmentDownloadBoard.Chip.allAttachments(of: messageID)
        guard !ignoresSave(chip) else { return }
        let pending = infos.filter { !savesUnderWay.contains(AttachmentDownloadBoard.Chip(message: messageID, attachmentID: $0.id)) }
        guard !pending.isEmpty else { return }
        savesUnderWay.insert(chip)
        for info in pending { setAttachmentFailed(false, info.id, of: messageID) }
        let download = beginDownload(chip)
        Task { [weak self] in
            guard let self else { return }
            let outcome = await AttachmentSaver.save(pending, into: folder, fetch: { info, progress in
                await self.preview.file(for: info, of: messageID, progress: progress)
            }, progress: download.progress, unfetched: { info in
                self.setAttachmentFailed(true, info.id, of: messageID)
            })
            self.endDownload(download.ticket)
            self.endSave(chip)
            self.onAction?(.attachmentsSaved(outcome))
        }
    }

    /// A press on Download (or, for `Chip.allAttachments`, on Download all) that would save a file twice: its save is
    /// under way, or ended a double-click ago; for one chip, its message's Download all is saving that file.
    private func ignoresSave(_ chip: AttachmentDownloadBoard.Chip) -> Bool {
        if savesUnderWay.contains(chip) { return true }
        if !chip.isAllAttachments, savesUnderWay.contains(.allAttachments(of: chip.message)) { return true }
        guard let ended = savesEnded[chip] else { return false }
        return ProcessInfo.processInfo.systemUptime - ended < NSEvent.doubleClickInterval
    }

    private func endSave(_ chip: AttachmentDownloadBoard.Chip) {
        savesUnderWay.remove(chip)
        let now = ProcessInfo.processInfo.systemUptime
        savesEnded = savesEnded.filter { now - $0.value < NSEvent.doubleClickInterval }
        savesEnded[chip] = now
    }

    private func performAttachment(_ command: AttachmentMenu.Command) {
        guard let target = menuAttachment else { return }
        performAttachment(command, target.attachment, of: target.message)
    }

    /// The chip's commands (spec §5.17). Each one fetches the file first, once per session; a failed fetch marks
    /// the chip, as a failed Quick Look does. Save to Downloads is the Download button's, toast and all.
    private func performAttachment(_ command: AttachmentMenu.Command, _ attachmentID: String, of messageID: MessageID) {
        guard let info = attachments(of: messageID).first(where: { $0.id == attachmentID }) else { return }
        switch command {
        case .quickLook:
            openAttachment(info, of: messageID)
            return
        case .saveToDownloads:
            downloadAttachment(info, of: messageID)
            return
        case .open, .saveAs, .copy:
            break
        }
        let window = view.window
        Task { [weak self] in
            guard let self, let file = await self.fetchAttachmentFile(info, of: messageID) else { return }
            switch command {
            case .quickLook, .saveToDownloads:
                break
            case .open:
                self.open(file, in: window)
            case .saveAs:
                let panel = NSSavePanel()
                panel.nameFieldStringValue = file.lastPathComponent
                let save: (NSApplication.ModalResponse) -> Void = { response in
                    guard response == .OK, let destination = panel.url else { return }
                    if !AttachmentSaver.copy(file, to: destination) { NSSound.beep() }
                }
                if let window { panel.beginSheetModal(for: window, completionHandler: save) } else { save(panel.runModal()) }
            case .copy:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([file as NSURL])
            }
        }
    }

    /// Hands the file to its app. A program or script asks first (Cancel is the default), as Mail does; the file
    /// is quarantined either way, so Gatekeeper still has its say over anything that runs.
    private func open(_ file: URL, in window: NSWindow?) {
        if !AttachmentSafety.isQuarantined(file) { try? AttachmentSafety.quarantine(file) }
        guard AttachmentSafety.runsCode(file) else {
            NSWorkspace.shared.open(file)
            return
        }
        AppAlert.openProgram(filename: file.lastPathComponent).present(on: window) { choice in
            if choice == 1 { NSWorkspace.shared.open(file) }
        }
    }

    /// "Couldn't download · Retry" on the chip (spec §5.17); opening it again is the retry.
    private func setAttachmentFailed(_ failed: Bool, _ attachmentID: String, of messageID: MessageID) {
        guard let slot = slot(showing: messageID) else { return }
        let key = ConversationShellAssets.jsStringLiteral(RenderPayload.messageKey(for: messageID))
        evaluate("window.ss && window.ss.attachmentFailed(\(key), \(ConversationShellAssets.jsStringLiteral(attachmentID)), \(failed))", in: slot)
    }

    /// Quick Look's data source and delegate, for the app's tests.
    var attachmentPreview: AttachmentPreviewController { preview }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        !preview.items.isEmpty
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = preview
        panel.delegate = preview
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }

    // MARK: Quick reply

    var isQuickReplyFocused: Bool { quickReply.isFocused }
    /// The bar itself, for the app's tests.
    var quickReplyBar: QuickReplyView { quickReply }

    /// Makes `id` the target message, as a click on it in the shell does (the shell's `select`, and tests).
    func setTarget(_ id: MessageID) {
        guard currentMessages.contains(where: { $0.id == id }) else { return }
        selectedMessageID = id
    }

    func focusQuickReply() {
        if bringReplyComposerForward() { return }
        quickReply.focus()
    }

    /// R and A from the list or the reader focus the field in Reply or Reply all mode (spec §5.18). False when
    /// the quick reply is hidden (Trash, Drafts, nothing or several selected), so the key opens the composer.
    /// While a composer holds this conversation's reply the bar is disabled and the key brings that window
    /// forward instead, so two replies never diverge.
    @discardableResult
    func focusQuickReply(all: Bool) -> Bool {
        guard isViewLoaded, !quickReply.isHidden else { return false }
        if bringReplyComposerForward() { return true }
        quickReply.focus(mode: all ? .replyAll : .reply)
        return true
    }

    /// The open composer replying to one of `messages` (spec §5.18, Disabled).
    private func replyComposer(for messages: [MessageMetadata]) -> ComposeWindowController? {
        guard !messages.isEmpty else { return nil }
        let controllers = ComposeWindowRegistry.shared.openControllers
        guard !controllers.isEmpty else { return nil }
        let ids = Set(messages.map(\.id))
        return controllers.first { $0.repliesTo.map(ids.contains) ?? false }
    }

    /// A composer opened or closed: the bar turns disabled while one holds this conversation's reply.
    func composersDidChange() {
        draftsDidChange()
        // A composer that closed may have queued a reply to this conversation, or an undo cancelled one.
        outboxTick()
        guard isViewLoaded, case .one = selection, !quickReply.isHidden else { return }
        quickReply.isComposerOpen = replyComposer(for: currentMessages) != nil
    }

    /// Brings forward the composer holding this conversation's reply; false when there is none.
    @discardableResult
    private func bringReplyComposerForward() -> Bool {
        guard case .one = selection, let composer = replyComposer(for: currentMessages), let window = composer.window else {
            quickReply.isComposerOpen = false
            return false
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        return true
    }

    /// Esc in the quick reply: the main window decides (§6.1 rows 7 and 9). Without one the field lets go and the
    /// web view takes focus.
    private func quickReplyEscape() {
        if let onAction {
            onAction(.escapeQuickReply)
        } else {
            leaveQuickReply()
        }
    }

    /// The field lets go, keeping its text, and the page takes focus: Esc in a reader window, which has no list to go
    /// back to (§6.1).
    func leaveQuickReply() {
        quickReply.blur()
        focusWebView()
    }

    /// The reader is going away with a quick reply still counting down (its reader window closing): the countdown moves
    /// to an undo-send panel for its remaining seconds, as when the bar hides, so its Undo is not lost (§5.18).
    func handOffQuickSend() {
        if let send = quickSend { moveQuickSendToPanel(send) }
    }

    /// The reader is going away (its reader window closing): the replies past their undo window whose outcome it was
    /// watching, which `watch(_:)` on a reader that stays takes over, so a failure still says so (§5.18).
    func handOffWatchedSends() -> [String: ComposeDraft] {
        defer { watchedSends = [:] }
        return watchedSends
    }

    /// Watches sends another reader handed over (`handOffWatchedSends`), as if this reader had sent them.
    func watch(_ sends: [String: ComposeDraft]) {
        guard !sends.isEmpty else { return }
        watchedSends.merge(sends) { mine, _ in mine }
        outboxTick()
    }

    /// Another reader parked text under the conversation this one shows (a reader window on it closed, §5.49): the
    /// text comes into this box, below what it holds, so it is where the conversation is on screen. Not while a
    /// composer holds the reply, whose bar takes no text.
    func takeParkedQuickReply() {
        guard isViewLoaded, case .one(let id) = selection, id == currentConversationID, !quickReply.isComposerOpen else { return }
        let parked = drafts.draft(under: id)
        guard !parked.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        drafts.forget(id)
        let typed = quickReply.text
        quickReply.restoreDraft(typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? parked : typed + "\n\n" + parked)
    }

    private func focusWebView() {
        guard let window = view.window else { return }
        if let current = pool.current {
            window.makeFirstResponder(current.webView)
        } else {
            window.makeFirstResponder(nil)
        }
    }

    /// The typed text moves to a reply composer and leaves the bar, which then shows its disabled state while
    /// that composer is open, so the reply is never in two places (§5.18).
    private func openQuickReplyInComposer(text: String, mode: QuickReplyView.Mode, attach: Bool) {
        guard let target = replyTarget(in: currentMessages)?.id else { return }
        onAction?(.replyInComposer(target, all: mode == .replyAll, body: text, attach: attach))
        quickReply.clear()
        quickReply.isComposerOpen = replyComposer(for: currentMessages) != nil
    }

    /// ⌘↩ in the quick reply (`action` nil: what Send does now), or ⇧⌘↩ (`.sendAndArchive`); internal so the app's tests
    /// can send one. Send and Archive archives the conversation once the reply is queued, as E would (in Later, or for a
    /// snoozed conversation, its snooze ends), and the strip's Undo brings it back with the reply (§5.23).
    func sendQuickReply(_ text: String, mode: QuickReplyView.Mode, action: SendAction? = nil) {
        guard let conversation = currentConversationID, let latest = replyTarget(in: currentMessages),
              let account = accountsByID[latest.id.accountID] else { return }
        // The account's signature follows the typed text, one empty line below it, as a composer would insert it (§5.18).
        let message = QuickReplyComposer.outgoingMessage(text: text, replyingTo: latest, accounts: accountsByID, all: mode == .replyAll,
                                                         signature: ComposeSignature.export(html: account.signature))
        guard !message.to.isEmpty else {
            quickReply.status = .noRecipients
            return
        }
        // What an undone or failed send reopens in a composer: the same text and signature, the signature marked as the
        // composer's own so From still replaces it there.
        let body = ComposeSignature.startingBody(typed: ComposeTextView.plainBody(text),
                                                 signature: ComposeSignature.body(html: account.signature)).body
        let draft = ComposeDraft(id: UUID(), mode: .reply(latest.id, all: mode == .replyAll), account: account, to: message.to,
                                 cc: message.cc, bcc: message.bcc, subject: message.subject, body: body,
                                 attachments: [], quoted: nil, threading: ReplyThreading(original: latest, isReply: true))
        do {
            let sendID = try client.send(message, undoWindow: Self.undoWindow)
            let startedAt = Date()
            let endsAt = startedAt.addingTimeInterval(Self.undoWindow)
            let names = (message.to + message.cc).map(\.shortDisplay)
            let recipient = names.count > 2 ? names[0] + " and \(names.count - 1) others" : names.joined(separator: " and ")
            // The store leaves the list on its observation, after this returns: the strip is up before the selection moves.
            let archive = (action ?? SendActionPreference.current).archives
                ? SendArchive.archiveConversation(answering: latest.id, client: client)
                : nil
            quickSend = QuickSend(sendID: sendID, text: text, conversation: conversation,
                                  subject: RenderPayloadBuilder.subject(of: currentMessages), startedAt: startedAt, endsAt: endsAt,
                                  draft: draft, archive: archive)
            onQuickSendChange?()
            quickReply.clear()
            quickReply.showStrip(.counting(endsAt: endsAt, duration: Self.undoWindow, recipient: recipient, archived: archive != nil))
            outboxTick()
            quickSendTimer?.invalidate()
            quickSendTimer = Timer.scheduledTimer(withTimeInterval: Self.undoWindow, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.quickSendWindowEnded() }
            }
            if archive != nil { onQuickSendArchived?() }
        } catch {
            ConversationSignposts.log.error("quick reply send failed: \(String(describing: error), privacy: .public)")
            quickReply.status = .error
        }
    }

    /// A Send Later time from the quick reply's drop-down or ⇧⌘L (nil: Pick a Time…, asked first); internal so the app's
    /// tests can schedule one. The reply waits in the outbox until then and, like a composer's, is kept as a draft on this
    /// Mac that its Drafts row stands in for; the bar clears and the main window says when it sends, with Undo, which puts
    /// the text back in the bar. Nothing is archived: the reply has not gone (§5.23).
    func sendQuickReplyLater(_ text: String, mode: QuickReplyView.Mode, at date: Date?) {
        guard let date else {
            SendLaterPicker.present(view.window) { [weak self] chosen in
                guard let chosen else { return }
                self?.sendQuickReplyLater(text, mode: mode, at: chosen)
            }
            return
        }
        guard let conversation = currentConversationID, let latest = replyTarget(in: currentMessages),
              let account = accountsByID[latest.id.accountID] else { return }
        let message = QuickReplyComposer.outgoingMessage(text: text, replyingTo: latest, accounts: accountsByID, all: mode == .replyAll,
                                                         signature: ComposeSignature.export(html: account.signature))
        guard !message.to.isEmpty else {
            quickReply.status = .noRecipients
            return
        }
        let body = ComposeSignature.startingBody(typed: ComposeTextView.plainBody(text),
                                                 signature: ComposeSignature.body(html: account.signature)).body
        let draft = ComposeDraft(id: UUID(), mode: .reply(latest.id, all: mode == .replyAll), account: account, to: message.to,
                                 cc: message.cc, bcc: message.bcc, subject: message.subject, body: body,
                                 attachments: [], quoted: nil, threading: ReplyThreading(original: latest, isReply: true))
        guard ComposeDraftStore.shared.saveNow(draft) else {
            quickReply.status = .error
            return
        }
        do {
            let sendID = try client.scheduleSend(message, at: date, draftID: draft.id)
            quickReply.clear()
            drafts.park("", under: conversation)
            let client = client
            let shelf = draftShelf
            SendLaterScheduled(sendID: sendID, date: date) { [weak self] in
                guard (try? client.cancelSend(id: sendID)) == true else {
                    NSSound.beep()
                    return
                }
                ComposeDraftStore.shared.remove(id: draft.id)
                if let self, self.currentConversationID != nil {
                    self.restoreUnsentQuickReply(text, under: conversation)
                } else {
                    // Scheduled in a reader window closed since (its reader shows nothing, or has gone): the text waits
                    // under its conversation, as the window's own text does, and the main window hands it to a reader
                    // showing that conversation (`MainWindowController.sendLaterScheduled`).
                    _ = shelf.drafts.restoreUnsent(text, under: conversation, shown: nil)
                }
            }.post(from: self)
        } catch {
            ConversationSignposts.log.error("quick reply schedule failed: \(String(describing: error), privacy: .public)")
            ComposeDraftStore.shared.remove(id: draft.id)
            quickReply.status = .error
        }
    }

    /// A reply scheduled in a reader window that has closed since was taken back, its text parked under `conversation`:
    /// it comes into this box when this reader shows that conversation (true); otherwise this reader's strip says it was
    /// not sent, with Show Draft going to it, when `confirming` (false either way). Nothing shown, nothing changes.
    @discardableResult
    func takeUnsentQuickReply(under conversation: ConversationID, confirming: Bool) -> Bool {
        guard isViewLoaded, let shown = currentConversationID else { return false }
        if shown == conversation {
            takeParkedQuickReply()
            quickReply.focus()
            return true
        }
        if confirming {
            quickSendShown = conversation
            quickReply.showStrip(.notSent(subject: RenderPayloadBuilder.subject(of: (try? client.store.messages(in: conversation)) ?? [])))
        }
        return false
    }

    /// An undone Send Later puts the reply back where it was written: in the bar when its conversation is on screen,
    /// else waiting under that conversation, with the strip saying so.
    private func restoreUnsentQuickReply(_ text: String, under conversation: ConversationID) {
        if drafts.restoreUnsent(text, under: conversation, shown: currentConversationID) {
            let typed = quickReply.text
            quickReply.restoreDraft(typed.isEmpty ? text : text + "\n\n" + typed)
            quickReply.focus()
        } else {
            quickSendShown = conversation
            quickReply.showStrip(.notSent(subject: RenderPayloadBuilder.subject(of: (try? client.store.messages(in: conversation)) ?? [])))
        }
    }

    private var quickSendShown: ConversationID?

    /// The undo window ran out: "Sent", or "Will send when you're back online" while the account is offline.
    private func quickSendWindowEnded() {
        quickSendTimer = nil
        guard let send = quickSend else { return }
        quickSend = nil
        onQuickSendChange?()
        let offline = offlineAccounts.contains(send.conversation.accountID)
        if quickReply.stripState != nil {
            quickReply.showStrip(offline ? .queuedOffline : .sent)
        } else {
            quickReply.status = .none
        }
        watchOutcome(of: send.sendID, draft: send.draft)
    }

    /// Watches a send past its undo window until it leaves, as the undo-send panel does for a composer's.
    private func watchOutcome(of sendID: String, draft: ComposeDraft) {
        watchedSends[sendID] = draft
        outboxTick()
    }

    /// One read of the outbox serves both the watched sends and the pending sheets, on the events that may change them
    /// (a send, a watch, the view loading); the outbox is then followed through the store's observation while either has
    /// something to follow.
    func outboxTick() {
        if let sends = try? client.store.pendingSendSummaries() {
            outboxChanged(sends)
        }
        guard outboxObservation == nil, !isOutboxIdle else { return }
        let observation = client.store.observePendingSends { [weak self] sends in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.outboxChanged(sends) }
            } else {
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.outboxChanged(sends) } }
            }
        }
        // A store that delivers its first value at once may have settled everything already.
        if isOutboxIdle { observation.cancel() } else { outboxObservation = observation }
    }

    /// Whether the reader has nothing in the outbox to follow.
    private var isOutboxIdle: Bool { watchedSends.isEmpty && outbox.isEmpty }

    /// Whether the reader follows the outbox now (tests).
    var followsOutbox: Bool { outboxObservation != nil }

    private func outboxChanged(_ sends: [PendingSendSummary]) {
        settleWatchedSends(sends)
        updateOutbox(sends)
        if isOutboxIdle {
            outboxObservation?.cancel()
            outboxObservation = nil
        }
    }

    /// The tests' name for a tick: a watched send's outcome is read now rather than within the second.
    func pollWatchedSends() {
        outboxTick()
    }

    /// A sent reply's row is gone (or marked sent); a failed one stays with its reason. The failure is kept
    /// as a draft on this Mac before the toast offers to open it, so closing the toast loses nothing.
    private func settleWatchedSends(_ sends: [PendingSendSummary]) {
        guard !watchedSends.isEmpty else { return }
        let byID = Dictionary(sends.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (id, draft) in watchedSends {
            let send = byID[id]
            switch send?.status {
            case nil, .sent?:
                watchedSends[id] = nil
            case .failed?:
                watchedSends[id] = nil
                var kept = draft
                kept.sendFailure = SendFailureWording.banner(lastError: send?.lastError, provider: draft.account.kind)
                ComposeDraftStore.shared.save(kept)
                onAction?(.quickReplyFailed(kept))
            case .scheduled?, .sending?, .later?, .missed?:
                // A quick reply sent now is never `later` or `missed`; those are Send Later's, which `SendLaterOutbox` follows.
                break
            }
        }
    }

    /// The replies on their way changed: the open conversation gains or loses its pending sheets.
    private func updateOutbox(_ sends: [PendingSendSummary]) {
        let leaving = sends.filter { ($0.status == .scheduled || $0.status == .sending) && !$0.isForward && $0.inReplyTo != nil }
        guard leaving.map(\.id) != outbox.map(\.id) else { return }
        outbox = leaving
        if case .one(let id) = selection, !currentMessages.isEmpty { refreshCurrentIfStale(currentMessages, id: id) }
    }

    /// The pending sheets answering `messages` (spec §5.14).
    private func pendingSheets(answering messages: [MessageMetadata]) -> [PendingSheet] {
        outbox.isEmpty ? [] : PendingSheet.sheets(for: outbox, answering: messages, accounts: accountsByID)
    }

    /// The pending sheets of the open conversation (tests).
    var pendingSheetIDs: [MessageID] { pendingSheets(answering: currentMessages).map(\.metadata.id) }

    /// Quick replies past their window whose outcome is still being watched (tests).
    var watchedSendIDs: Set<String> { Set(watchedSends.keys) }

    /// ⌘Z while a quick reply is inside its undo window cancels it, wherever the selection is. False when no
    /// quick reply is waiting, so the key goes on to the toast's undo.
    func cancelQuickSend() -> Bool {
        guard quickSend != nil else { return false }
        undoQuickSend()
        return true
    }

    /// Undo can arrive after the selection moved on; the text then waits under the thread it was written for.
    private func undoQuickSend() {
        guard let send = quickSend else { return }
        quickSendTimer?.invalidate()
        quickSendTimer = nil
        quickSend = nil
        onQuickSendChange?()
        let cancelled = (try? client.cancelSend(id: send.sendID)) ?? false
        outboxTick()
        guard cancelled else {
            quickReply.showStrip(.alreadySent)
            return
        }
        if let archive = send.archive {
            // Back in the Inbox and selected again, as Z after E leaves it; a show the debounce holds lands now, so the text
            // goes back into its own conversation's box below rather than being parked.
            archive.revert()
            if pendingShow?.id == send.conversation { flushPendingShow() }
        }
        if drafts.restoreUnsent(send.text, under: send.conversation, shown: currentConversationID) {
            quickReply.hideStrip()
            quickReply.status = .none
            // Anything typed since the send belongs to the same thread, so it is kept below the unsent text.
            let typed = quickReply.text
            quickReply.restoreDraft(typed.isEmpty ? send.text : send.text + "\n\n" + typed)
            quickReply.focus()
        } else {
            quickSendShown = send.conversation
            quickReply.status = .none
            quickReply.showStrip(.notSent(subject: send.subject))
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleKey(event) else { return event }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// The reader's own keys (spec §6): N and P move through the messages, "." shows or hides quoted text,
    /// ⇧⌘I loads images and ⇧⌘O switches Original colors on the target, and Space previews its attachments
    /// (or, on a focused elision mark, goes on to press it). None of them fire while a text field has focus.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = view.window, window.isKeyWindow, event.window === window,
              !KeyboardRouter.isTextInput(window.firstResponder) else { return false }
        let chord = ReaderShortcuts.chord(event.modifierFlags.rawValue)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if ReaderShortcuts.isPlainSpace(charactersIgnoringModifiers: event.charactersIgnoringModifiers, rawModifierFlags: event.modifierFlags.rawValue) {
            guard let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) else { return false }
            // A focused find-bar button takes Space as any button does.
            if let bar = find.bar, responder.isDescendant(of: bar) { return false }
            Quire.Motion.finishAll()
            return openQuickLookForSelectedMessage()
        }
        guard case .one = selection, let current = pool.current, !webContainer.isHidden else { return false }
        if chord == 0 {
            switch key {
            case "n", "p":
                Quire.Motion.finishAll()
                step(key == "n" ? 1 : -1, in: current)
                return true
            case ".":
                Quire.Motion.finishAll()
                evaluate("window.ss.toggleQuotes()", in: current)
                return true
            default:
                return false
            }
        }
        if chord == ReaderShortcuts.shift | ReaderShortcuts.command {
            switch key {
            case "i":
                Quire.Motion.finishAll()
                evaluate("window.ss.loadImages(null)", in: current)
                return true
            case "o":
                Quire.Motion.finishAll()
                evaluate("window.ss.toggleOriginal()", in: current)
                return true
            default:
                return false
            }
        }
        return false
    }

    private func step(_ delta: Int, in slot: PooledConversationView) {
        slot.webView.evaluateJavaScript("window.ss.step(\(delta))") { [weak self] result, _ in
            guard let self, let key = result as? String, let id = RenderPayload.messageID(fromKey: key) else { return }
            self.selectedMessageID = id
        }
    }

    // MARK: Menu commands

    @objc func nextMessage(_ sender: Any?) {
        guard let current = pool.current else { return }
        step(1, in: current)
    }

    @objc func previousMessage(_ sender: Any?) {
        guard let current = pool.current else { return }
        step(-1, in: current)
    }

    @objc func toggleQuotedText(_ sender: Any?) {
        guard let current = pool.current else { return }
        evaluate("window.ss.toggleQuotes()", in: current)
    }

    @objc func loadImages(_ sender: Any?) {
        guard let current = pool.current else { return }
        evaluate("window.ss.loadImages(null)", in: current)
    }

    @objc func toggleOriginalColors(_ sender: Any?) {
        guard let current = pool.current else { return }
        evaluate("window.ss.toggleOriginal()", in: current)
    }

    /// Edit › Find in Conversation… ⌥⌘F (spec §5.50). ⌘F stays the list's search.
    @objc func findInConversation(_ sender: Any?) {
        guard showsOneConversation else { return }
        find.open()
    }

    /// Edit › Find Next ⌘G: the next match, or with the bar closed the kept query found again.
    @objc func findNextMatch(_ sender: Any?) {
        guard showsOneConversation else { return }
        find.step(1)
    }

    /// Edit › Find Previous ⇧⌘G.
    @objc func findPreviousMatch(_ sender: Any?) {
        guard showsOneConversation else { return }
        find.step(-1)
    }

    /// Esc while the find bar is open and the keyboard is in the reader (§6.1): the bar closes and the page keeps the
    /// keyboard. False when there is no bar to close.
    func closeFindForEscape() -> Bool {
        guard find.isOpen else { return false }
        find.close(returningFocus: true)
        return true
    }

    /// The slot on screen once it holds the selected conversation. While the selection's show waits, or its render lands
    /// in another slot, the page on screen is the conversation being left, which the find bar never searches.
    private var searchableSlot: PooledConversationView? {
        guard case .one(let id) = selection, id == currentConversationID, let current = pool.current, current.renderedID == id else {
            return nil
        }
        return current
    }

    private var showsOneConversation: Bool {
        guard case .one = selection else { return false }
        return pool.current != nil && !webContainer.isHidden
    }

    /// File › Save Attachments… (spec §5.35): the target message's attachments, copied into a folder the user
    /// picks (Downloads to start with), then shown in the Finder. A file that cannot be fetched marks its chip
    /// “Couldn't download · Retry”, as a failed Quick Look does.
    @objc func saveAttachments(_ sender: Any?) {
        guard let messageID = attachmentTarget, let window = view.window else { return }
        let infos = attachments(of: messageID)
        guard !infos.isEmpty else {
            NSSound.beep()
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save"
        panel.message = infos.count == 1 ? "Choose a folder for the attachment." : "Choose a folder for the \(infos.count) attachments."
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let folder = panel.url, let self else { return }
                self.save(infos, of: messageID, into: folder)
            }
        }
    }

    private func save(_ infos: [AttachmentInfo], of messageID: MessageID, into folder: URL) {
        Task { [weak self] in
            guard let self else { return }
            let outcome = await AttachmentSaver.save(infos, into: folder, fetch: { info, _ in
                await self.preview.file(for: info, of: messageID)
            }, unfetched: { info in
                self.setAttachmentFailed(true, info.id, of: messageID)
            })
            if outcome.saved.isEmpty {
                NSSound.beep()
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(outcome.saved)
            }
        }
    }

    /// File › Download Attachments (⇧⌘D, spec §5.17): the target message's files to Downloads, as Download all saves
    /// them; on a message with one file, that chip's Download.
    @objc func downloadAttachments(_ sender: Any?) {
        guard let messageID = attachmentTarget, !attachments(of: messageID).isEmpty else { return NSSound.beep() }
        downloadAllAttachments(of: messageID)
    }

    /// File › Print… (spec §5.48): the open conversation's sheets, every message open, as the reader shows each one. The
    /// shell is asked first what it shows (images loaded, quoted text and the message under a card unfolded); the payload is
    /// built again from the store, as a render builds it, so the printout has every body whether or not its card was ever
    /// opened. The print panel follows as a sheet once the printout's images are in.
    @objc func printConversation(_ sender: Any?) {
        guard case .one(let id) = selection, let current = pool.current, current.renderedID == id, let window = view.window,
              !printer.isBusy else {
            NSSound.beep()
            return
        }
        let messages = currentMessages
        let printWith: (Any?) -> Void = { [weak self] states in
            guard let self, self.currentConversationID == id, !self.printer.isBusy else { return }
            let payload = self.prepare(messages).payload
            let sheets = PrintSheetState.states(fromShell: states, loadRemoteImages: payload.loadRemoteImages)
            let document = PrintDocumentBuilder(imageWait: Quire.Motion.printImageWait).document(for: payload, sheets: sheets)
            self.printer.print(document, title: PrintDocumentBuilder.title(of: payload), imageWait: Quire.Motion.printImageWait, on: window)
        }
        // A shell still loading has shown nothing yet: the conversation prints as it opens.
        guard current.isReady else { return printWith(nil) }
        current.webView.evaluateJavaScript("window.ss.cardStates()") { result, _ in
            MainActor.assumeIsolated { printWith(result) }
        }
    }

    /// The message Save Attachments… acts on: the target message (spec §5.14).
    private var attachmentTarget: MessageID? {
        guard case .one = selection else { return nil }
        return selectedMessageID ?? currentMessages.last?.id
    }

    /// The reader's commands apply to one shown conversation; Original Colors carries a checkmark while the
    /// target message shows the sender's colours (spec §5.16); Save Attachments… needs files to save. Disabled
    /// items stay in their menus (§5.35).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let showsOne: Bool
        if case .one = selection { showsOne = pool.current != nil && !webContainer.isHidden } else { showsOne = false }
        switch menuItem.action {
        case #selector(toggleOriginalColors(_:)):
            menuItem.state = selectedMessageID.map(originalColorsShown.contains) == true ? .on : .off
            return showsOne
        case #selector(nextMessage(_:)), #selector(previousMessage(_:)), #selector(toggleQuotedText(_:)), #selector(loadImages(_:)),
             #selector(findInConversation(_:)):
            return showsOne
        case #selector(findNextMatch(_:)), #selector(findPreviousMatch(_:)):
            return showsOne && find.canStep
        case #selector(saveAttachments(_:)), #selector(downloadAttachments(_:)):
            return attachmentTarget.map { !attachments(of: $0).isEmpty } ?? false
        case #selector(printConversation(_:)):
            // One printout at a time: Print… waits while one is prepared or its panel is up (§5.48).
            return showsOne && !printer.isBusy
        default:
            return true
        }
    }

    // MARK: Helpers

    private func evaluate(_ script: String, in slot: PooledConversationView) {
        guard slot.isReady else { return }
        slot.webView.evaluateJavaScript(script) { _, error in
            if let error {
                ConversationSignposts.log.error("shell call failed: \(String(describing: error), privacy: .public)")
            }
        }
    }
}

/// The reader's root view: the `canvas` desk behind the sheets and the empty states (spec §4.1), and the end
/// of a resize, when wide HTML is refitted: a live one (window or split divider) when it ends, any other (the
/// rail shown or hidden, zoom, full screen) once the run loop has settled the new width.
@MainActor
final class ReaderRootView: NSView {
    var onEndLiveResize: (() -> Void)?
    private var settleTimer: Timer?
    /// How long a width must hold before a resize outside a live resize counts as ended: an animated rail
    /// toggle moves the width every frame, and the fit is recomputed once, not per frame (spec §5.14).
    private static let settleDelay: TimeInterval = 0.15

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Increase Contrast and Graphite change `canvas` without changing the appearance.
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    @objc private func environmentDidChange(_ note: Notification) {
        needsDisplay = true
    }

    override var isOpaque: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        guard widthChanged, !inLiveResize, window != nil else { return }
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: Self.settleDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.settleTimer = nil
                if !self.inLiveResize { self.onEndLiveResize?() }
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qCanvas.setFill()
        bounds.intersection(dirtyRect).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        onEndLiveResize?()
    }
}

/// Finishes the shell's running height animations when a key press calls `Quire.Motion.finishAll()`.
@MainActor
final class ShellMotionFinisher: QuireAnimator {
    private weak var slot: PooledConversationView?

    init(slot: PooledConversationView) {
        self.slot = slot
    }

    func finishAnimation() {
        guard let slot, slot.isReady else { return }
        slot.webView.evaluateJavaScript("window.ss && window.ss.finishAll()") { _, _ in }
    }
}
