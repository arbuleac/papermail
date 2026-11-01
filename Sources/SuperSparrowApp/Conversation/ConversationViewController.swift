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
    private static let markReadDelay: TimeInterval = 0.5
    private static let undoWindow: TimeInterval = 5

    private let pool: WebViewPool
    private let preview: AttachmentPreviewController
    private let builder = RenderPayloadBuilder()
    private let header = ConversationHeaderView()
    private let webContainer = NSView()
    private let quickReply = QuickReplyView()
    private let emptyLabel = NSTextField(labelWithString: "No conversation selected")

    private var observation: StoreObservation?
    private var showTimer: Timer?
    private var pendingShowID: ConversationID?
    private var lastShowAt: TimeInterval = -.infinity
    private var markReadTimer: Timer?
    private var bodyFetches: Set<MessageID> = []
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
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        observation?.cancel()
        showTimer?.invalidate()
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
        header.subject = subject(for: id)
        header.isHidden = false
        emptyLabel.isHidden = true
        let now = ProcessInfo.processInfo.systemUptime
        let tooSoon = now - lastShowAt < Self.showDebounce
        lastShowAt = now
        pendingShowID = id
        if tooSoon || showTimer != nil {
            showTimer?.invalidate()
            showTimer = Timer.scheduledTimer(withTimeInterval: Self.showDebounce, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushPendingShow() }
            }
        } else {
            flushPendingShow()
        }
    }

    /// Renders `ids` into free slots in order, skipping ones already held, until the pool runs out.
    func prerender(_ ids: [ConversationID]) {
        var reserved: [PooledConversationView] = []
        let wanted = ids.filter { $0 != currentConversationID }
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
            let payload = payload(for: messages, id: id)
            let state = ConversationSignposts.begin(ConversationSignposts.prerender)
            pool.render(payload, id: id, into: slot) { _ in
                ConversationSignposts.end(ConversationSignposts.prerender, state)
            }
            requestMissingBodies(messages)
        }
    }

    private func cancelPendingShow() {
        showTimer?.invalidate()
        showTimer = nil
        pendingShowID = nil
    }

    private func flushPendingShow() {
        showTimer = nil
        guard let id = pendingShowID else { return }
        pendingShowID = nil
        performShow(id)
    }

    private func performShow(_ id: ConversationID) {
        if let previous = showSignpost {
            ConversationSignposts.end(ConversationSignposts.show, previous)
        }
        showSignpost = ConversationSignposts.begin(ConversationSignposts.show)
        currentConversationID = id
        preview.closePanel()
        quickReply.hideStrip()

        let messages = visibleMessages(for: id)
        applyMessages(messages, for: id)
        let payload = payload(for: messages, id: id)

        if let held = pool.slot(rendering: id) {
            if held.renderInFlight {
                // The completion registered by the earlier show() swaps it in.
            } else {
                swap(in: held)
                if held.renderedPayload != payload {
                    pool.render(payload, id: id, into: held)
                }
            }
        } else if let slot = pool.acquire() {
            if slot.renderedID == nil {
                // A blank shell is better than another conversation's cards while the render lands.
                swap(in: slot)
            }
            pool.render(payload, id: id, into: slot) { [weak self] rendered in
                guard let self, rendered, self.currentConversationID == id else { return }
                self.swap(in: slot)
            }
        }

        observe(id)
        scheduleMarkRead(for: id)
        requestMissingBodies(messages)
    }

    private func showEmptyState() {
        currentConversationID = nil
        currentMessages = []
        selectedMessageID = nil
        observation?.cancel()
        observation = nil
        markReadTimer?.invalidate()
        markReadTimer = nil
        preview.closePanel()
        quickReply.hideStrip()
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
        guard slot === pool.current, let id = currentConversationID else { return }
        let messages = visibleMessages(for: id)
        pool.render(payload(for: messages, id: id), id: id, into: slot)
    }

    // MARK: Store

    private func subject(for id: ConversationID) -> String {
        RenderPayloadBuilder.subject(of: visibleMessages(for: id))
    }

    private func visibleMessages(for id: ConversationID) -> [MessageMetadata] {
        RenderPayloadBuilder.visibleMessages((try? client.store.messages(in: id)) ?? [])
    }

    private func payload(for messages: [MessageMetadata], id: ConversationID) -> RenderPayload {
        var bodies: [MessageID: StoredBody] = [:]
        for message in messages {
            if let body = try? client.store.body(for: message.id) { bodies[message.id] = body }
        }
        return builder.build(messages: messages, bodies: bodies, accounts: accountsByID)
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
        guard let current = pool.current, current.renderedID == id else { return }
        let fresh = payload(for: messages, id: id)
        if current.renderedPayload != fresh {
            pool.render(fresh, id: id, into: current)
        }
    }

    private func requestMissingBodies(_ messages: [MessageMetadata]) {
        for message in messages where bodyFetches.contains(message.id) == false {
            guard (try? client.store.body(for: message.id)) == nil else { continue }
            bodyFetches.insert(message.id)
            let client = self.client
            Task { [weak self] in
                _ = try? await client.ensureBody(for: message.id)
                guard let self else { return }
                self.bodyFetches.remove(message.id)
                guard self.currentConversationID == message.conversationID else { return }
                let visible = self.visibleMessages(for: message.conversationID)
                self.refreshCurrentIfStale(visible, id: message.conversationID)
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

    /// Space: Quick Look for the selected message's first attachment (or close the panel if it is up).
    func openQuickLookForSelectedMessage() {
        if preview.isPanelVisible {
            preview.closePanel()
            return
        }
        guard let messageID = selectedMessageID ?? currentMessages.last?.id,
              let first = attachments(of: messageID).first else { return }
        openAttachment(first, of: messageID)
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
        guard let latest = currentMessages.last else { return }
        let message = QuickReplyComposer.outgoingMessage(text: text, replyingTo: latest, accounts: accountsByID)
        guard !message.to.isEmpty else {
            quickReply.showStrip("No one to reply to")
            return
        }
        do {
            let sendID = try client.send(message, undoWindow: Self.undoWindow)
            quickReply.clear()
            quickReply.showStrip("Sent", buttonTitle: "Undo", duration: Self.undoWindow) { [weak self] in
                guard let self else { return }
                let cancelled = (try? self.client.cancelSend(id: sendID)) ?? false
                if cancelled {
                    self.quickReply.restoreDraft(text)
                    self.quickReply.focus()
                } else {
                    self.quickReply.showStrip("Already sent")
                }
            }
        } catch {
            ConversationSignposts.log.error("quick reply send failed: \(String(describing: error), privacy: .public)")
            quickReply.showStrip("Couldn't send")
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

    /// Space opens Quick Look only while focus is inside the reader and not in the reply box.
    private func handleSpace(_ event: NSEvent) -> Bool {
        guard let window = view.window, event.window === window,
              event.charactersIgnoringModifiers == " ",
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
              let responder = window.firstResponder as? NSView,
              responder.isDescendant(of: view),
              !(responder is NSTextView) else { return false }
        openQuickLookForSelectedMessage()
        return true
    }
}
