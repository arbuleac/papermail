import AppKit
import QuickLookUI
import SSCore
import WebKit
import os

/// The conversation reader: header, pooled web view, docked quick reply.
///
/// Reads only from `client.store`; every command goes through `onAction` or `MailClient`. Opening a
/// conversation is a view swap when it was pre-rendered, otherwise one `ss.render` into a free slot.
@MainActor
final class ConversationViewController: NSViewController {
    let client: MailClient
    /// Used for "me" in recipient lists and to pick reply recipients. Seeded from the client, kept by the owner.
    var accountsByID: [AccountID: Account]
    var onAction: ((ConversationAction) -> Void)?

    private(set) var currentConversationID: ConversationID?
    private(set) var currentMessages: [MessageMetadata] = []
    /// The card the user last clicked, defaulting to the latest message; Space and r/a/f act on it.
    private(set) var selectedMessageID: MessageID?

    private static let showDebounce: TimeInterval = 0.03
    /// Pre-rendering neighbours costs a store read, a payload build and a render per slot; while `j` is
    /// held each one would be evicted unseen by the next repeat, so it waits for the selection to rest.
    private static let prerenderDelay: TimeInterval = 0.15
    private static let markReadDelay: TimeInterval = 0.5
    /// Seconds a quick reply is held for undo. The shell sets it from the "Undo send" preference.
    static var undoWindow: TimeInterval = 5
    /// The "Load remote images" preference, set by `AppSettings`; a change posts `remoteImagesPolicyChanged`.
    static var loadRemoteImages = false
    static let remoteImagesPolicyChanged = Notification.Name("SSRemoteImagesPolicyChanged")

    private let pool: WebViewPool
    private let preview: AttachmentPreviewController
    private let builder = RenderPayloadBuilder()
    private let header = ConversationHeaderView()
    private let webContainer = NSView()
    private let quickReply = QuickReplyView()
    private let emptyLabel = NSTextField(labelWithString: "No conversation selected")

