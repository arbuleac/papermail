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

    let client: MailClient
    let accounts: [Account]
    let mode: ComposeMode
    private(set) var account: Account
    /// This message's identity in `ComposeDraftStore`.
    private(set) var draftID = UUID()
    /// The provider's draft this message continues (Continue Editing on a synced Drafts row); sending it
    /// discards the provider's copy, so Drafts never keeps the original beside the sent message.
    private(set) var continuesDraft: MessageID?

    /// The account the message is sent from.
    var accountID: AccountID { account.id }

    /// The body as plain text (the app's tests read it).
    var bodyText: String { textView.string }

    /// The body's editor (the app's tests type into it).
    var bodyEditor: ComposeTextView { textView }

    /// Everything the window holds, as a kept draft would (the app's tests read the fields through it).
    var contents: ComposeDraft { currentDraft() }

    /// What the bottom bar's status says now (the app's tests read it).
    var status: ComposeStatus? { statusBoard.current }

    /// Send was pressed and the message is not yet handed over: the button shows it is sending (the app's tests read it).
    var sendIsStarting: Bool { isSending }

    /// The message this composer replies to (not a forward): the reader disables its quick reply while one
    /// of its conversation's messages has a reply open here (§5.18).
    var repliesTo: MessageID? {
        if case .reply(let id, _) = mode { return id }
        return nil
    }

    let content = ComposeContentView()
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
    private(set) var isSending = false
    private var closesWithoutSaving = false
    private var statusBoard = ComposeStatusBoard() {
        didSet { if oldValue != statusBoard { showStatus() } }
    }
    private var autosaveTimer: Timer?
    /// A draft of this window is on disk, so “nothing worth keeping” must remove it.
    private var hasStoredDraft = false
    private var linkPopover: ComposeLinkPopover?
    /// Help me write on the body of a reply (§5.56), made the first time it is reached (`bodyWriteSession`).
    var writeSession: WriteSession?
    /// While Help me write streams a reply into the body, the user's own edits wait (`textView(_:shouldChangeTextIn:…)`),
    /// and so does everything else that would take the half-written reply or edit around it: Send, ⌘↩, Send and Archive
    /// and Send Later, which would send it; From, whose signature swap the body would refuse; and the other fields,
    /// whose edits the silenced undo would not record (§5.56). The attachment strip is not the body: Attach Files…, a drop
    /// or a pasted file still attach.
    var refusesBodyEdits = false {
        didSet {
            guard oldValue != refusesBodyEdits else { return }
            updateEditLock()
            updateSendEnabled()
        }
    }
    private var statusObservation: StoreObservation?
    /// The body holds, or held, a signature this window put there, or is a reopened draft left as the user had it.
    /// A From change then replaces only a signature still in the body: one the user deleted is not added again.
    private var signaturePlaced = false
    /// Set while a From change replaces the signature, so that edit is not taken for the user's own (§5.20 Status).
    private var isReplacingSignature = false
    /// Send's drop-down (§5.23): choosing an action makes it every Send button's default; a row's key pressed while it is
    /// open sends as ⌘↩ or ⇧⌘↩ would; a Send Later time schedules this message for it.
    private lazy var sendActionMenu = SendActionMenu(choose: { SendActionPreference.choose($0) },
                                                     send: { [weak self] action in self?.send(fromMenu: action) },
                                                     sendLater: { [weak self] date in self?.sendLater(at: date) })

    // MARK: Presenting

    /// Opens a composer and keeps it alive until its window closes. A reply or forward that was kept as a
    /// draft opens with what was written; one already open comes forward.
    ///
    /// `body` is text already written for it (the quick reply's, §5.18): it opens in the editor with the caret
    /// at its end, below anything a kept draft held. With `attach`, the Attach Files panel follows at once; `dropped` is
    /// what was dropped on the quick reply, attached as a drop on this window would attach it.
    @discardableResult
    static func present(client: MailClient, account: Account, accounts: [Account], mode: ComposeMode, body: String = "",
                        attach: Bool = false, dropped: [AttachmentDropItem] = []) -> ComposeWindowController {
        let typed = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : body
        let controller: ComposeWindowController
        var caret: Int?
        // For analytics: a window opened, and as what; a kept draft's window only brought forward opens none.
        let started: AnalyticsSignal.ComposeKind?
        // A reply scheduled with Send Later keeps its draft until it goes; R again starts another reply rather than
        // reopening that one, which would leave the same message scheduled and open for sending at once.
        if var kept = ComposeDraftStore.shared.keptDraft(for: mode, accounts: accounts),
           !SendLaterOutbox.heldDraftIDs(in: client.store).contains(kept.id) {
            if !typed.isEmpty {
                let joined = ComposeSignature.adding(ComposeTextView.plainBody(typed), to: kept.body)
                kept.body = joined.body
                caret = joined.caret
            }
            let reopened = reopen(client: client, accounts: accounts, draft: kept)
            controller = reopened.controller
            started = reopened.opened ? .draft : nil
        } else {
            started = AnalyticsSignal.ComposeKind(mode)
            controller = ComposeWindowController(client: client, account: account, accounts: accounts, mode: mode)
            caret = controller.startBody(typed: typed.isEmpty ? nil : ComposeTextView.plainBody(typed))
            controller.show()
            controller.beginPrefill()
        }
        if !typed.isEmpty {
            controller.textView.setSelectedRange(NSRange(location: caret ?? (controller.textView.string as NSString).length, length: 0))
            controller.draftChanged(body: true)
        }
        if !dropped.isEmpty { controller.attachDropped(dropped) }
        if attach { controller.attachFile(nil) }
        if let started { Analytics.send(.composeStarted(started, .app, Analytics.trigger)) }
        return controller
    }

    /// A new message to `address` (a token's context menu, New Message).
    @discardableResult
    static func presentNew(client: MailClient, account: Account, accounts: [Account], to address: EmailAddress) -> ComposeWindowController {
        let controller = ComposeWindowController(client: client, account: account, accounts: accounts, mode: .new)
        controller.toField.addresses = [address]
        controller.startBody(typed: nil)
        controller.show()
        controller.window?.makeFirstResponder(controller.subjectField)
        Analytics.send(.composeStarted(.new, .app, Analytics.trigger))
        return controller
    }

    /// A new message from a mail link another app opened (`mailto:`, spec §5.20). What the link filled in is the
    /// window's starting point, as a reply's prefill is, so closing it untouched keeps no draft; nothing is sent
    /// until the user sends it. Focus goes to the first of To and Subject the link left empty, else to the end of
    /// the body.
    @discardableResult
    static func present(client: MailClient, account: Account, accounts: [Account], link: MailtoLink) -> ComposeWindowController {
        let controller = ComposeWindowController(client: client, account: account, accounts: accounts, mode: .new)
        let bodyEnd = controller.fill(from: link)
        controller.show()
        let subjectIsEmpty = link.subject.trimmingCharacters(in: .whitespaces).isEmpty
        if !link.to.isEmpty, subjectIsEmpty {
            controller.window?.makeFirstResponder(controller.subjectField)
        } else if !link.to.isEmpty {
            // The end of the link's body, above the signature.
            controller.textView.setSelectedRange(NSRange(location: bodyEnd, length: 0))
        }
        Analytics.send(.composeStarted(.new, .mailLink, nil))
        return controller
    }

    /// A new message from a Services menu item (spec §5.20 Services): the selected text as its body, above the signature,
    /// or the files attached through the same path as a drop, so a folder or an unreadable file is skipped with the
    /// rejected-drop status. As for a mail link, what the service filled in is the window's starting point, so closing
    /// it untouched keeps no draft. Focus goes to To, which no service fills.
    @discardableResult
    static func present(client: MailClient, account: Account, accounts: [Account], service: ServiceRequest) -> ComposeWindowController {
        let controller = ComposeWindowController(client: client, account: account, accounts: accounts, mode: .new)
        controller.fill(from: service)
        controller.show()
        Analytics.send(.composeStarted(.new, .service, nil))
        return controller
    }

    /// Reopens a draft: an undone send or a kept draft, exactly as it was; its window comes forward if it is
    /// already open.
    @discardableResult
    static func present(client: MailClient, accounts: [Account], draft: ComposeDraft) -> ComposeWindowController {
        reopen(client: client, accounts: accounts, draft: draft).controller
    }

    /// `present(client:accounts:draft:)`, saying whether a window opened rather than one already open came forward.
    private static func reopen(client: MailClient, accounts: [Account], draft: ComposeDraft) -> (controller: ComposeWindowController, opened: Bool) {
        if let open = ComposeWindowRegistry.shared.openControllers.first(where: { $0.draftID == draft.id }) {
            open.window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return (open, false)
        }
        let controller = ComposeWindowController(client: client, account: draft.account, accounts: accounts, mode: draft.mode)
        controller.restore(draft)
        controller.show()
        return (controller, true)
    }

    /// Opens the kept draft `id` (the Drafts view's Continue Editing); false when it is gone.
    @discardableResult
    static func reopenKeptDraft(id: UUID, client: MailClient, accounts: [Account]) -> Bool {
        guard let draft = ComposeDraftStore.shared.draft(id: id, accounts: accounts) else { return false }
        if reopen(client: client, accounts: accounts, draft: draft).opened {
            Analytics.send(.composeStarted(.draft, .app, Analytics.trigger))
        }
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
        content.onDrop = { [weak self] items in self?.attachDropped(items) }
        // A drop while the message is being handed over, or the window is going, would be thrown away: none is offered.
        content.acceptsDrops = { [weak self] in self.map { !$0.isSending && !$0.closesWithoutSaving } ?? false }
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
            Quire.Layout.Composer.bodyPadTop + 2 * textView.lineHeight)
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
        // Files pasted or dropped on the text that are not all pictures attach, as files dropped anywhere else do.
        textView.onAttachFiles = { [weak self] urls in self?.addAttachments(from: urls) }
        textView.onAttachFromMail = { [weak self] items in self?.attachDropped(items) }
        // The autosave before a picture was ready left it out; the next one takes it in.
        textView.onPictureReady = { [weak self] in self?.scheduleAutosave() }
        quoteView.onHeightChange = { [weak self] in self?.bodyDocument.needsLayout = true }

        bar.sendButton.target = self
        bar.sendButton.action = #selector(send(_:))
        bar.sendOptionsButton.target = self
        bar.sendOptionsButton.action = #selector(showSendOptions(_:))
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
        // A drop-down in any composer or the quick reply changes what this Send does too (§5.23).
        NotificationCenter.default.addObserver(self, selector: #selector(sendActionDidChange(_:)),
                                               name: SendActionPreference.didChange, object: nil)
    }

    /// The Tab loop (§5.20): From → To → Cc → Bcc → Subject → Body → attachment chips → Send → Send's drop-down → Attach →
    /// Format → the format toggles → From. The Cc and Bcc buttons join it only with Full Keyboard Access.
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
        loop += [bar.sendButton, bar.sendOptionsButton, bar.attachButton, bar.formatButton]
        if content.showsFormatRow { loop += content.formatRow.buttons.map(\.button) }
        for (index, view) in loop.enumerated() {
            view.nextKeyView = loop[(index + 1) % loop.count]
        }
        window?.initialFirstResponder = toField.keyView
    }

    private func populateFromPopup() {
        fromPopup.titles = accounts.map(AccountLabels.senderTitle(for:))
        selectAccountInFromPopup()
        fromPopup.isEnabled = accounts.count > 1 && !isHeld && !refusesBodyEdits
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
        // The Write control's state is read from this Mac as the window comes forward (spec §3b: no provider is asked).
        if note.name == NSWindow.didBecomeKeyNotification { bodyWriteSession?.refresh() }
        if note.name == NSWindow.didResignKeyNotification {
            for field in [toField, ccField, bccField] { field.closeAutocomplete() }
        }
    }

    // MARK: Header actions

    @objc private func fromChanged(_ sender: Any?) {
        // A reply streaming in keeps the From it was asked under: the body would refuse the new signature.
        guard !refusesBodyEdits else {
            selectAccountInFromPopup()
            NSSound.beep()
            return
        }
        guard accounts.indices.contains(fromPopup.selectedIndex) else { return }
        let chosen = accounts[fromPopup.selectedIndex]
        guard chosen.id != account.id else { return }
        account = chosen
        fromPopup.inkMark = .dot(slot: account.inkSlot)
        replaceSignature()
        observeStatus()
        draftChanged(body: false)
    }

    /// Chooses the From account as the popup does (the app's tests).
    func chooseFrom(_ id: AccountID) {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        fromPopup.selectedIndex = index
        fromChanged(fromPopup)
    }

    // MARK: Signature (§5.20)

    /// Starts a new message's body: `typed` (a mail link's body, the quick reply's text), then the sending account's
    /// signature one empty line below it, when it has one. Returns where the caret goes: the end of `typed`, above the
    /// signature. What the composer put there is not the user's work, so it stays out of what is worth keeping.
    @discardableResult
    private func startBody(typed: NSAttributedString?) -> Int {
        let signature = ComposeSignature.body(html: account.signature)
        let start = ComposeSignature.startingBody(typed: typed, signature: signature)
        if start.body.length > 0 { textView.replaceContents(with: start.body) }
        textView.setSelectedRange(NSRange(location: start.caret, length: 0))
        signaturePlaced = signature != nil
        return start.caret
    }

    /// From changed: the signature still in the body becomes the new account's, or goes with the empty line before it
    /// when that account has none. Text typed inside it goes with it (the whole marked range is replaced); text typed
    /// before or after it stays. A signature the user deleted is not added again, and a body that never had one (the
    /// previous account had none) gets the new account's below what was written. One undoable change.
    private func replaceSignature() {
        guard let storage = textView.textStorage else { return }
        let signature = ComposeSignature.body(html: account.signature)
        let text = storage.string as NSString
        let selection = textView.selectedRange()
        let edit: (range: NSRange, replacement: NSAttributedString)
        if let current = ComposeSignature.range(in: storage) {
            if let signature {
                edit = (current, signature)
            } else {
                let start = ComposeSignature.separatorStart(before: current, in: text)
                edit = (NSRange(location: start, length: NSMaxRange(current) - start), NSAttributedString())
            }
        } else if !signaturePlaced, let signature {
            edit = (NSRange(location: text.length, length: 0), ComposeSignature.startingBody(typed: nil, signature: signature).body)
        } else {
            return
        }
        // Clicking From leaves focus in an open link popover, whose range would then point at other text.
        linkPopover?.close()
        guard textView.shouldChangeText(in: edit.range, replacementString: edit.replacement.string) else { return }
        isReplacingSignature = true
        textView.breakUndoCoalescing()
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        textView.didChangeText()
        textView.breakUndoCoalescing()
        isReplacingSignature = false
        signaturePlaced = signature != nil
        // A selection in what was written stays on the same text; one inside the old signature goes to where it began.
        if NSMaxRange(selection) <= edit.range.location {
            textView.setSelectedRange(selection)
        } else if selection.location >= NSMaxRange(edit.range) {
            textView.setSelectedRange(NSRange(location: selection.location + edit.replacement.length - edit.range.length, length: selection.length))
        } else {
            textView.setSelectedRange(NSRange(location: edit.range.location, length: 0))
        }
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
        // This window's accounts are as they were when it opened; the new one takes them as they are now, so a
        // signature changed in Settings since then is the one it starts with.
        let current = ((try? client.store.accounts()) ?? []).sorted { $0.addedAt < $1.addedAt }
        if let from = current.first(where: { $0.id == account.id }) {
            Self.presentNew(client: client, account: from, accounts: current, to: address)
        } else {
            Self.presentNew(client: client, account: account, accounts: accounts, to: address)
        }
    }

    private func updateTitle() {
        let subject = subjectField.stringValue.trimmingCharacters(in: .whitespaces)
        window?.title = subject.isEmpty ? "New Message" : subject
    }

    private func perform(_ command: ComposeContentView.Command) {
        switch command {
        case .send: send(nil)
        case .sendAndArchive: sendAndArchive(nil)
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
            // Esc closes a composer holding nothing worth keeping (§6.1).
            escapeComposer(nil)
            return true
        default:
            return false
        }
    }

    // MARK: NSTextViewDelegate (body)

    /// Esc in the body goes to the composer, which closes only if it holds nothing worth keeping (§6.1); ⌥Esc still
    /// completes words. Answered here, as the body's delegate, so the Settings signature field, the same text view
    /// outside a composer, keeps NSTextView's own Esc.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        escapeComposer(textView)
        return true
    }

    /// While Help me write streams a reply into the body, typing, pasting and a From change's signature wait: the reply and
    /// the user's own edits never interleave (§5.56).
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        !(textView === self.textView && refusesBodyEdits)
    }

    func textDidChange(_ notification: Notification) {
        // A From change replacing the signature reports itself as a header edit (`fromChanged`).
        if !isReplacingSignature { draftChanged(body: true) }
        updateFormatState()
        bodyWriteSession?.userDidEdit()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        updateFormatState()
        if (notification.object as? NSTextView) === textView { bodyWriteSession?.selectionDidChange() }
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
        // A reply streaming into the body takes no formatting or link until it ends, and the keyboard stays where it is.
        guard !refusesBodyEdits else {
            NSSound.beep()
            return
        }
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
        guard !refusesBodyEdits else {
            NSSound.beep()
            return
        }
        linkPopover = textView.presentLinkPopover(in: content) { [weak self] in
            self?.linkPopover = nil
            self?.updateFormatState()
        }
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
        // The body is the user's as they left it, signature or none: nothing is added to it, now or on a From change.
        signaturePlaced = true
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

    /// A mail link's fields, in plain text: the body takes no formatting and no quote; it is a new message, so the
    /// account's signature follows it (§5.20). Returns the end of the link's body.
    private func fill(from link: MailtoLink) -> Int {
        toField.addresses = link.to
        ccField.addresses = link.cc
        bccField.addresses = link.bcc
        if !link.cc.isEmpty { showRow(ccRow, button: ccButton) }
        if !link.bcc.isEmpty { showRow(bccRow, button: bccButton) }
        subjectField.stringValue = link.subject
        subjectField.updateFont()
        let bodyEnd = startBody(typed: link.body.isEmpty ? nil : ComposeTextView.plainBody(link.body))
        baseline = currentDraft().fingerprint
        updateTitle()
        updateSendEnabled()
        return bodyEnd
    }

    /// A service's text or files. The caret waits at the end of the text, above the signature, for when the user gets
    /// to the body.
    private func fill(from service: ServiceRequest) {
        switch service {
        case .selection(let text):
            startBody(typed: text.isEmpty ? nil : ComposeTextView.plainBody(text))
        case .files(let urls):
            startBody(typed: nil)
            attach(urls)
        }
        baseline = currentDraft().fingerprint
        updateTitle()
        updateSendEnabled()
    }

    /// Content worth keeping: anything the user typed, chose or attached; at most the prefilled reply, its folded
    /// original and the signature is not (§5.20).
    private var isWorthKeeping: Bool {
        let fingerprint = currentDraft().fingerprint
        guard fingerprint != baseline else { return false }
        // The signature is the composer's, not the user's work.
        let typed = !fingerprint.bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        // A reply streaming in (§5.56) is kept once it is the user's, as one edit; until then the draft waits.
        if refusesBodyEdits {
            scheduleAutosave()
            return
        }
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

    /// Format › Insert Picture… (⌥⌘I; §5.20, Images in the body): the keyboard's way to put picture files into the text,
    /// at the body's caret, as pasting them would; Attach Files… puts files on the strip instead. The panel lists
    /// pictures only.
    @objc func insertPicture(_ sender: Any?) {
        // A reply streaming into the body refuses the picture as it refuses typing (§5.56): the item waits for it.
        guard let window, !isSending, !refusesBodyEdits else {
            if refusesBodyEdits { NSSound.beep() }
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image]
        panel.prompt = "Insert"
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .OK, let self, !self.isSending, !self.refusesBodyEdits else { return }
                self.window?.makeFirstResponder(self.textView)
                self.textView.insertPictureFiles(panel.urls)
            }
        }
    }

    /// What a drop on the window brings (§5.20), or the quick reply's (§5.18): files as Attach Files… attaches them, and
    /// attachments dragged from a message (§5.17) as chips that load until their bytes are in. The user's change to the
    /// draft either way.
    func attachDropped(_ items: [AttachmentDropItem]) {
        guard !isSending else { return }
        var urls: [URL] = []
        var references: [MailAttachmentReference] = []
        for item in items {
            switch item {
            case .file(let url): urls.append(url)
            case .mail(let reference): references.append(reference)
            }
        }
        let attachedFiles = !urls.isEmpty && attach(urls)
        let resolved = references.compactMap(resolve)
        for reference in resolved { attachFromMail(reference) }
        if resolved.count < references.count { statusBoard.post(.droppedAttachmentsGone(count: references.count - resolved.count)) }
        if attachedFiles || !resolved.isEmpty { draftChanged(body: false) }
    }

    /// The app's own attachment as the store lists it: any app can write the type to a pasteboard, so the message and
    /// file a reference names are only taken when a stored message lists that file, and the name, type and size are the
    /// store's, never the pasteboard's. Nil when no stored message lists it (deleted meanwhile, or never the app's).
    private func resolve(_ reference: MailAttachmentReference) -> MailAttachmentReference? {
        let listed = (try? client.store.attachments(of: reference.message)) ?? nil
        guard let info = listed?.first(where: { $0.id == reference.info.id && !$0.isInline }) else { return nil }
        return MailAttachmentReference(message: reference.message, info: info)
    }

    /// Fetches of attachments dragged from a message, by chip: Send waits for them.
    private var mailFetches: [UUID: Task<Void, Never>] = [:]
    /// A Send or Send Later waiting for those fetches (§5.20): it goes once the last file is in.
    private var sendAfterDrops: (() -> Void)?

    /// An attachment dragged from a message (§5.17): its chip joins the strip at once, loading, and is ready once the engine
    /// hands over the bytes (this Mac's copy, or a download, as the reader's Download fetches it). One that cannot be
    /// fetched leaves the strip again and the status says so; one the user removed meanwhile is forgotten.
    private func attachFromMail(_ reference: MailAttachmentReference) {
        let placeholder = ComposeAttachment.loading(info: reference.info, contentID: nil)
        attachments.append(placeholder)
        let client = client
        mailFetches[placeholder.id] = Task { [weak self] in
            var bytes: Data?
            do {
                bytes = try await client.attachmentData(for: reference.message, attachmentID: reference.info.id,
                                                        expectedSize: reference.info.sizeBytes, progress: nil)
            } catch {
                let failure = error as NSError
                Self.logger.error("Compose could not fetch a dropped attachment: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
            }
            // Removed meanwhile (its entry went with its chip), or the window closed: nothing more to do.
            guard let self, self.mailFetches.removeValue(forKey: placeholder.id) != nil else { return }
            guard let bytes else {
                self.attachments.removeAll { $0.id == placeholder.id }
                if !self.content.strip.hasChips, self.window?.firstResponder === self.content.strip { self.window?.makeFirstResponder(self.textView) }
                self.statusBoard.post(.droppedAttachmentFailed(name: reference.filename))
                self.dropFetchEnded(failed: true)
                return
            }
            self.replaceAttachment(placeholder.id) { attachment in
                attachment.source = .data(bytes)
                attachment.sizeBytes = bytes.count
                attachment.state = .ready
            }
            self.draftChanged(body: false)
            self.dropFetchEnded(failed: false)
        }
    }

    /// Send and Send Later wait for attachments dragged from a message that are still arriving (§5.20). The button shows
    /// it is sending and the fields hold still, so the message that goes is the one checked; the window still closes
    /// (keeping the draft), Esc stops the wait, and a loading chip can be removed, which lets the send go without it. One
    /// that could not be fetched stops the send, its status saying which, so nothing leaves without a file the user added.
    /// `proceed` runs at once when none is arriving; asked again while waiting, the latest action is the one that runs.
    private func afterDroppedAttachments(_ proceed: @escaping () -> Void) {
        guard !mailFetches.isEmpty else { return proceed() }
        sendAfterDrops = proceed
        setHeld(true)
    }

    /// One dropped attachment's fetch ended, or its chip was removed: a waiting send stops at a failure and goes once
    /// nothing is left to arrive.
    private func dropFetchEnded(failed: Bool) {
        guard let proceed = sendAfterDrops else { return }
        if failed {
            stopWaitingToSend()
            NSSound.beep()
        } else if mailFetches.isEmpty {
            stopWaitingToSend()
            proceed()
        }
    }

    private func stopWaitingToSend() {
        sendAfterDrops = nil
        setHeld(false)
    }

    /// Send waits for dropped attachments (the app's tests read it).
    var isWaitingToSend: Bool { sendAfterDrops != nil }

    /// Attaches the readable files as the user's change to the draft.
    private func addAttachments(from urls: [URL]) {
        guard !isSending else { return }
        if attach(urls) { draftChanged(body: false) }
    }

    /// Attaches the readable files; folders and unreadable files become the rejected-drop status (§5.20),
    /// never an alert. Returns whether anything was attached.
    @discardableResult
    private func attach(_ urls: [URL]) -> Bool {
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
        if !added.isEmpty { attachments.append(contentsOf: added) }
        if !rejected.isEmpty { statusBoard.post(.rejectedDrop(rejected)) }
        return !added.isEmpty
    }

    /// The demo's compose snapshot (`--snapshot-compose`, spec §5.43): its line of text and picture at the caret, typed
    /// and pasted as a person would, so the snapshot shows a picture in the body (§5.20, Images in the body).
    ///
    /// The sample is the snapshot's, not the user's: this composer keeps no draft, so the next run does not reopen it
    /// with the sample in it (and write the sample a second time), and the demo's Drafts never show it. A reply that
    /// already holds the sample (kept by a run before this rule) is left as it is.
    func writeDemoSample() {
        keepNoDraft()
        guard !textView.string.contains(DemoComposerSample.text),
              let picture = ComposeImageAttachment.make(data: DemoComposerSample.picture, typeIdentifier: ComposerImageFormat.png.typeIdentifier,
                                                        filename: DemoComposerSample.pictureName) else { return }
        window?.makeFirstResponder(textView)
        textView.insertText(DemoComposerSample.text + "\n", replacementRange: textView.selectedRange())
        textView.insertPictures([picture])
    }

    /// A snapshot's composer keeps no draft: its sample is the snapshot's, not the user's.
    func keepNoDraft() {
        autosaveTimer?.invalidate()
        closesWithoutSaving = true
    }

    private func removeAttachment(id: UUID) {
        guard !isSending else { return }
        attachments.removeAll { $0.id == id }
        // A file still arriving from a message is not waited for any longer: a send waiting on it may go.
        if let fetch = mailFetches.removeValue(forKey: id) {
            fetch.cancel()
            dropFetchEnded(failed: false)
        }
        draftChanged(body: false)
        if !content.strip.hasChips, window?.firstResponder === content.strip { window?.makeFirstResponder(textView) }
    }

    // MARK: Sending

    /// What Send, ⌘↩ and Message › Send do now (§5.23): the default the drop-down chose, Send and Archive unless the user
    /// picked Send; a new message answers no conversation, so it only sends.
    var sendAction: SendAction {
        SendActionPreference.current.effective(answers: mode.originalMessageID != nil)
    }

    /// Send, ⌘↩ and Message › Send: the default action.
    @objc func send(_ sender: Any?) {
        send(as: sendAction)
    }

    /// ⇧⌘↩ and Message › Send and Archive: send, then archive the conversation the message answers, whatever Send does.
    @objc func sendAndArchive(_ sender: Any?) {
        send(as: .sendAndArchive)
    }

    /// A row's key pressed while the drop-down is open: the checked row's ⌘↩ does what Send does, Send and Archive's ⇧⌘↩
    /// always archives, as the keys do with the menu closed.
    private func send(fromMenu action: SendAction) {
        if action == SendActionPreference.current {
            send(nil)
        } else {
            sendAndArchive(nil)
        }
    }

    private func send(as action: SendAction) {
        guard !isSending, !isPrefilling, !refusesBodyEdits, validateRecipients() else {
            NSSound.beep()
            return
        }
        if subjectField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let window {
            AppAlert.sendWithoutSubject.present(on: window) { [weak self] choice in
                guard let self else { return }
                if choice == 1 {
                    self.performSend(action)
                } else {
                    self.window?.makeFirstResponder(self.subjectField)
                }
            }
            return
        }
        performSend(action)
    }

    /// Send's drop-down (§5.23): the two actions, the default checked, each with the key that does it now; choosing one
    /// makes it the default for every Send button and ⌘↩, and a click never sends. Hung from Send's face; tracks until
    /// dismissed.
    @objc func showSendOptions(_ sender: Any?) {
        guard !isSending, !refusesBodyEdits else { return }
        SendActionMenu.popUp(sendOptionsMenu(), from: bar.send)
    }

    /// The drop-down's menu as it opens now (the app's tests choose from it).
    func sendOptionsMenu() -> NSMenu {
        sendActionMenu.menu(current: SendActionPreference.current)
    }

    #if DEBUG
    /// The drop-down's builder, for a render of the menu with either choice (`SendSnapshotStates`).
    var debugSendActionMenu: SendActionMenu { sendActionMenu }
    #endif

    // MARK: Send Later

    /// ⇧⌘L and Message › Send Later… (§5.23): Send Later's times, hung from Send's face as its drop-down would be.
    @objc func sendLater(_ sender: Any?) {
        guard !isSending, !refusesBodyEdits, bar.sendButton.isEnabled else {
            NSSound.beep()
            return
        }
        SendActionMenu.popUp(sendLaterMenu(), from: bar.send)
    }

    /// The menu ⇧⌘L pops (the app's tests choose from it).
    func sendLaterMenu() -> NSMenu {
        sendActionMenu.laterMenu()
    }

    /// A Send Later time from the drop-down, or nil for Pick a Time…, which asks for one first.
    func sendLater(at date: Date?) {
        guard let date else {
            SendLaterPicker.present(window) { [weak self] chosen in
                guard let chosen else { return }
                self?.schedule(at: chosen)
            }
            return
        }
        schedule(at: date)
    }

    /// As Send checks a message before it goes: a recipient, then a subject (§5.20).
    private func schedule(at date: Date) {
        guard !isSending, !isPrefilling, !refusesBodyEdits, validateRecipients() else {
            NSSound.beep()
            return
        }
        if subjectField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let window {
            AppAlert.sendWithoutSubject.present(on: window) { [weak self] choice in
                guard let self else { return }
                if choice == 1 {
                    self.performSchedule(at: date)
                } else {
                    self.window?.makeFirstResponder(self.subjectField)
                }
            }
            return
        }
        performSchedule(at: date)
    }

    /// The message waits in the outbox until `date` (`MailClient.scheduleSend`), and its draft stays on this Mac, which
    /// the Drafts row stands in for: opening the row brings it back as written. The window closes and the main window
    /// says when it sends, with Undo. The draft is kept before the send is queued, so a send never waits without one.
    private func performSchedule(at date: Date) {
        guard mailFetches.isEmpty else { return afterDroppedAttachments { [weak self] in self?.performSchedule(at: date) } }
        autosaveTimer?.invalidate()
        var current = currentDraft()
        current.sendFailure = nil
        let draft = current
        let normalized = ComposeBodyNormalizer.normalize(draft.body)
        let pending = draft.attachments.filter(\.isSendable)
        setSending(true)

        Task { [weak self] in
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
            let message = draft.outgoingMessage(normalizedBody: normalized, loadedAttachments: outcome.parts)
            guard ComposeDraftStore.shared.saveNow(draft) else {
                self.setSending(false)
                self.sendFailure = "Couldn't schedule: the draft couldn't be kept on this Mac."
                return
            }
            self.hasStoredDraft = true
            do {
                let sendID = try self.client.scheduleSend(message, at: date, draftID: draft.id)
                Analytics.send(.sendLaterScheduled(.composer))
                let client = self.client
                let accounts = self.accounts
                self.closesWithoutSaving = true
                self.close()
                SendLaterScheduled(sendID: sendID, date: date) {
                    // Undo: the schedule goes and the composer comes back with what was written; too late, it is on its way.
                    guard (try? client.cancelSend(id: sendID)) == true else {
                        NSSound.beep()
                        return false
                    }
                    let kept = ComposeDraftStore.shared.draft(id: draft.id, accounts: accounts) ?? draft
                    ComposeWindowController.present(client: client, accounts: accounts, draft: kept)
                    return true
                }.post()
            } catch {
                Self.logger.error("Scheduling a send failed: \(String(describing: error))")
                self.setSending(false)
                self.sendFailure = "Couldn't schedule: the message couldn't be added to the outbox."
            }
        }
    }

    /// Send's tooltip and VoiceOver name as set now (the app's tests).
    var sendButtonHelp: (toolTip: String?, label: String?) { (bar.sendButton.toolTip, bar.sendButton.accessibilityLabel()) }

    @objc private func sendActionDidChange(_ note: Notification) {
        updateSendEnabled()
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

    private func performSend(_ action: SendAction) {
        guard mailFetches.isEmpty else { return afterDroppedAttachments { [weak self] in self?.performSend(action) } }
        autosaveTimer?.invalidate()
        let draft = currentDraft()
        let normalized = ComposeBodyNormalizer.normalize(draft.body)
        let pending = draft.attachments.filter(\.isSendable)
        setSending(true)

        Task { [weak self] in
            // A picture pasted just before Send may still be being prepared: it goes with the message, so Send waits for
            // it, the button showing it is sending (§5.20, Images in the body).
            await ComposeInlineImages.waitUntilPrepared(normalized)
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
                Analytics.send(.messageSent(.init(self.mode), archives: action.archives))
                // Queued: Send and Archive archives the conversation it answers now, as E would, and the panel's Undo
                // brings it back with the message (§5.23). A new message has none.
                let archive = action.archives
                    ? self.mode.originalMessageID.flatMap { SendArchive.archiveConversation(answering: $0, client: self.client) }
                    : nil
                // The outbox holds the message now; the panel keeps the draft for Undo and for a failure.
                ComposeDraftStore.shared.remove(id: self.draftID)
                // The provider's draft this one continued goes to Trash, as the reader's Discard sends it, but only
                // once the message has left: an Undo inside the window must find it still in Drafts (§5.19, §5.31).
                let client = self.client
                let continued = self.continuesDraft
                self.closesWithoutSaving = true
                self.close()
                UndoSendPanel.show(client: client, accounts: self.accounts, sendID: sendID, draft: sent,
                                   undoWindow: Self.undoWindow, archive: archive, onSent: continued.map { original in
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
        setHeld(sending)
    }

    /// The button shows the send under way and the fields hold still: while the message is handed over, and while a send
    /// waits for dropped attachments (`afterDroppedAttachments`).
    private func setHeld(_ held: Bool) {
        let held = held || isHeld
        bar.sendButton.isLoading = held
        textView.isEditable = !held
        updateEditLock()
        updateSendEnabled()
    }

    /// A send holds the window: while the message is handed over, and while it waits for dropped attachments.
    private var isHeld: Bool { isSending || sendAfterDrops != nil }

    /// The header fields, From and Send's drop-down take no change while a send is held or a reply streams in.
    private func updateEditLock() {
        let locked = isHeld || refusesBodyEdits
        bar.sendOptionsButton.isEnabled = !locked
        for field in [toField, ccField, bccField] { field.isLocked = locked }
        subjectField.isEditable = !locked
        fromPopup.isEnabled = accounts.count > 1 && !locked
    }

    /// Send is disabled without a valid recipient (§5.23); its tooltip says what to fix, and otherwise what Send does now
    /// (“Send and Archive  ⌘↩”), which VoiceOver hears as its name, though its label stays “Send”. Send and ⌘↩ both
    /// validate, so an invalid address beside a valid one lands on the field to fix instead of sending.
    private func updateSendEnabled() {
        let fields = [toField, ccField, bccField]
        let readiness = ComposeSendReadiness.evaluate(tokens: fields.flatMap(\.addresses), pendingText: fields.map(\.pendingText))
        let button = bar.sendButton
        let action = sendAction
        button.toolTip = readiness.isEnabled ? action.tooltip : readiness.tooltip
        // While sending, the button's own “Sending…” is its name.
        button.setAccessibilityLabel(button.isLoading ? nil : action.title)
        button.isEnabled = isSending || (!isPrefilling && !refusesBodyEdits && readiness.isEnabled)
    }

    // MARK: Discarding

    /// Message › Discard Draft… (§5.20): the one way to throw a draft away, since closing keeps it. The alert
    /// is AppAlert's composer form (§5.33: “Keep Writing” default and Esc, “Discard” destructive).
    @objc func discardDraft(_ sender: Any?) {
        // While a reply streams into the body the draft is not the user's to judge yet: Stop first (§5.56).
        guard let window, !isSending, !refusesBodyEdits else {
            if refusesBodyEdits { NSSound.beep() }
            return
        }
        AppAlert.discardDraft(recipient: currentDraft().firstRecipientName).present(on: window) { [weak self] choice in
            guard choice == 1, let self else { return }
            self.confirmDiscard()
        }
    }

    /// Presents `alert` as a sheet on `window` with Esc answering `escapeAnswers`. NSAlert gives Esc only to a
    /// button titled “Cancel”, and a button holds one key equivalent (a hidden button's never fires), so the
    /// sheet's Esc is caught by a local monitor that lives as long as the sheet.
    private func confirmDiscard() {
        // What Undo brings back is what the user wrote, never half a reply: a write still streaming is put back first.
        endHelpMeWrite()
        let draft = currentDraft()
        let client = client
        let accounts = accounts
        autosaveTimer?.invalidate()
        ComposeDraftStore.shared.remove(id: draftID)
        closesWithoutSaving = true
        close()
        let undo = ComposeDraftUndo(accountID: draft.account.id) {
            ComposeWindowController.present(client: client, accounts: accounts, draft: draft)
        }
        NotificationCenter.default.post(name: Self.draftDiscardedNotification, object: nil, userInfo: [Self.draftUndoKey: undo])
    }

    /// Esc, once no popover is left to close (§6.1): a composer holding nothing worth keeping (nothing typed, chosen or
    /// attached beyond the prefilled reply, its folded original and the signature) closes, keeping no draft; one
    /// holding the user's work stays open, since Esc must never throw work away. Every field and the window call it,
    /// so it answers wherever the keyboard is.
    @objc func escapeComposer(_ sender: Any?) {
        // Help me write takes Esc first: it stops a write, or closes its strip (§6.1).
        if writeSession?.escape() == true { return }
        // A send waiting for dropped attachments is stopped next; the message stays as written.
        if sendAfterDrops != nil { return stopWaitingToSend() }
        guard !isSending, !isWorthKeeping, !isTypingAnAddress else { return }
        window?.performClose(nil)
    }

    /// An address typed in To, Cc or Bcc that is not a token yet (or a token taken back to fix) is the user's work too,
    /// though the draft does not hold it until it becomes a token.
    private var isTypingAnAddress: Bool {
        [toField, ccField, bccField].contains { !$0.pendingText.trimmingCharacters(in: .whitespaces).isEmpty }
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
            return !isSending && !refusesBodyEdits && !KeyboardRouter.isTextInput(window?.firstResponder)
        }
        switch action {
        case #selector(attachFile(_:)), #selector(addCcField(_:)), #selector(addBccField(_:)):
            return !isSending
        case #selector(discardDraft(_:)), #selector(insertPicture(_:)):
            // Both act on the body, which a reply streaming in keeps until it ends (§5.56).
            return !isSending && !refusesBodyEdits
        case #selector(send(_:)), #selector(sendAndArchive(_:)), #selector(sendLater(_:)):
            return !isSending && !refusesBodyEdits && bar.sendButton.isEnabled
        case #selector(toggleFormatRow(_:)):
            menuItem.title = content.showsFormatRow ? "Hide Format Row" : "Show Format Row"
            return true
        case #selector(helpMeWrite(_:)), #selector(helpMeWriteWithInstructions(_:)):
            // New messages and forwards answer no one: the item says so rather than writing to nobody (§5.56).
            return validateHelpMeWrite(menuItem)
        default:
            return true
        }
    }

    // MARK: NSWindowDelegate

    /// To, Cc, Bcc and Subject edit in a field editor that hands dragged files and attachments to the window (§5.20).
    private lazy var fieldEditor = ComposeFieldEditor.make()

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        client is NSTextField ? fieldEditor : nil
    }

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
        // A reply still streaming in is not the user's yet: the body goes back to what they wrote before it is kept.
        endHelpMeWrite()
        // A picture still being prepared goes into this save: the window will not be there to save it later.
        textView.finishPreparingPictures()
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
        endHelpMeWrite()
        prefillTask?.cancel()
        for fetch in mailFetches.values { fetch.cancel() }
        mailFetches = [:]
        sendAfterDrops = nil
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
    /// The account the draft writes from: removing it takes the step out of the undo history, which ⌘Z otherwise reaches
    /// for as long as it holds the step (§6.1).
    let accountID: AccountID?
    private let action: @MainActor () -> Void

    init(accountID: AccountID? = nil, _ action: @escaping @MainActor () -> Void) {
        self.accountID = accountID
        self.action = action
    }

    func undo() {
        action()
    }
}

/// The composer's window: Esc closes it only while it holds nothing worth keeping (§6.1), it reports focus changes to its controller, and Edit ›
/// Undo undoes typing when the focused text can, else cancels the newest counting undo-send panel (“Undo
/// Send”, §6.1 rows 1–2; the main window's toasts are not reachable from here).
@MainActor
final class ComposeWindow: NSWindow {
    /// Every focus change goes through here (clicks, Tab, code), so the rows can redraw their rings.
    var onFirstResponderChange: (() -> Void)?

    private var responderChangeDepth = 0

    private var undoTarget: UndoPrecedence.Target {
        let textCanUndo = KeyboardRouter.isTextInput(firstResponder) && undoManager?.canUndo == true
        return UndoPrecedence.commandZ(textCanUndo: textCanUndo, sends: UndoSendPanel.liveSends, toast: nil, latestGroup: nil)
    }

    @objc func undo(_ sender: Any?) {
        if WriteSession.isStreaming(in: self) {
            NSSound.beep()
            return
        }
        switch undoTarget {
        case .typing: undoManager?.undo()
        case .send(let id): UndoSendPanel.panel(sendID: id)?.undo()
        case .group, .nothing: NSSound.beep()
        }
    }

    /// While Help me write streams a reply into a field here, Undo and Redo wait: the stack's text steps belong to the text
    /// as it was before the write, and the write ends in one step of its own (§5.56, §6.1).
    @objc func redo(_ sender: Any?) {
        if WriteSession.isStreaming(in: self) {
            NSSound.beep()
            return
        }
        undoManager?.redo()
    }

    /// Undo and Redo are disabled while a reply streams in (§6.1); nil when the item is neither or nothing streams.
    private func validateWhileWriting(_ menuItem: NSMenuItem) -> Bool? {
        guard menuItem.action == #selector(undo(_:)) || menuItem.action == #selector(redo(_:)), WriteSession.isStreaming(in: self) else {
            return nil
        }
        menuItem.title = menuItem.action == #selector(undo(_:)) ? "Can\u{2019}t Undo" : "Can\u{2019}t Redo"
        return false
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let answer = validateWhileWriting(menuItem) { return answer }
        guard menuItem.action == #selector(undo(_:)) else { return super.validateMenuItem(menuItem) }
        switch undoTarget {
        case .typing:
            menuItem.title = undoManager?.undoMenuItemTitle ?? "Undo"
            return true
        case .send(let id):
            menuItem.title = UndoSendPanel.panel(sendID: id)?.undoMenuTitle ?? SendAction.undoMenuTitle(archived: false)
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

    /// Esc with the keyboard on a control rather than in a field: the same rule as in the fields (§6.1).
    override func cancelOperation(_ sender: Any?) {
        (windowController as? ComposeWindowController)?.escapeComposer(sender)
    }
}

/// The Subject field: borderless `composeSubject` (New York 15 pt at Default, its sans twin under the SF Pro font or
/// for scripts New York lacks) in `ink`, an `accent` caret, no ring of its own (the row draws the inset ring). A
/// Font switch or a Text size (spec §4.15) re-sets it at once, in every open composer, mid-edit included.
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
        let font = QuireFont.font(.composeSubject, for: stringValue, textSize: QuireEnvironment.textSize)
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
            leaveTheFieldEditorsPointerToTheField()
        }
        return accepted
    }

    /// The I-beam over the field (§4.17), cut out of what lies on it (the autocomplete, the link popover), which AppKit's
    /// own could not be. None while a send locks it, which leaves it neither editable nor selectable.
    override func resetCursorRects() {
        if isEnabled, isSelectable { addTextPointerRects() }
    }
}
