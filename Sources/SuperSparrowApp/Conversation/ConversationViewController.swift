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
    private(set) var currentMessages: [MessageMetadata] = []
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

    private let pool: WebViewPool
    private let preview: AttachmentPreviewController
    private let builder = RenderPayloadBuilder()
    private let header = ReaderHeaderView()
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
    /// Messages the shell shows in Original colors this session, for View › Original Colors' checkmark.
    private var originalColorsShown: Set<MessageID> = []
    private var drafts = QuickReplyDrafts()
    private var quickSend: QuickSend?
    private var quickSendTimer: Timer?
    /// Quick replies whose undo window has ended, watched until they leave: a failure then becomes the error
    /// toast of §5.18 (“Couldn't send your reply · Open draft”). Keyed by send id.
    private var watchedSends: [String: ComposeDraft] = [:]
    /// Replies on their way out (scheduled or sending, not forwards): the open conversation shows the ones that
    /// answer it as pending sheets (spec §5.14). Read on events and on each outbox tick, never per selection.
    private var outbox: [PendingSend] = []
    /// Ticks once a second while a send is watched or a reply is on its way; the store has no observation for
    /// the outbox.
    private var outboxTimer: Timer?
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
    }

    /// Called whenever a quick reply's undo window opens or closes, so the main window can re-rank ⌘Z (§6.1).
    var onQuickSendChange: (() -> Void)?

    /// The quick reply's send while ⌘Z can still cancel it.
    var liveQuickSend: UndoPrecedence.LiveSend? {
        quickSend.map { UndoPrecedence.LiveSend(id: $0.sendID, startedAt: $0.startedAt) }
    }

    init(client: MailClient) {
        self.client = client
        self.pool = WebViewPool(client: client)
        self.preview = AttachmentPreviewController(client: client)
        var accounts: [AccountID: Account] = [:]
        for account in (try? client.accounts()) ?? [] { accounts[account.id] = account }
        self.accountsByID = accounts
        super.init(nibName: nil, bundle: nil)
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
        outboxTimer?.invalidate()
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
        quickReply.onSend = { [weak self] text, mode in self?.sendQuickReply(text, mode: mode) }
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
            drafts.park(quickReply.text, under: id)
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
        pool.render(prepared.payload, inputs: prepared.inputs, id: id, into: slot)
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
                               remaining: remaining, startedAt: send.startedAt)
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

    /// The shell pads the conversation by the bar's height + 12, once per height change (spec §8.4).
    private func applyBottomInset() {
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
        let payload = builder.build(
            messages: all, bodies: bodies, accounts: accountsByID, bodyStates: states,
            loadRemoteImages: Self.loadRemoteImages, readingSans: settings.readingFont == .sfPro,
            colorsNoticeDismissed: settings.originalColorsNoticeDismissed, pending: Set(sheets.map(\.metadata.id))
        )
        return (payload, RenderInputs(messages: all) { bodies[$0] != nil })
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
        applyMessages(visible, for: id)
        // Emptied while open (its last message deleted or moved elsewhere): the desk says so (spec §5.9).
        guard !visible.isEmpty else { return }
        refreshCurrentIfStale(visible, id: id)
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

    /// When the connection returns, bodies that waited for it start by themselves (spec §5.14).
    private func statusesChanged(_ statuses: [AccountSyncStatus]) {
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

    /// Reading font and the colours notice change what bodies look like, never what they hold: every shell is
    /// told in place, and the payloads built from now on carry the new values.
    private func displayPreferencesDidChange() {
        broadcastPreferences()
    }

    private func broadcastPreferences() {
        let settings = AppSettings.shared
        let sans = settings.readingFont == .sfPro
        pool.broadcast("window.ss && window.ss.preferences({readingSans: \(sans), colorsNoticeDismissed: \(settings.originalColorsNoticeDismissed)})")
    }

    /// Wide HTML is refitted once a live resize ends, never per frame (spec §5.14).
    private func liveResizeEnded() {
        guard let current = pool.current else { return }
        evaluate("window.ss && window.ss.refit()", in: current)
    }

    // MARK: Shell messages

    private func handle(_ message: ConversationScriptMessage, from slot: PooledConversationView) {
        guard slot === pool.current else { return }
        switch message {
        case .ready:
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
        case let .action(type, messageID, attachmentID, on, point):
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
            case "continueDraft":
                onAction?(.continueDraft(messageID))
            case "discardDraft":
                if let id = currentConversationID { onAction?(.discardDrafts([id])) }
            default:
                ConversationSignposts.log.debug("unknown shell action \(type, privacy: .public)")
            }
        }
    }

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
            let state = result as? [String: Any] ?? [:]
            let message = self.currentMessages.first { $0.id == id }
            let options = MessageMoreMenu.Options(
                isStarred: message?.isStarred ?? false,
                imagesBlocked: state["imagesBlocked"] as? Bool ?? false,
                offersOriginal: state["offersOriginal"] as? Bool ?? false,
                showsOriginal: state["original"] as? Bool ?? false,
                hasSenderAddress: !(message?.from?.address ?? "").isEmpty
            )
            self.moreMenu.menu(options).popUp(positioning: nil, at: point, in: slot.webView)
        }
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
        case .copySenderAddress:
            guard let address = currentMessages.first(where: { $0.id == id })?.from?.address else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(address, forType: .string)
        }
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
        var parts = messageID.flatMap { (try? client.store.body(for: $0))?.body.attachments } ?? []
        if let focused = focusedAttachment, focused.message == messageID,
           let index = parts.firstIndex(where: { $0.id == focused.attachment }) {
            parts.insert(parts.remove(at: index), at: 0)
        }
        switch ReaderShortcuts.spaceOutcome(previewVisible: preview.isPanelVisible, attachments: parts) {
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

    private func attachments(of messageID: MessageID) -> [AttachmentInfo] {
        ((try? client.store.body(for: messageID))?.body.attachments ?? []).filter { !$0.isInline }
    }

    private func openAttachment(id attachmentID: String, of messageID: MessageID) {
        guard let info = attachments(of: messageID).first(where: { $0.id == attachmentID }) else { return }
        openAttachment(info, of: messageID)
    }

    private func openAttachment(_ info: AttachmentInfo, of messageID: MessageID) {
        onAction?(.openAttachment(messageID, info))
        let siblings = attachments(of: messageID)
        setAttachmentFailed(false, info.id, of: messageID)
        let shown = showDownloadSoon(info.id, of: messageID)
        Task { [weak self] in
            guard let self else { return }
            let opened = await self.preview.preview(info, of: messageID, siblings: siblings) { [weak self] in
                shown.cancel()
                self?.setAttachmentProgress(.done, info.id, of: messageID)
            }
            if !opened { self.setAttachmentFailed(true, info.id, of: messageID) }
        }
    }

    /// What a chip's download shows (spec §5.17): the engine reports no byte counts yet, so a fetch sweeps the
    /// contrail; `fraction` is ready for a provider that does.
    enum AttachmentProgress: Equatable {
        case sweeping
        case fraction(Double)
        case done
    }

    /// The chip shows its download only once the fetch outlasts a cached file (150 ms, as spinners wait), so
    /// opening a file already on this Mac never flashes it.
    private func showDownloadSoon(_ attachmentID: String, of messageID: MessageID) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.setAttachmentProgress(.sweeping, attachmentID, of: messageID)
        }
    }

    private func setAttachmentProgress(_ progress: AttachmentProgress, _ attachmentID: String, of messageID: MessageID) {
        guard let current = pool.current, currentMessages.contains(where: { $0.id == messageID }) else { return }
        let key = ConversationShellAssets.jsStringLiteral(RenderPayload.messageKey(for: messageID))
        let value: String
        switch progress {
        case .sweeping: value = "null"
        case .fraction(let fraction): value = String(max(0, min(1, fraction)))
        case .done: value = "-1"
        }
        evaluate("window.ss && window.ss.attachmentProgress(\(key), \(ConversationShellAssets.jsStringLiteral(attachmentID)), \(value))",
                 in: current)
    }

    private func performAttachment(_ command: AttachmentMenu.Command) {
        guard let target = menuAttachment else { return }
        performAttachment(command, target.attachment, of: target.message)
    }

    /// The chip's commands (spec §5.17). Each one fetches the file first, once per session; a failed fetch marks
    /// the chip, as a failed Quick Look does.
    private func performAttachment(_ command: AttachmentMenu.Command, _ attachmentID: String, of messageID: MessageID) {
        guard let info = attachments(of: messageID).first(where: { $0.id == attachmentID }) else { return }
        if command == .quickLook {
            openAttachment(info, of: messageID)
            return
        }
        setAttachmentFailed(false, info.id, of: messageID)
        let window = view.window
        let shown = showDownloadSoon(info.id, of: messageID)
        Task { [weak self] in
            guard let self else { return }
            let fetched = await self.preview.file(for: info, of: messageID)
            shown.cancel()
            self.setAttachmentProgress(.done, info.id, of: messageID)
            guard let file = fetched else {
                self.setAttachmentFailed(true, info.id, of: messageID)
                return
            }
            switch command {
            case .quickLook:
                break
            case .open:
                self.open(file, in: window)
            case .saveToDownloads:
                guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { return }
                if let saved = Self.copy(file, into: downloads) {
                    NSWorkspace.shared.activateFileViewerSelecting([saved])
                } else {
                    NSSound.beep()
                }
            case .saveAs:
                let panel = NSSavePanel()
                panel.nameFieldStringValue = file.lastPathComponent
                let save: (NSApplication.ModalResponse) -> Void = { response in
                    guard response == .OK, let destination = panel.url else { return }
                    do {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.copyItem(at: file, to: destination)
                    } catch {
                        Self.logSaveFailure(error)
                        NSSound.beep()
                    }
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

    /// A Cocoa file error names the attachment and its path, which are message content: only the domain and
    /// code are public.
    private static func logSaveFailure(_ error: Error) {
        let failure = error as NSError
        ConversationSignposts.log.error("saving an attachment failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
        ConversationSignposts.log.debug("saving an attachment failed: \(String(describing: error), privacy: .private)")
    }

    /// Copies `file` into `folder` under its own name, numbered like the Finder ("plan 2.pdf") when taken.
    private static func copy(_ file: URL, into folder: URL) -> URL? {
        let manager = FileManager.default
        let base = file.deletingPathExtension().lastPathComponent
        let ext = file.pathExtension
        for index in 1...999 {
            let name = index == 1 ? file.lastPathComponent : base + " \(index)" + (ext.isEmpty ? "" : "." + ext)
            let destination = folder.appendingPathComponent(name)
            guard !manager.fileExists(atPath: destination.path) else { continue }
            do {
                try manager.copyItem(at: file, to: destination)
                return destination
            } catch {
                logSaveFailure(error)
                return nil
            }
        }
        return nil
    }

    /// "Couldn't download · Retry" on the chip (spec §5.17); opening it again is the retry.
    private func setAttachmentFailed(_ failed: Bool, _ attachmentID: String, of messageID: MessageID) {
        guard let current = pool.current, currentMessages.contains(where: { $0.id == messageID }) else { return }
        let key = ConversationShellAssets.jsStringLiteral(RenderPayload.messageKey(for: messageID))
        evaluate("window.ss && window.ss.attachmentFailed(\(key), \(ConversationShellAssets.jsStringLiteral(attachmentID)), \(failed))", in: current)
    }

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

    /// Esc in the quick reply: the main window decides (§6.1 rows 6–7). Without one the field lets go and the
    /// web view takes focus.
    private func quickReplyEscape() {
        if let onAction {
            onAction(.escapeQuickReply)
        } else {
            quickReply.blur()
            focusWebView()
        }
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
        if let id = currentConversationID { drafts.park("", under: id) }
        quickReply.isComposerOpen = replyComposer(for: currentMessages) != nil
    }

    /// ⌘↩ in the quick reply; internal so the app's tests can send one.
    func sendQuickReply(_ text: String, mode: QuickReplyView.Mode) {
        guard let conversation = currentConversationID, let latest = replyTarget(in: currentMessages),
              let account = accountsByID[latest.id.accountID] else { return }
        let message = QuickReplyComposer.outgoingMessage(text: text, replyingTo: latest, accounts: accountsByID, all: mode == .replyAll)
        guard !message.to.isEmpty else {
            quickReply.status = .noRecipients
            return
        }
        let draft = ComposeDraft(id: UUID(), mode: .reply(latest.id, all: mode == .replyAll), account: account, to: message.to,
                                 cc: message.cc, bcc: message.bcc, subject: message.subject, body: NSAttributedString(string: text),
                                 attachments: [], quoted: nil, threading: ReplyThreading(original: latest, isReply: true))
        do {
            let sendID = try client.send(message, undoWindow: Self.undoWindow)
            let startedAt = Date()
            let endsAt = startedAt.addingTimeInterval(Self.undoWindow)
            let names = (message.to + message.cc).map(\.shortDisplay)
            let recipient = names.count > 2 ? names[0] + " and \(names.count - 1) others" : names.joined(separator: " and ")
            quickSend = QuickSend(sendID: sendID, text: text, conversation: conversation,
                                  subject: RenderPayloadBuilder.subject(of: currentMessages), startedAt: startedAt, endsAt: endsAt,
                                  draft: draft)
            onQuickSendChange?()
            quickReply.clear()
            quickReply.showStrip(.counting(endsAt: endsAt, duration: Self.undoWindow, recipient: recipient))
            outboxTick()
            quickSendTimer?.invalidate()
            quickSendTimer = Timer.scheduledTimer(withTimeInterval: Self.undoWindow, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.quickSendWindowEnded() }
            }
        } catch {
            ConversationSignposts.log.error("quick reply send failed: \(String(describing: error), privacy: .public)")
            quickReply.status = .error
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

    /// One read of the outbox serves both the watched sends and the pending sheets; the timer runs only while
    /// either has something to follow.
    func outboxTick() {
        if let sends = try? client.store.pendingSends() {
            settleWatchedSends(sends)
            updateOutbox(sends)
        }
        if watchedSends.isEmpty, outbox.isEmpty {
            outboxTimer?.invalidate()
            outboxTimer = nil
        } else if outboxTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
                MainActor.assumeIsolated {
                    guard let self else { return timer.invalidate() }
                    self.outboxTick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            outboxTimer = timer
        }
    }

    /// The tests' name for a tick: a watched send's outcome is read now rather than within the second.
    func pollWatchedSends() {
        outboxTick()
    }

    /// A sent reply's row is gone (or marked sent); a failed one stays with its reason. The failure is kept
    /// as a draft on this Mac before the toast offers to open it, so closing the toast loses nothing.
    private func settleWatchedSends(_ sends: [PendingSend]) {
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
            case .scheduled?, .sending?:
                break
            }
        }
    }

    /// The replies on their way changed: the open conversation gains or loses its pending sheets.
    private func updateOutbox(_ sends: [PendingSend]) {
        let leaving = sends.filter { ($0.status == .scheduled || $0.status == .sending) && !$0.message.isForward && $0.message.inReplyTo != nil }
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
    /// ⇧⌘I loads images and ⇧⌘O switches Original colors on the target, and Space previews its attachments.
    /// None of them fire while a text field has focus.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window = view.window, window.isKeyWindow, event.window === window,
              !KeyboardRouter.isTextInput(window.firstResponder) else { return false }
        let chord = ReaderShortcuts.chord(event.modifierFlags.rawValue)
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if ReaderShortcuts.isPlainSpace(charactersIgnoringModifiers: event.charactersIgnoringModifiers, rawModifierFlags: event.modifierFlags.rawValue) {
            guard let responder = window.firstResponder as? NSView, responder.isDescendant(of: view) else { return false }
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
            var saved: [URL] = []
            for info in infos {
                guard let file = await self.preview.file(for: info, of: messageID) else {
                    self.setAttachmentFailed(true, info.id, of: messageID)
                    continue
                }
                if let copy = Self.copy(file, into: folder) { saved.append(copy) }
            }
            if saved.isEmpty {
                NSSound.beep()
            } else {
                NSWorkspace.shared.activateFileViewerSelecting(saved)
            }
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
        case #selector(nextMessage(_:)), #selector(previousMessage(_:)), #selector(toggleQuotedText(_:)), #selector(loadImages(_:)):
            return showsOne
        case #selector(saveAttachments(_:)):
            return attachmentTarget.map { !attachments(of: $0).isEmpty } ?? false
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