    private var observation: StoreObservation?
    private var showTimer: Timer?
    private var prerenderTimer: Timer?
    private var pendingShow: (id: ConversationID, messages: [MessageMetadata])?
    private var lastShowAt: TimeInterval = -.infinity
    private var markReadTimer: Timer?
    private var bodyFetches: Set<MessageID> = []
    private var drafts = QuickReplyDrafts()
    private var keyMonitor: Any?
    private var showSignpost: OSSignpostIntervalState?

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
        NotificationCenter.default.addObserver(forName: Self.remoteImagesPolicyChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.remoteImagesPolicyDidChange() }
        }
    }

    /// Everything rendered under the old preference is stale: pre-rendered slots are dropped and the
    /// conversation on screen is rendered again, so turning images off stops them at once.
    private func remoteImagesPolicyDidChange() {
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
        showTimer?.invalidate()
        prerenderTimer?.invalidate()
        markReadTimer?.invalidate()
    }

    // MARK: View

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true
        root.translatesAutoresizingMaskIntoConstraints = false

        webContainer.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = NSFont.systemFont(ofSize: 15)
        emptyLabel.alignment = .center

        root.addSubview(header)
        root.addSubview(webContainer)
        root.addSubview(quickReply)
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webContainer.topAnchor.constraint(equalTo: header.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: quickReply.topAnchor),
            quickReply.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            quickReply.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            quickReply.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
        ])

        header.onArchive = { [weak self] in
            guard let self, let id = self.currentConversationID else { return }
            self.onAction?(.archive(id))
        }
        header.onToggleStar = { [weak self] in
            guard let self, let id = self.currentConversationID else { return }
            self.onAction?(.star(id, !self.header.isStarred))
        }
        header.onTrash = { [weak self] in
            guard let self, let id = self.currentConversationID else { return }
            self.onAction?(.trash(id))
        }
        quickReply.onSend = { [weak self] text in self?.sendQuickReply(text) }
        quickReply.onEscape = { [weak self] in self?.focusWebView() }

        view = root
        showEmptyState()
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
            showEmptyState()
            return
        }
        // One metadata read serves the header now and the show that follows; the observation set up
        // by the show brings anything that changes in between.
        let messages = visibleMessages(for: id)
        header.subject = RenderPayloadBuilder.subject(of: messages)
        header.isHidden = false
        emptyLabel.isHidden = true
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
        }
        currentConversationID = id
        preview.closePanel()
        // The "Sent · Undo" strip stays up: its own timer ends the undo window, not the selection.

        applyMessages(messages, for: id)
        present(id, messages: messages)
        observe(id)
        scheduleMarkRead(for: id)
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

    private func showEmptyState() {
        if let id = currentConversationID {
            drafts.park(quickReply.text, under: id)
        }
        currentConversationID = nil
        currentMessages = []
        selectedMessageID = nil
        observation?.cancel()
        observation = nil
        markReadTimer?.invalidate()
        markReadTimer = nil
        preview.closePanel()
        quickReply.clear()
        if let current = pool.current {
            current.webView.removeFromSuperview()
            pool.current = nil
        }
        header.isHidden = true
        webContainer.isHidden = true
        quickReply.isHidden = true
        emptyLabel.isHidden = false
    }

    private func swap(in slot: PooledConversationView) {
        webContainer.isHidden = false
        quickReply.isHidden = false
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
        if let state = showSignpost {
            ConversationSignposts.end(ConversationSignposts.show, state)
            showSignpost = nil
        }
    }

    private func slotWasRecreated(_ slot: PooledConversationView) {
        // A waiter released by the reset may already have re-rendered the current conversation into it.
        guard slot === pool.current, let id = currentConversationID, slot.renderedID != id else { return }
        let prepared = prepare(visibleMessages(for: id))
        pool.render(prepared.payload, inputs: prepared.inputs, id: id, into: slot)
    }

    // MARK: Store

    private func visibleMessages(for id: ConversationID) -> [MessageMetadata] {
        RenderPayloadBuilder.visibleMessages((try? client.store.messages(in: id)) ?? [])
    }

    /// The payload for one render and the inputs it was built from. The only place bodies are read in bulk.
    private func prepare(_ messages: [MessageMetadata]) -> (payload: RenderPayload, inputs: RenderInputs) {
        var bodies: [MessageID: StoredBody] = [:]
        for message in messages {
            if let body = try? client.store.body(for: message.id) { bodies[message.id] = body }
        }
        let payload = builder.build(messages: messages, bodies: bodies, accounts: accountsByID, loadRemoteImages: Self.loadRemoteImages)
        return (payload, RenderInputs(messages: messages) { bodies[$0] != nil })
    }

    private func applyMessages(_ messages: [MessageMetadata], for id: ConversationID) {
        currentMessages = messages
        header.subject = RenderPayloadBuilder.subject(of: messages)
        header.isStarred = messages.contains(where: \.isStarred)
        if let selected = selectedMessageID, messages.contains(where: { $0.id == selected }) {
            // Keep the user's pick across refreshes of the same conversation.
        } else {
            selectedMessageID = messages.last?.id
        }
        if let latest = messages.last {
            quickReply.placeholderName = QuickReplyComposer.replyTargetName(for: latest, accounts: accountsByID)
        } else {
            quickReply.placeholderName = ""
        }
    }

    private func observe(_ id: ConversationID) {
        observation?.cancel()
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
        let fresh = rendered.refreshed(with: messages) { [client] id in
            (try? client.store.body(for: id)) != nil
        }
        guard fresh != rendered else { return }
        // Mark-read and star are the common changes; they patch the headers without reading a body.
        if let patches = rendered.flagPatches(to: fresh), pool.patchFlags(patches, inputs: fresh, id: id, in: slot) {
            return
        }
        let prepared = prepare(messages)
        pool.refresh(prepared.payload, inputs: prepared.inputs, id: id, into: slot)
    }

    /// Fetches bodies the slot rendered without; `rendered` says which ones it had, so those are never looked up.
    private func requestMissingBodies(_ messages: [MessageMetadata], rendered: RenderInputs?) {
        for message in messages where bodyFetches.contains(message.id) == false {
            if rendered?.hasBody(message.id) == true { continue }
            guard (try? client.store.body(for: message.id)) == nil else { continue }
            bodyFetches.insert(message.id)
            let client = self.client
            Task { [weak self] in
                _ = try? await client.ensureBody(for: message.id)
                guard let self else { return }
                self.bodyFetches.remove(message.id)
                guard self.currentConversationID == message.conversationID else { return }
                self.refreshCurrentIfStale(self.currentMessages, id: message.conversationID)
            }
        }
    }

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

    // MARK: Shell messages

    private func handle(_ message: ConversationScriptMessage, from slot: PooledConversationView) {
        guard slot === pool.current else { return }
        switch message {
        case .ready:
            break
        case .select(let id):
            selectedMessageID = id
        case .openLink(let url):
            if let scheme = url.scheme?.lowercased(), ConversationNavigationPolicy.isOpenableExternally(scheme) {
                NSWorkspace.shared.open(url)
            }
        case .action(let type, let messageID, let attachmentID):
            guard let messageID else { return }
            selectedMessageID = messageID
            switch type {
            case "reply": onAction?(.reply(messageID))
            case "replyAll": onAction?(.replyAll(messageID))
            case "forward": onAction?(.forward(messageID))
            case "openAttachment":
                if let attachmentID { openAttachment(id: attachmentID, of: messageID) }
            default:
                ConversationSignposts.log.debug("unknown shell action \(type, privacy: .public)")
            }
        }
    }

    // MARK: Attachments and Quick Look

    /// Space: Quick Look for the selected message's first attachment, or close the panel if it is up.
    /// Returns false when there was nothing to do, so the key can go on to the web view and page down.
    @discardableResult
    func openQuickLookForSelectedMessage() -> Bool {
        let messageID = selectedMessageID ?? currentMessages.last?.id
        let parts = messageID.flatMap { (try? client.store.body(for: $0))?.body.attachments } ?? []
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
        Task { [weak self] in
            await self?.preview.preview(info, of: messageID, siblings: siblings)
        }
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

    func focusQuickReply() {
        quickReply.focus()
    }

    private func focusWebView() {
        guard let window = view.window else { return }
        if let current = pool.current {
            window.makeFirstResponder(current.webView)
        } else {
            window.makeFirstResponder(nil)
        }
    }

    private func sendQuickReply(_ text: String) {
        guard let conversation = currentConversationID, let latest = currentMessages.last else { return }
        let message = QuickReplyComposer.outgoingMessage(text: text, replyingTo: latest, accounts: accountsByID)
        guard !message.to.isEmpty else {
            quickReply.showStrip("No one to reply to")
            return
        }
        do {
            let sendID = try client.send(message, undoWindow: Self.undoWindow)
            quickReply.clear()
            quickReply.showStrip("Sent", buttonTitle: "Undo", duration: Self.undoWindow) { [weak self] in
                self?.undoSend(sendID, text: text, writtenUnder: conversation)
            }
        } catch {
            ConversationSignposts.log.error("quick reply send failed: \(String(describing: error), privacy: .public)")
            quickReply.showStrip("Couldn't send")
        }
    }

    /// Undo can arrive after the selection moved on; the text then waits under the thread it was written for.
    private func undoSend(_ sendID: String, text: String, writtenUnder conversation: ConversationID) {
        let cancelled = (try? client.cancelSend(id: sendID)) ?? false
        guard cancelled else {
            quickReply.showStrip("Already sent")
            return
        }
        if drafts.restoreUnsent(text, under: conversation, shown: currentConversationID) {
            // Anything typed since the send belongs to the same thread, so it is kept below the unsent text.
            let typed = quickReply.text
            quickReply.restoreDraft(typed.isEmpty ? text : text + "\n\n" + typed)
            quickReply.focus()
        } else {
            quickReply.showStrip("Not sent, draft kept")
        }
    }

    // MARK: Keyboard

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.handleSpace(event) else { return event }
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    /// Space opens Quick Look only while focus is inside the reader and not in the reply box. With nothing
    /// to preview the event is left alone, so the web view pages down on it as Safari would.
    private func handleSpace(_ event: NSEvent) -> Bool {
        guard let window = view.window, event.window === window,
              ReaderShortcuts.isPlainSpace(
                  charactersIgnoringModifiers: event.charactersIgnoringModifiers,
                  rawModifierFlags: event.modifierFlags.rawValue
              ),
              let responder = window.firstResponder as? NSView,
              responder.isDescendant(of: view),
              !(responder is NSTextView) else { return false }
        return openQuickLookForSelectedMessage()
    }
}
