import AppKit
import SSCore
import SSDesign
import os

/// The composer window (spec §3.2, §5.20–§5.23). One window per message; `present` keeps it alive in
/// `ComposeWindowRegistry` until it closes. Reply and forward windows open immediately with the header fields
/// filled from local metadata and fetch the original body afterwards, so the user can start typing before the
/// network answers.
///
/// Drafts are kept on this Mac (`ComposeDraftStore`) and autosaved, so closing never asks: content worth
/// keeping is saved before the window goes, and Message › Discard Draft… is the one way to throw it away.
@MainActor
final class ComposeWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate, NSTextViewDelegate, NSMenuItemValidation {
    /// Seconds a send is held for undo. The shell sets it from the "Undo send" preference.
    static var undoWindow: TimeInterval = 5

    /// Posted after Message › Discard Draft… removed a draft; `userInfo[draftUndoKey]` is a
    /// `ComposeDraftUndo` the main window's “Draft discarded · Undo” toast calls.
    static let draftDiscardedNotification = Notification.Name("ComposeDraftDiscarded")
    static let draftUndoKey = "undo"

    private static let sizeDefaultsKey = "ComposeWindowSize"
    private static let defaultSize = NSSize(width: Quire.Layout.Composer.width, height: Quire.Layout.Composer.height)
    private static let minimumSize = NSSize(width: Quire.Layout.Composer.minWidth, height: Quire.Layout.Composer.minHeight)
    private static let autosaveDelay: TimeInterval = 1.5
    private static let logger = Logger(subsystem: "io.supersparrow.mac", category: "compose")

    private let client: MailClient
    private let accounts: [Account]
    private let mode: ComposeMode
    private var account: Account
    /// This message's identity in `ComposeDraftStore`.
    private(set) var draftID = UUID()

    private let content = ComposeContentView()
    private let fromPopup: QuirePopUpButton
    private let toField = AddressTokenField()
    private let ccField = AddressTokenField()
    private let bccField = AddressTokenField()
    private let ccButton = QuireButton(title: "Cc", variant: .ghost, size: .small)
    private let bccButton = QuireButton(title: "Bcc", variant: .ghost, size: .small)
    private let subjectField = ComposeSubjectField()
    private let fromRow: ComposeFieldRow
    private let toRow: ComposeFieldRow
    private let ccRow: ComposeFieldRow
    private let bccRow: ComposeFieldRow
    private let subjectRow: ComposeFieldRow
    private let textView: ComposeTextView
    private let bodyDocument = ComposeDocumentView()
    private let quoteView = QuotedOriginalView()

    private var bar: ComposeBottomBar { content.bottomBar }

    private var attachments: [ComposeAttachment] = [] {
        didSet {
            content.strip.attachments = attachments
            content.needsLayout = true
        }
    }
    private var quoted: QuotedReply.Rendering? {
        didSet { quoteView.rendering = quoted }
    }
    private var threading: ReplyThreading?
    private var sendFailure: String? {
        didSet { bodyDocument.setFailureBanner(sendFailure) }
    }
    /// What the window held before the user touched it; only changes from it are worth keeping.
    private var baseline = ComposeDraft.Fingerprint()
    private var prefillTask: Task<Void, Never>?
    private var isPrefilling = false
    private var isSending = false
    private var closesWithoutSaving = false
    private var statusBoard = ComposeStatusBoard() {
        didSet { if oldValue != statusBoard { showStatus() } }
    }
    private var autosaveTimer: Timer?
    /// A draft of this window is on disk, so “nothing worth keeping” must remove it.
    private var hasStoredDraft = false
    private var linkPopover: ComposeLinkPopover?
    private var statusObservation: StoreObservation?

    // MARK: Presenting

    /// Opens a composer and keeps it alive until its window closes. A reply or forward that was kept as a
    /// draft opens with what was written; one already open comes forward.
    @discardableResult
    static func present(client: MailClient, account: Account, accounts: [Account], mode: ComposeMode) -> ComposeWindowController {
        if let kept = ComposeDraftStore.shared.keptDraft(for: mode, accounts: accounts) {
            return present(client: client, accounts: accounts, draft: kept)
        }
        let controller = ComposeWindowController(client: client, account: account, accounts: accounts, mode: mode)
        controller.show()
        controller.beginPrefill()
        return controller
    }

    /// A new message to `address` (a token's context menu, New Message).
    @discardableResult
    static func presentNew(client: MailClient, account: Account, accounts: [Account], to address: EmailAddress) -> ComposeWindowController {
        let controller = ComposeWindowController(client: client, account: account, accounts: accounts, mode: .new)
        controller.toField.addresses = [address]
        controller.show()
        controller.window?.makeFirstResponder(controller.subjectField)
        return controller
    }

