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
    let mode: ComposeMode
    private var account: Account
    /// This message's identity in `ComposeDraftStore`.
    private(set) var draftID = UUID()
    /// The provider's draft this message continues (Continue Editing on a synced Drafts row); sending it
    /// discards the provider's copy, so Drafts never keeps the original beside the sent message.
    private(set) var continuesDraft: MessageID?

    /// The account the message is sent from.
    var accountID: AccountID { account.id }

    /// The body as plain text (the app's tests read it).
    var bodyText: String { textView.string }

    /// The message this composer replies to (not a forward): the reader disables its quick reply while one
    /// of its conversation's messages has a reply open here (§5.18).
    var repliesTo: MessageID? {
        if case .reply(let id, _) = mode { return id }
        return nil
    }

    private let content = ComposeContentView()
    private let fromPopup: QuirePopUpButton
    private let toField = AddressTokenField()
    private let ccField = AddressTokenField()
    private let bccField = AddressTokenField()
    private let ccButton = QuireButton(title: "Cc", variant: .ghost, size: .small)
    private let bccButton = QuireButton(title: "Bcc", variant: .ghost, size: .small)
    private let subjectField = ComposeSubjectField()
    /// The Subject field's font as set now (tests read it).
    var subjectFont: NSFont? { subjectField.font }
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
    ///
    /// `body` is text already written for it (the quick reply's, §5.18): it opens in the editor with the caret
    /// at its end, below anything a kept draft held. With `attach`, the Attach Files panel follows at once.
    @discardableResult
    static func present(client: MailClient, account: Account, accounts: [Account], mode: ComposeMode, body: String = "",
                        attach: Bool = false) -> ComposeWindowController {
        let typed = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : body
        let controller: ComposeWindowController
        if var kept = ComposeDraftStore.shared.keptDraft(for: mode, accounts: accounts) {
            if !typed.isEmpty {
                let joined = NSMutableAttributedString(attributedString: kept.body)
                if joined.length > 0 { joined.append(NSAttributedString(string: "\n\n")) }
                joined.append(NSAttributedString(string: typed))
                kept.body = joined
            }
            controller = present(client: client, accounts: accounts, draft: kept)
        } else {
            controller = ComposeWindowController(client: client, account: account, accounts: accounts, mode: mode)
            if !typed.isEmpty { controller.textView.replaceContents(with: NSAttributedString(string: typed)) }
            controller.show()
            controller.beginPrefill()
        }
        if !typed.isEmpty {
            controller.textView.setSelectedRange(NSRange(location: (controller.textView.string as NSString).length, length: 0))
            controller.draftChanged(body: true)
        }
        if attach { controller.attachFile(nil) }
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
            styleMask: QuireWindowChrome.mainStyleMask,
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

    /// §3.2: a transparent system title bar over `paper`, the title visible, no toolbar. The chrome is the
    /// design layer's, so the composer and `WindowChromeTests` configure the same window.
    private func configureWindow(_ window: NSWindow) {
        QuireWindowChrome.configureComposerWindow(window)
        window.delegate = self
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenAuxiliary]
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
        // Quitting closes windows without asking their delegates, so the last edit is kept here instead.
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillTerminate(_:)),
                                               name: NSApplication.willTerminateNotification, object: nil)
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
        fromPopup.titles = accounts.map(AccountLabels.senderTitle(for:))
        selectAccountInFromPopup()
        fromPopup.isEnabled = accounts.count > 1
    }

    private func selectAccountInFromPopup() {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            fromPopup.selectedIndex = index
        }
        fromPopup.inkMark = .dot(slot: account.inkSlot)
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
        // Rings show only in the key window (§3.4): the rows', a selected token's and a focused chip's.
        for row in [fromRow, toRow, ccRow, bccRow, subjectRow] { row.needsDisplay = true }
        for field in [toField, ccField, bccField] { field.windowKeyDidChange() }
        content.strip.windowKeyDidChange()
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

    /// Message › Add Cc Field / Add Bcc Field (spec §5.35): the same as the To row's Cc and Bcc buttons.
    @objc func addCcField(_ sender: Any?) {
        revealCc(sender)
    }

    @objc func addBccField(_ sender: Any?) {
        revealBcc(sender)
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

    /// Clicking a link in the body places the caret, as anywhere else in text being written; ⌘K on it opens
    /// the link popover to edit it (§5.20). The text view would otherwise open the address in the browser.
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        textView.setSelectedRange(NSRange(location: charIndex, length: 0))
        return true
    }

    /// ⌘B, ⌘I or ⌘U at a caret change only the typing attributes, which no text or selection change reports;
    /// the toggles follow the caret all the same (§5.20, Format row).
    func textViewDidChangeTypingAttributes(_ notification: Notification) {
        updateFormatState()
    }

    // MARK: Format row

    @objc func toggleFormatRow(_ sender: Any?) {
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

    // MARK: Format menu (§5.35)

    // The body answers these itself while it has focus. From elsewhere in the window (Send, a chip, a format
    // toggle) they act on the body as the format row does; while another field is being typed in they stay
    // disabled, so ⌘B in Subject never bolds the body.
    @objc func toggleBold(_ sender: Any?) { applyFormat(.bold) }
    @objc func toggleItalic(_ sender: Any?) { applyFormat(.italic) }
    @objc func toggleUnderline(_ sender: Any?) { applyFormat(.underline) }
    @objc func toggleBulletList(_ sender: Any?) { applyFormat(.bulletList) }
    @objc func toggleNumberedList(_ sender: Any?) { applyFormat(.numberedList) }
    @objc func toggleBlockQuote(_ sender: Any?) { applyFormat(.quote) }
    @objc func insertLink(_ sender: Any?) { applyFormat(.link) }

    private static let formatCommands: Set<Selector> = [
        #selector(toggleBold(_:)), #selector(toggleItalic(_:)), #selector(toggleUnderline(_:)), #selector(toggleBulletList(_:)),
        #selector(toggleNumberedList(_:)), #selector(toggleBlockQuote(_:)), #selector(insertLink(_:)),
    ]

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
                let data = try await client.attachmentData(for: originalID, attachmentID: part.info.id,
                                                           expectedSize: part.info.sizeBytes, progress: nil)
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
            sendFailure: sendFailure,
            continuesDraft: continuesDraft
        )
    }

    private func restore(_ draft: ComposeDraft) {
        draftID = draft.id
        continuesDraft = draft.continuesDraft
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
        hasStoredDraft = ComposeDraftStore.shared.contains(id: draft.id)
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

    @objc func attachFile(_ sender: Any?) {
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

    @objc func send(_ sender: Any?) {
        guard !isSending, !isPrefilling, validateRecipients() else {
            NSSound.beep()
            return
        }
        if subjectField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let window {
            AppAlert.sendWithoutSubject.present(on: window) { [weak self] choice in
                guard let self else { return }
                if choice == 1 {
                    self.performSend()
                } else {
                    self.window?.makeFirstResponder(self.subjectField)
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
                // The provider's draft this one continued goes to Trash, as the reader's Discard sends it, but only
                // once the message has left: an Undo inside the window must find it still in Drafts (§5.19, §5.31).
                let client = self.client
                let continued = self.continuesDraft
                self.closesWithoutSaving = true
                self.close()
                UndoSendPanel.show(client: client, accounts: self.accounts, sendID: sendID, draft: sent,
                                   undoWindow: Self.undoWindow, onSent: continued.map { original in
                    { Self.discardContinuedDraft(original, client: client) }
                })
            } catch {
                Self.logger.error("Queueing a send failed: \(String(describing: error))")
                self.setSending(false)
                self.sendFailure = "Couldn't send: the message couldn't be added to the outbox."
            }
        }
    }

    private static func discardContinuedDraft(_ original: MessageID, client: MailClient) {
        do {
            try client.perform(.trash, on: [original])
        } catch {
            let failure = error as NSError
            logger.error("Discarding the continued draft failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
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

    /// Send is disabled without a valid recipient (§5.23); its tooltip says what to fix. Send and ⌘↩ both
    /// validate, so an invalid address beside a valid one lands on the field to fix instead of sending.
    private func updateSendEnabled() {
        let fields = [toField, ccField, bccField]
        let readiness = ComposeSendReadiness.evaluate(tokens: fields.flatMap(\.addresses), pendingText: fields.map(\.pendingText))
        let button = bar.sendButton
        button.toolTip = readiness.tooltip
        button.isEnabled = isSending || (!isPrefilling && readiness.isEnabled)
    }

    // MARK: Discarding

    /// Message › Discard Draft… (§5.20): the one way to throw a draft away, since closing keeps it. The alert
    /// is AppAlert's composer form (§5.33: “Keep Writing” default and Esc, “Discard” destructive).
    @objc func discardDraft(_ sender: Any?) {
        guard let window, !isSending else { return }
        AppAlert.discardDraft(recipient: currentDraft().firstRecipientName).present(on: window) { [weak self] choice in
            guard choice == 1, let self else { return }
            self.confirmDiscard()
        }
    }

    /// Presents `alert` as a sheet on `window` with Esc answering `escapeAnswers`. NSAlert gives Esc only to a
    /// button titled “Cancel”, and a button holds one key equivalent (a hidden button's never fires), so the
    /// sheet's Esc is caught by a local monitor that lives as long as the sheet.
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

    /// Closes the window and keeps nothing: its draft was discarded elsewhere, or its account was removed.
    func closeWithoutSaving() {
        autosaveTimer?.invalidate()
        closesWithoutSaving = true
        close()
    }

    // MARK: Menu validation

    /// The composer's Message and Format items (§5.35): what does not apply now is disabled, never hidden.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let action = menuItem.action else { return true }
        if Self.formatCommands.contains(action) {
            return !isSending && !KeyboardRouter.isTextInput(window?.firstResponder)
        }
        switch action {
        case #selector(discardDraft(_:)), #selector(attachFile(_:)), #selector(addCcField(_:)), #selector(addBccField(_:)):
            return !isSending
        case #selector(send(_:)):
            return !isSending && bar.sendButton.isEnabled
        case #selector(toggleFormatRow(_:)):
            menuItem.title = content.showsFormatRow ? "Hide Format Row" : "Show Format Row"
            return true
        default:
            return true
        }
    }

    // MARK: NSWindowDelegate

    /// Closing never asks (§5.20): content worth keeping is saved before the window goes, nothing is kept
    /// otherwise. While a send is starting the window stays; the undo panel replaces it at once.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closesWithoutSaving { return true }
        guard !isSending else { return false }
        keepDraftNow()
        return true
    }

    /// The synchronous save behind closing and quitting: content worth keeping is written before returning,
    /// a draft that no longer holds anything worth keeping is removed.
    private func keepDraftNow() {
        autosaveTimer?.invalidate()
        if isWorthKeeping {
            ComposeDraftStore.shared.saveNow(currentDraft())
        } else if hasStoredDraft {
            ComposeDraftStore.shared.remove(id: draftID)
        }
    }

    /// Only a window that is still open saves: a minimized one counts, a closed one already saved or was
    /// discarded, and must not bring back a draft that has since been sent from a reopened window.
    @objc private func applicationWillTerminate(_ note: Notification) {
        guard !closesWithoutSaving, !isSending,
              ComposeWindowRegistry.shared.openControllers.contains(where: { $0 === self }) else { return }
        keepDraftNow()
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
        guard let window, !LaunchOptions().isWindowSnapshot else { return }
        let content = window.contentRect(forFrameRect: window.frame).size
        UserDefaults.standard.set(NSStringFromSize(content), forKey: Self.sizeDefaultsKey)
    }

    private static func savedSize() -> NSSize? {
        // A snapshot draws the default 640 × 600 (§5.20), whatever size the user left the composer at.
        guard !LaunchOptions().isWindowSnapshot else { return nil }
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

/// The composer's window: Esc never closes it (§6.1), it reports focus changes to its controller, and Edit ›
/// Undo undoes typing when the focused text can, else cancels the newest counting undo-send panel (“Undo
/// Send”, §6.1 rows 1–2; the main window's toasts are not reachable from here).
@MainActor
final class ComposeWindow: NSWindow {
    /// Every focus change goes through here (clicks, Tab, code), so the rows can redraw their rings.
    var onFirstResponderChange: (() -> Void)?

    private var responderChangeDepth = 0

    private var undoTarget: UndoPrecedence.Target {
        let textCanUndo = KeyboardRouter.isTextInput(firstResponder) && undoManager?.canUndo == true
        return UndoPrecedence.commandZ(textCanUndo: textCanUndo, sends: UndoSendPanel.liveSends, toast: nil, graceGroup: nil)
    }

    @objc func undo(_ sender: Any?) {
        switch undoTarget {
        case .typing: undoManager?.undo()
        case .send(let id): UndoSendPanel.panel(sendID: id)?.undo()
        case .group, .nothing: NSSound.beep()
        }
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(undo(_:)) else { return super.validateMenuItem(menuItem) }
        switch undoTarget {
        case .typing:
            menuItem.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return true
        case .send:
            menuItem.title = "Undo Send"
            return true
        case .group, .nothing:
            menuItem.title = "Can't Undo"
            return false
        }
    }

    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        responderChangeDepth += 1
        let changed = super.makeFirstResponder(responder)
        responderChangeDepth -= 1
        // A field editor that ends editing makes the window itself first responder for a moment, from inside
        // the outer call (`endEditingFor:`). Reporting that moment would tell a recipient field it lost focus
        // while a click or ← is selecting one of its tokens, which drops the selection; only the settled
        // responder is reported.
        if responderChangeDepth == 0 { onFirstResponderChange?() }
        return changed
    }

    override func cancelOperation(_ sender: Any?) {}
}

/// The Subject field: borderless `composeSubject` (New York 15 pt, its sans twin under the SF Pro font or for
/// scripts New York lacks) in `ink`, an `accent` caret, no ring of its own (the row draws the inset ring). A
/// Font switch re-sets it at once, in every open composer, mid-edit included.
@MainActor
private final class ComposeSubjectField: NSTextField {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        // Opaque on the row's `paper`: over a clear background AppKit set the New York 15 regular subject a
        // visible step heavier than the specimen (§5.20), as if semibold.
        drawsBackground = true
        backgroundColor = .qPaper
        focusRingType = .none
        textColor = .qInk
        lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        cell?.isScrollable = true
        updateFont()
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ComposeSubjectField is built in code")
    }

    func updateFont() {
        let font = QuireFont.font(.composeSubject, for: stringValue)
        guard self.font != font else { return }
        self.font = font
        // While the subject is being edited the field editor draws it, with its own font and typing attributes.
        if let editor = currentEditor() as? NSTextView {
            editor.font = font
            editor.typingAttributes[.font] = font
        }
    }

    @objc private func environmentDidChange(_ note: Notification) {
        updateFont()
        superview?.needsLayout = true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted, let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = .qAccent
        }
        return accepted
    }
}