    /// Reopens a draft: an undone send or a kept draft, exactly as it was; its window comes forward if it is
    /// already open.
    @discardableResult
    static func present(client: MailClient, accounts: [Account], draft: ComposeDraft) -> ComposeWindowController {
        if let open = ComposeWindowRegistry.shared.openControllers.first(where: { $0.draftID == draft.id }) {
            open.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return open
        }
        let controller = ComposeWindowController(client: client, account: draft.account, accounts: accounts, mode: draft.mode)
        controller.restore(draft)
        controller.show()
        return controller
    }

    /// Opens the kept draft `id` (the Drafts view's Continue Editing); false when it is gone.
    @discardableResult
    static func reopenKeptDraft(id: UUID, client: MailClient, accounts: [Account]) -> Bool {
        guard let draft = ComposeDraftStore.shared.draft(id: id, accounts: accounts) else { return false }
        present(client: client, accounts: accounts, draft: draft)
        return true
    }

    init(client: MailClient, account: Account, accounts: [Account], mode: ComposeMode) {
        self.client = client
        self.accounts = accounts.isEmpty ? [account] : accounts
        self.mode = mode
        // A reply belongs to the account that received the original, whatever the caller's current selection.
        if let id = mode.originalMessageID, let owner = accounts.first(where: { $0.id == id.accountID }) {
            self.account = owner
        } else {
            self.account = account
        }

        fromPopup = QuirePopUpButton(titles: [], isBorderless: true)
        textView = ComposeTextView(frame: NSRect(x: 0, y: 0, width: Self.defaultSize.width, height: 200))
        fromRow = ComposeFieldRow(title: "From", control: fromPopup)
        toRow = ComposeFieldRow(title: "To", control: toField, accessories: [ccButton, bccButton])
        ccRow = ComposeFieldRow(title: "Cc", control: ccField)
        bccRow = ComposeFieldRow(title: "Bcc", control: bccField)
        subjectRow = ComposeFieldRow(title: "Subject", kind: .subject, control: subjectField)

        let window = ComposeWindow(
            contentRect: NSRect(origin: .zero, size: Self.savedSize() ?? Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configureWindow(window)
        buildContent(in: window)
        wireControls()
        populateFromPopup()
        rebuildKeyLoop()
        updateTitle()
        updateSendEnabled()
        observeStatus()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ComposeWindowController is built in code")
    }

    private func show() {
        guard let window else { return }
        ComposeWindowRegistry.shared.register(self)
        ComposeWindowRegistry.shared.cascade(window)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        // Undo reopens the composer from a non-activating panel, possibly while another app is frontmost.
        NSApp.activate()
        focusInitialField()
    }

    // MARK: Building the window

    /// §3.2: a transparent system title bar over `paper`, the title visible, no toolbar.
    private func configureWindow(_ window: NSWindow) {
        window.delegate = self
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenAuxiliary]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.backgroundColor = .qPaper
    }

    private func buildContent(in window: NSWindow) {
        window.contentView = content
        content.onDropFiles = { [weak self] urls in self?.addAttachments(from: urls) }
        content.onCommand = { [weak self] command in self?.perform(command) }
        content.rows = [fromRow, toRow, ccRow, bccRow, subjectRow]
        fromRow.isHidden = accounts.count < 2
        ccRow.isHidden = true
        bccRow.isHidden = true

        bodyDocument.editor = textView
        bodyDocument.translatesAutoresizingMaskIntoConstraints = false
        bodyDocument.addSubview(textView)
        bodyDocument.addSubview(quoteView)
        let scrollView = content.scrollView
        scrollView.documentView = bodyDocument

        let clip = scrollView.contentView
        let fillsPage = quoteView.bottomAnchor.constraint(equalTo: bodyDocument.bottomAnchor)
        fillsPage.priority = .defaultLow
        // Room for a couple of lines before the folded original, so an empty reply still reads as a page.
        let editorMinimum = textView.heightAnchor.constraint(greaterThanOrEqualToConstant:
            Quire.Layout.Composer.bodyPadTop + 2 * ComposeTextView.bodyRole.lineHeight)
        editorMinimum.priority = .defaultHigh
        NSLayoutConstraint.activate([
            bodyDocument.topAnchor.constraint(equalTo: clip.topAnchor),
            bodyDocument.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            bodyDocument.widthAnchor.constraint(equalTo: clip.widthAnchor),
            bodyDocument.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
            textView.topAnchor.constraint(equalTo: bodyDocument.topAnchor),
            textView.leadingAnchor.constraint(equalTo: bodyDocument.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: bodyDocument.trailingAnchor),
            editorMinimum,
            quoteView.topAnchor.constraint(equalTo: textView.bottomAnchor),
            quoteView.leadingAnchor.constraint(equalTo: bodyDocument.leadingAnchor),
            quoteView.trailingAnchor.constraint(equalTo: bodyDocument.trailingAnchor),
            quoteView.bottomAnchor.constraint(lessThanOrEqualTo: bodyDocument.bottomAnchor),
            fillsPage,
        ])
    }

    private func wireControls() {
        let store = client.store
        let provider: AddressTokenField.SuggestionProvider = { prefix, limit in
            try store.suggestAddresses(prefix: prefix, limit: limit)
        }
        for (field, row) in [(toField, toRow), (ccField, ccRow), (bccField, bccRow)] {
            field.suggestionProvider = provider
            field.overlayHost = content
            field.onChange = { [weak self] in self?.recipientsChanged() }
            field.onLayoutChange = { [weak self] in self?.content.needsLayout = true }
            field.onFocusChange = { [weak row] in row?.needsDisplay = true }
            field.onNewMessage = { [weak self] address in self?.newMessage(to: address) }
            row.heightProvider = { [weak field] in field?.rowHeight ?? Quire.Layout.Composer.fieldRow }
            row.isFocused = { [weak field] in field?.hasKeyboardFocus ?? false }
            row.focusIsInside = { [weak field] in field?.focusIsOnToken ?? false }
        }
        fromRow.isFocused = { [weak self] in self?.window?.firstResponder === self?.fromPopup }
        subjectRow.isFocused = { [weak self] in
            guard let self, let responder = self.window?.firstResponder else { return false }
            return responder === self.subjectField || (responder as? NSTextView)?.delegate === self.subjectField
        }

        fromPopup.drawsFocusRing = false
        fromPopup.target = self
        fromPopup.action = #selector(fromChanged(_:))
        fromPopup.setAccessibilityLabel("From")

        for (button, title, row) in [(ccButton, "Add Cc Field  ⇧⌘C", ccRow), (bccButton, "Add Bcc Field  ⇧⌘B", bccRow)] {
            button.toolTip = title
            button.requiresFullKeyboardAccess = true
            button.target = self
            button.action = row === ccRow ? #selector(revealCc(_:)) : #selector(revealBcc(_:))
        }

        subjectField.delegate = self

        textView.delegate = self
        textView.onLinkRequest = { [weak self] _ in self?.showLinkPopover() }
        quoteView.onHeightChange = { [weak self] in self?.bodyDocument.needsLayout = true }

        bar.sendButton.target = self
        bar.sendButton.action = #selector(send(_:))
        bar.attachButton.target = self
        bar.attachButton.action = #selector(attachFile(_:))
        bar.formatButton.target = self
        bar.formatButton.action = #selector(toggleFormatRow(_:))
        content.formatRow.onToggle = { [weak self] item in self?.applyFormat(item) }
        content.strip.onRemove = { [weak self] id in self?.removeAttachment(id: id) }

        if let window {
            (window as? ComposeWindow)?.onFirstResponderChange = { [weak self] in self?.firstResponderChanged() }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(windowKeyChanged(_:)), name: name, object: window)
            }
        }
    }

    /// The Tab loop (§5.20): From → To → Cc → Bcc → Subject → Body → attachment chips → Send → Attach → Format →
    /// the format toggles → From. The Cc and Bcc buttons join it only with Full Keyboard Access.
    private func rebuildKeyLoop() {
        var loop: [NSView] = []
        if !fromRow.isHidden { loop.append(fromPopup) }
        loop.append(toField.keyView)
        loop += [ccButton, bccButton].filter { !$0.isHidden }
        if !ccRow.isHidden { loop.append(ccField.keyView) }
        if !bccRow.isHidden { loop.append(bccField.keyView) }
        loop.append(subjectField)
        loop.append(textView)
        loop.append(content.strip)
        loop += [bar.sendButton, bar.attachButton, bar.formatButton]
        if content.showsFormatRow { loop += content.formatRow.buttons.map(\.button) }
        for (index, view) in loop.enumerated() {
            view.nextKeyView = loop[(index + 1) % loop.count]
        }
        window?.initialFirstResponder = toField.keyView
    }

    private func populateFromPopup() {
        fromPopup.titles = accounts.map(Self.senderTitle)
        selectAccountInFromPopup()
        fromPopup.isEnabled = accounts.count > 1
    }

    private func selectAccountInFromPopup() {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            fromPopup.selectedIndex = index
        }
        fromPopup.inkMark = .dot(slot: account.inkSlot)
    }

    private static func senderTitle(for account: Account) -> String {
        let name = account.displayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? account.email : "\(name) <\(account.email)>"
    }

    private func focusInitialField() {
        switch mode {
        case .reply:
            window?.makeFirstResponder(textView)
        case .new, .forward:
            window?.makeFirstResponder(toField.addresses.isEmpty ? toField.keyView : textView)
        }
    }

    // MARK: Focus

    private func firstResponderChanged() {
        for field in [toField, ccField, bccField] { field.firstResponderDidChange() }
        for row in [fromRow, toRow, ccRow, bccRow, subjectRow] { row.needsDisplay = true }
        // The link popover belongs to the moment: focus going anywhere else dismisses it.
        if let popover = linkPopover, let responder = window?.firstResponder as? NSView, !responder.isDescendant(of: popover) {
            popover.close()
        }
    }

    @objc private func windowKeyChanged(_ note: Notification) {
        for row in [fromRow, toRow, ccRow, bccRow, subjectRow] { row.needsDisplay = true }
        if note.name == NSWindow.didResignKeyNotification {
            for field in [toField, ccField, bccField] { field.closeAutocomplete() }
        }
    }

    // MARK: Header actions

    @objc private func fromChanged(_ sender: Any?) {
        guard accounts.indices.contains(fromPopup.selectedIndex) else { return }
        // Changing From changes the sending account and nothing in the body: v1 has no signatures (§9).
        account = accounts[fromPopup.selectedIndex]
        fromPopup.inkMark = .dot(slot: account.inkSlot)
        observeStatus()
        draftChanged(body: false)
    }

    @objc private func revealCc(_ sender: Any?) {
        showRow(ccRow, button: ccButton)
        window?.makeFirstResponder(ccField.keyView)
    }

    @objc private func revealBcc(_ sender: Any?) {
        showRow(bccRow, button: bccButton)
        window?.makeFirstResponder(bccField.keyView)
    }

    private func showRow(_ row: ComposeFieldRow, button: QuireButton) {
        row.isHidden = false
        button.isHidden = true
        toRow.accessoriesDidChange()
        rebuildKeyLoop()
        content.needsLayout = true
    }

    private func newMessage(to address: EmailAddress) {
        Self.presentNew(client: client, account: account, accounts: accounts, to: address)
    }

    private func updateTitle() {
        let subject = subjectField.stringValue.trimmingCharacters(in: .whitespaces)
        window?.title = subject.isEmpty ? "New Message" : subject
    }

    private func perform(_ command: ComposeContentView.Command) {
        switch command {
        case .send: send(nil)
        case .attach: attachFile(nil)
        case .toggleFormatRow: toggleFormatRow(nil)
        case .addCc: if ccRow.isHidden { revealCc(nil) } else { window?.makeFirstResponder(ccField.keyView) }
        case .addBcc: if bccRow.isHidden { revealBcc(nil) } else { window?.makeFirstResponder(bccField.keyView) }
        }
    }

    // MARK: NSTextFieldDelegate (subject)

    func controlTextDidChange(_ obj: Notification) {
        subjectField.updateFont()
        updateTitle()
        draftChanged(body: false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard control === subjectField else { return false }
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            // Return in the subject moves on to the body instead of inserting nothing.
            window?.makeFirstResponder(self.textView)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc never closes a composer (§6.1).
            return true
        default:
            return false
        }
    }

    // MARK: NSTextViewDelegate (body)

    func textDidChange(_ notification: Notification) {
        draftChanged(body: true)
        updateFormatState()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateFormatState()
    }

    // MARK: Format row

    @objc private func toggleFormatRow(_ sender: Any?) {
        content.showsFormatRow.toggle()
        bar.formatButton.isOn = content.showsFormatRow
        bar.formatButton.toolTip = content.showsFormatRow ? "Hide Format Row  ⇧⌘T" : "Show Format Row  ⇧⌘T"
        bar.formatButton.setAccessibilityLabel(content.showsFormatRow ? "Hide Format Row" : "Show Format Row")
        updateFormatState()
        rebuildKeyLoop()
    }

    private func applyFormat(_ item: ComposeFormatRow.Item) {
        if window?.firstResponder !== textView { window?.makeFirstResponder(textView) }
        switch item {
        case .bold: textView.toggleBold(nil)
        case .italic: textView.toggleItalic(nil)
        case .underline: textView.underline(nil)
        case .bulletList: textView.toggleBulletList(nil)
        case .numberedList: textView.toggleNumberedList(nil)
        case .quote: textView.toggleBlockQuote(nil)
        case .link: showLinkPopover()
        }
        updateFormatState()
    }

    private func updateFormatState() {
        guard content.showsFormatRow else { return }
        content.formatRow.setState(textView.formatState)
    }

    // MARK: Link popover

    private func showLinkPopover() {
        guard linkPopover == nil, !isSending else { return }
        let selection = textView.selectedRange()
        let existing = textView.existingLink(at: selection)
        let range = existing?.range ?? selection
        let request = ComposeLinkPopover.Request(range: range, existingTarget: existing?.target, needsText: range.length == 0)
        let popover = ComposeLinkPopover(request: request)
        guard let anchor = textView.anchorRects(for: range) else { return }
        let first = content.convert(anchor.first, from: textView)
        let last = content.convert(anchor.last, from: textView)
        let startX = content.convert(NSPoint(x: anchor.startX, y: anchor.first.minY), from: textView).x
        let c = Quire.Layout.Composer.self
        let frame = ComposePopoverPlacement.linkPopover(firstLine: first, lastLine: last, selectionStartX: startX,
                                                        size: popover.preferredSize, bounds: content.bounds, pad: c.linkPopoverPad,
                                                        offsetY: c.linkPopoverOffsetY, edgeMin: c.popoverEdgeMin)
        popover.onConfirm = { [weak self] target, text in
            self?.textView.applyLink(target, text: text, to: range)
        }
        popover.onRemove = { [weak self] in self?.textView.removeLink(in: range) }
        popover.onClose = { [weak self, weak popover] in
            guard let self else { return }
            self.linkPopover = nil
            // Confirmed or cancelled from inside: the caret goes back to the text. Focus that already moved
            // elsewhere (a click in a field) stays where it went.
            if let popover, let responder = self.window?.firstResponder as? NSView, responder.isDescendant(of: popover) {
                self.window?.makeFirstResponder(self.textView)
            }
            self.updateFormatState()
        }
        linkPopover = popover
        popover.present(in: content, frame: frame)
    }

    // MARK: Prefill

    private func beginPrefill() {
        guard let originalID = mode.originalMessageID else { return }
        isPrefilling = true
        statusBoard.post(.loadingOriginal)
        updateSendEnabled()
        prefillTask = Task { [weak self] in
            guard let self else { return }
            await self.prefill(originalID: originalID)
        }
    }

    private func prefill(originalID: MessageID) async {
        guard let original = try? client.store.message(originalID) else {
            finishPrefill(status: .originalGone)
            return
        }
        applyHeaders(from: original)

        let body: StoredBody
        do {
            body = try await client.ensureBody(for: originalID)
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.error("Compose prefill could not load the original body: \(String(describing: error))")
            finishPrefill(status: .originalFailed)
            return
        }
        guard !Task.isCancelled else { return }

        // Built off the main actor: the quote re-serializes the whole stored body with SwiftSoup, which on
        // a long thread takes long enough to drop keystrokes in the editor that is already on screen.
        let isForward = mode.isForward
        let rendering = await Task.detached(priority: .userInitiated) {
            isForward
                ? QuotedReply.forward(original: original, body: body)
                : QuotedReply.reply(original: original, body: body)
        }.value
        guard !Task.isCancelled else { return }
        quoted = rendering

        let parts = QuotedReply.partsToCarry(from: body.body.attachments, quotedHTML: rendering.html, isForward: isForward)
        // Forwarded files show as loading chips at once; inline parts of the quote never show.
        let placeholders = parts.map { ComposeAttachment.loading(info: $0.info, contentID: $0.contentID) }
        attachments.append(contentsOf: placeholders)
        baseline.attachmentIDs.formUnion(placeholders.map(\.id))
        var failures = 0
        for (part, placeholder) in zip(parts, placeholders) {
            do {
                let data = try await client.attachmentData(for: originalID, attachmentID: part.info.id)
                guard !Task.isCancelled else { return }
                replaceAttachment(placeholder.id) { attachment in
                    attachment.source = .data(data)
                    attachment.sizeBytes = data.count
                    attachment.state = .ready
                }
            } catch {
                guard !Task.isCancelled else { return }
                failures += 1
                replaceAttachment(placeholder.id) { $0.state = .failed(short: "Couldn't load", detail: "Couldn't load from the original message") }
                Self.logger.error("Compose prefill could not load an attachment: \(String(describing: error))")
            }
        }
        finishPrefill(status: failures == 0 ? nil : .attachmentsFailed(count: failures))
    }

    private func replaceAttachment(_ id: UUID, _ change: (inout ComposeAttachment) -> Void) {
        guard let index = attachments.firstIndex(where: { $0.id == id }) else { return }
        var attachment = attachments[index]
        change(&attachment)
        attachments[index] = attachment
    }

    private func applyHeaders(from original: MessageMetadata) {
        switch mode {
        case .reply(_, let all):
            let recipients = ReplyRecipients.compute(for: original, all: all, ownAddresses: [account.email])
            toField.addresses = recipients.to
            ccField.addresses = recipients.cc
            if !recipients.cc.isEmpty { showRow(ccRow, button: ccButton) }
            subjectField.stringValue = SubjectPrefixer.reply(original.subject)
            threading = ReplyThreading(original: original, isReply: true)
            baseline.to = recipients.to.map(\.address)
            baseline.cc = recipients.cc.map(\.address)
        case .forward:
            subjectField.stringValue = SubjectPrefixer.forward(original.subject)
            threading = ReplyThreading(original: original, isReply: false)
        case .new:
            break
        }
        baseline.subject = subjectField.stringValue
        subjectField.updateFont()
        updateTitle()
        updateSendEnabled()
    }

    private func finishPrefill(status: ComposeStatus?) {
        isPrefilling = false
        statusBoard.finishLoadingOriginal()
        if let status { statusBoard.post(status) }
        updateSendEnabled()
    }

    // MARK: Draft state

    private func currentDraft() -> ComposeDraft {
        ComposeDraft(
            id: draftID,
            mode: mode,
            account: account,
            to: toField.addresses,
            cc: ccField.addresses,
            bcc: bccField.addresses,
            subject: subjectField.stringValue,
            body: NSAttributedString(attributedString: textView.attributedString()),
            attachments: attachments,
            quoted: quoted,
            threading: threading,
            sendFailure: sendFailure
        )
    }

    private func restore(_ draft: ComposeDraft) {
        draftID = draft.id
        // The draft remembers the From the user chose, which `init` replaced with the original's owner.
        account = draft.account
        selectAccountInFromPopup()
        toField.addresses = draft.to
        ccField.addresses = draft.cc
        bccField.addresses = draft.bcc
        if !draft.cc.isEmpty { showRow(ccRow, button: ccButton) }
        if !draft.bcc.isEmpty { showRow(bccRow, button: bccButton) }
        subjectField.stringValue = draft.subject
        subjectField.updateFont()
        textView.replaceContents(with: draft.body)
        attachments = draft.attachments
        quoted = draft.quoted
        threading = draft.threading
        sendFailure = draft.sendFailure
        // Everything here is the user's own work, so it is worth keeping as it stands.
        baseline = ComposeDraft.Fingerprint()
        hasStoredDraft = ComposeDraftStore.shared.draft(id: draft.id, accounts: accounts) != nil
        updateTitle()
        updateSendEnabled()
        observeStatus()
    }

    /// Content worth keeping: anything the user typed, chose or attached; at most the prefilled reply and
    /// its folded original is not (§5.20).
    private var isWorthKeeping: Bool {
        let fingerprint = currentDraft().fingerprint
        guard fingerprint != baseline else { return false }
        let typed = !textView.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasRecipients = !fingerprint.to.isEmpty || !fingerprint.cc.isEmpty || !fingerprint.bcc.isEmpty
        let hasSubject = !fingerprint.subject.trimmingCharacters(in: .whitespaces).isEmpty
        let hasFiles = attachments.contains { !$0.isInline && !baseline.attachmentIDs.contains($0.id) }
        return typed || hasRecipients || hasSubject || hasFiles
    }

    private func recipientsChanged() {
        updateSendEnabled()
        draftChanged(body: false)
    }

    /// An edit: Draft saved goes stale (warnings wait for the body), and the autosave restarts its pause.
    private func draftChanged(body: Bool) {
        if body { statusBoard.bodyEdited() } else { statusBoard.edited() }
        scheduleAutosave()
    }

    private func scheduleAutosave() {
        autosaveTimer?.invalidate()
        guard !isSending, !closesWithoutSaving else { return }
        let timer = Timer(timeInterval: Self.autosaveDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.autosave() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autosaveTimer = timer
    }

    private func autosave() {
        autosaveTimer = nil
        guard !isSending, !closesWithoutSaving else { return }
        guard isWorthKeeping else {
            if hasStoredDraft {
                ComposeDraftStore.shared.remove(id: draftID)
                hasStoredDraft = false
            }
            return
        }
        statusBoard.post(.saving)
        ComposeDraftStore.shared.save(currentDraft()) { [weak self] ok in
            guard let self else { return }
            if ok {
                self.hasStoredDraft = true
                self.statusBoard.post(.saved)
            } else {
                self.statusBoard.clear(.saving)
            }
        }
    }

    private func showStatus() {
        bar.statusView.status = statusBoard.current
        bar.statusDidChange()
    }

    /// The sending account's provider is out of reach: a send waits in the outbox (§5.20, Offline).
    private func observeStatus() {
        let accountID = account.id
        statusObservation?.cancel()
        statusObservation = client.observeStatus { [weak self] statuses in
            let offline = statuses.first { $0.accountID == accountID }.map {
                $0.phase == .error && ($0.message ?? "").hasPrefix("network")
            } ?? false
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.statusBoard.setOffline(offline) }
            }
        }
    }

    // MARK: Attachments

    @objc private func attachFile(_ sender: Any?) {
        guard let window, !isSending else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let self else { return }
                self.addAttachments(from: panel.urls)
            }
        }
    }

    /// Attaches the readable files; folders and unreadable files become the rejected-drop status (§5.20),
    /// never an alert.
    private func addAttachments(from urls: [URL]) {
        guard !isSending else { return }
        var rejected = ComposeStatus.RejectedDrop()
        var added: [ComposeAttachment] = []
        for url in urls {
            do {
                added.append(try ComposeAttachment(fileURL: url))
            } catch ComposeAttachment.AttachError.folder {
                rejected.folders.append(url.lastPathComponent)
            } catch {
                rejected.unreadable.append(url.lastPathComponent)
            }
        }
        if !added.isEmpty {
            attachments.append(contentsOf: added)
            draftChanged(body: false)
        }
        if !rejected.isEmpty { statusBoard.post(.rejectedDrop(rejected)) }
    }

    private func removeAttachment(id: UUID) {
        guard !isSending else { return }
        attachments.removeAll { $0.id == id }
        draftChanged(body: false)
        if !content.strip.hasChips, window?.firstResponder === content.strip { window?.makeFirstResponder(textView) }
    }

    // MARK: Sending

    @objc private func send(_ sender: Any?) {
        guard !isSending, !isPrefilling, validateRecipients() else {
            NSSound.beep()
            return
        }
        if subjectField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let window {
            let alert = NSAlert()
            alert.messageText = "Send without a subject?"
            alert.informativeText = "Messages without a subject are easy to miss."
            alert.addButton(withTitle: "Add Subject")
            alert.addButton(withTitle: "Send Anyway").keyEquivalent = ""
            // Esc goes to Add Subject too (§5.20): a hidden third button carries it, since a button holds one key.
            let escape = alert.addButton(withTitle: "Add Subject")
            escape.keyEquivalent = "\u{1b}"
            alert.layout()
            escape.isHidden = true
            alert.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if response == .alertSecondButtonReturn {
                        self.performSend()
                    } else {
                        self.window?.makeFirstResponder(self.subjectField)
                    }
                }
            }
            return
        }
        performSend()
    }

    /// Commits whatever is still being typed and reports whether the message has somewhere to go; focus goes
    /// to the first field that would be rejected.
    private func validateRecipients() -> Bool {
        let ccValid = ccField.validateForSend()
        let bccValid = bccField.validateForSend()
        let hasOtherRecipient = !ccField.addresses.isEmpty || !bccField.addresses.isEmpty
        let toValid = toField.validateForSend(requireRecipient: !hasOtherRecipient)
        if !toValid {
            window?.makeFirstResponder(toField.keyView)
        } else if !ccValid {
            window?.makeFirstResponder(ccField.keyView)
        } else if !bccValid {
            window?.makeFirstResponder(bccField.keyView)
        }
        updateSendEnabled()
        return toValid && ccValid && bccValid
    }

    private func performSend() {
        autosaveTimer?.invalidate()
        let draft = currentDraft()
        let normalized = ComposeBodyNormalizer.normalize(draft.body)
        let pending = draft.attachments.filter(\.isSendable)
        setSending(true)

        Task { [weak self] in
            // File-backed attachments are read here, off the main thread, so a large file never stalls the window.
            let outcome: (parts: [OutgoingAttachment], failure: UUID?) = await Task.detached(priority: .userInitiated) {
                var parts: [OutgoingAttachment] = []
                for attachment in pending {
                    do {
                        parts.append(try attachment.outgoing())
                    } catch {
                        return ([], attachment.id)
                    }
                }
                return (parts, nil)
            }.value
            guard let self else { return }
            if let failed = outcome.failure {
                self.setSending(false)
                let name = self.attachments.first { $0.id == failed }?.filename ?? "attachment"
                self.replaceAttachment(failed) { $0.state = .failed(short: "Can't read", detail: "“\(name)” couldn't be read. It may have been moved or deleted.") }
                self.statusBoard.post(.unreadableAttachment(name: name))
                return
            }
            var sent = draft
            sent.sendFailure = nil
            let message = sent.outgoingMessage(normalizedBody: normalized, loadedAttachments: outcome.parts)
            do {
                let sendID = try self.client.send(message, undoWindow: Self.undoWindow)
                // The outbox holds the message now; the panel keeps the draft for Undo and for a failure.
                ComposeDraftStore.shared.remove(id: self.draftID)
                self.closesWithoutSaving = true
                self.close()
                UndoSendPanel.show(client: self.client, accounts: self.accounts, sendID: sendID, draft: sent,
                                   undoWindow: Self.undoWindow)
            } catch {
                Self.logger.error("Queueing a send failed: \(String(describing: error))")
                self.setSending(false)
                self.sendFailure = "Couldn't send: the message couldn't be added to the outbox."
            }
        }
    }

    private func setSending(_ sending: Bool) {
        isSending = sending
        if sending { sendFailure = nil }
        bar.sendButton.isLoading = sending
        for field in [toField, ccField, bccField] { field.isLocked = sending }
        subjectField.isEditable = !sending
        textView.isEditable = !sending
        updateSendEnabled()
    }

    /// Send is disabled without a valid recipient (§5.23); its tooltip says what to fix. ⌘↩ still validates,
    /// so it lands on the field to fix.
    private func updateSendEnabled() {
        let fields = [toField, ccField, bccField]
        let invalid = fields.flatMap(\.invalidAddresses)
        let pending = fields.map(\.pendingText).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let hasRecipient = fields.contains { !$0.addresses.isEmpty } || !pending.isEmpty
        let button = bar.sendButton
        if let bad = invalid.first {
            button.toolTip = "Fix the address \(bad.address)"
        } else if !hasRecipient {
            button.toolTip = "Add a recipient"
        } else {
            button.toolTip = "Send  ⌘↩"
        }
        button.isEnabled = isSending || (!isPrefilling && hasRecipient && invalid.isEmpty)
    }

    // MARK: Discarding

    /// Message › Discard Draft… (§5.20): the “Discard this draft?” alert, composer form.
    @objc func discardDraft(_ sender: Any?) {
        guard let window, !isSending else { return }
        let alert = NSAlert()
        alert.messageText = "Discard this draft?"
        if let name = currentDraft().firstRecipientName {
            alert.informativeText = "The message to \(name) hasn't been sent. Discarding removes it from this Mac."
        } else {
            alert.informativeText = "This message hasn't been sent. Discarding removes it from this Mac."
        }
        alert.addButton(withTitle: "Keep Writing")
        let discard = alert.addButton(withTitle: "Discard")
        discard.hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertSecondButtonReturn, let self else { return }
                self.confirmDiscard()
            }
        }
    }

    private func confirmDiscard() {
        let draft = currentDraft()
        let client = client
        let accounts = accounts
        autosaveTimer?.invalidate()
        ComposeDraftStore.shared.remove(id: draftID)
        closesWithoutSaving = true
        close()
        let undo = ComposeDraftUndo {
            ComposeWindowController.present(client: client, accounts: accounts, draft: draft)
        }
        NotificationCenter.default.post(name: Self.draftDiscardedNotification, object: nil, userInfo: [Self.draftUndoKey: undo])
    }

    // MARK: Menu validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(discardDraft(_:)) { return !isSending }
        return true
    }

    // MARK: NSWindowDelegate

    /// Closing never asks (§5.20): content worth keeping is saved before the window goes, nothing is kept
    /// otherwise. While a send is starting the window stays; the undo panel replaces it at once.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closesWithoutSaving { return true }
        guard !isSending else { return false }
        autosaveTimer?.invalidate()
        if isWorthKeeping {
            ComposeDraftStore.shared.saveNow(currentDraft())
        } else if hasStoredDraft {
            ComposeDraftStore.shared.remove(id: draftID)
        }
        return true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveSize()
    }

    func windowWillClose(_ notification: Notification) {
        prefillTask?.cancel()
        autosaveTimer?.invalidate()
        statusObservation?.cancel()
        for field in [toField, ccField, bccField] { field.closeAutocomplete() }
        saveSize()
        ComposeWindowRegistry.shared.unregister(self)
    }

    /// Stores the content size, which is what `init` feeds back as `contentRect`; storing the frame
    /// would add a title bar's height on every reopen.
    private func saveSize() {
        guard let window else { return }
        let content = window.contentRect(forFrameRect: window.frame).size
        UserDefaults.standard.set(NSStringFromSize(content), forKey: Self.sizeDefaultsKey)
    }

    private static func savedSize() -> NSSize? {
        guard let stored = UserDefaults.standard.string(forKey: sizeDefaultsKey) else { return nil }
        let size = NSSizeFromString(stored)
        guard size.width >= minimumSize.width, size.height >= minimumSize.height else { return nil }
        return size
    }
}

/// Reopens a discarded draft: what the main window's “Draft discarded · Undo” toast calls.
@MainActor
final class ComposeDraftUndo: NSObject {
    private let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }

    func undo() {
        action()
    }
}

/// The composer's window: Esc never closes it (§6.1), and it reports focus changes to its controller.
@MainActor
final class ComposeWindow: NSWindow {
    /// Every focus change goes through here (clicks, Tab, code), so the rows can redraw their rings.
    var onFirstResponderChange: (() -> Void)?

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let changed = super.makeFirstResponder(responder)
        onFirstResponderChange?()
        return changed
    }

    override func cancelOperation(_ sender: Any?) {}
}

/// The Subject field: borderless `composeSubject` (New York 15 pt, its sans twin for scripts New York lacks)
/// in `ink`, an `accent` caret, no ring of its own (the row draws the inset ring).
@MainActor
private final class ComposeSubjectField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        textColor = .qInk
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        updateFont()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ComposeSubjectField is built in code")
    }

    func updateFont() {
        let font = QuireFont.font(.composeSubject, for: stringValue)
        if self.font != font { self.font = font }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = .qAccent
        }
        return accepted
    }
}
