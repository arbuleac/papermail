import AppKit
import SSCore
import os

/// The composer window. One window per message; `present` keeps it alive in `ComposeWindowRegistry` until
/// it closes. Reply and forward windows open immediately with the header fields filled from local metadata
/// and fetch the original body afterwards, so the user can start typing before the network answers.
@MainActor
final class ComposeWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// Seconds a send is held for undo. The shell sets it from the "Undo send" preference.
    static var undoWindow: TimeInterval = 5

    private static let sizeDefaultsKey = "ComposeWindowSize"
    private static let defaultSize = NSSize(width: 640, height: 560)
    private static let minimumSize = NSSize(width: 460, height: 360)
    private static let logger = Logger(subsystem: "io.supersparrow.mac", category: "compose")

    private let client: MailClient
    private let accounts: [Account]
    private let mode: ComposeMode
    private var account: Account

    private let fromPopup: NSPopUpButton
    private let toField: AddressTokenField
    private let ccField: AddressTokenField
    private let bccField: AddressTokenField
    private let ccBccButton: NSButton
    private let subjectField: NSTextField
    private let fromRow: ComposeFieldRow
    private let toRow: ComposeFieldRow
    private let ccRow: ComposeFieldRow
    private let bccRow: ComposeFieldRow
    private let subjectRow: ComposeFieldRow
    private let textView: ComposeTextView
    private let quoteView: QuotedOriginalView
    private let attachmentStrip: AttachmentStripView
    private let sendButton: NSButton
    private let attachButton: NSButton
    private let statusLabel: NSTextField
    private let spinner: NSProgressIndicator

    private var attachments: [ComposeAttachment] = [] {
        didSet { attachmentStrip.attachments = attachments }
    }
    private var quoted: QuotedReply.Rendering? {
        didSet { quoteView.rendering = quoted }
    }
    private var threading: ReplyThreading?
    /// Full-width constraints for the header rows. The stack detaches hidden rows, which drops these, so
    /// they are re-activated when Cc/Bcc come back.
    private var rowEdgeConstraints: [NSLayoutConstraint] = []
    /// What the window held before the user touched it; closing only asks when the draft differs.
    private var baseline = ComposeDraft.Fingerprint()
    private var prefillTask: Task<Void, Never>?
    private var isPrefilling = false
    private var isSending = false
    private var closesWithoutPrompt = false

    // MARK: Presenting

    /// Opens a composer and keeps it alive until its window closes.
    @discardableResult
    static func present(client: MailClient, account: Account, accounts: [Account], mode: ComposeMode) -> ComposeWindowController {
        let controller = ComposeWindowController(client: client, account: account, accounts: accounts, mode: mode)
        controller.show()
        controller.beginPrefill()
        return controller
    }

    /// Reopens a message whose send was undone, exactly as it was.
    @discardableResult
    static func present(client: MailClient, accounts: [Account], draft: ComposeDraft) -> ComposeWindowController {
        let controller = ComposeWindowController(client: client, account: draft.account, accounts: accounts, mode: draft.mode)
        controller.restore(draft)
        controller.show()
        return controller
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

        let fromPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let toField = AddressTokenField(frame: .zero)
        let ccField = AddressTokenField(frame: .zero)
        let bccField = AddressTokenField(frame: .zero)
        let ccBccButton = NSButton(title: "Cc Bcc", target: nil, action: nil)
        let subjectField = NSTextField(string: "")
        let textView = ComposeTextView(frame: NSRect(x: 0, y: 0, width: Self.defaultSize.width, height: 200))
        let sendButton = NSButton(title: "Send", target: nil, action: nil)
        let paperclip = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Attach File") ?? NSImage()
        let attachButton = NSButton(image: paperclip, target: nil, action: nil)

        self.fromPopup = fromPopup
        self.toField = toField
        self.ccField = ccField
        self.bccField = bccField
        self.ccBccButton = ccBccButton
        self.subjectField = subjectField
        self.textView = textView
        self.sendButton = sendButton
        self.attachButton = attachButton
        fromRow = ComposeFieldRow(title: "From:", control: fromPopup)
        toRow = ComposeFieldRow(title: "To:", control: toField, accessory: ccBccButton)
        ccRow = ComposeFieldRow(title: "Cc:", control: ccField)
        bccRow = ComposeFieldRow(title: "Bcc:", control: bccField)
        subjectRow = ComposeFieldRow(title: "Subject:", control: subjectField)
        quoteView = QuotedOriginalView()
        attachmentStrip = AttachmentStripView()
        statusLabel = NSTextField(labelWithString: "")
        spinner = NSProgressIndicator()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.savedSize() ?? Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configureWindow(window)
        buildContent(in: window)
        wireControls()
        populateFromPopup()
        updateTitle()
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

    private func configureWindow(_ window: NSWindow) {
        window.delegate = self
        window.minSize = Self.minimumSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.collectionBehavior = [.fullScreenAuxiliary]
    }

    private func buildContent(in window: NSWindow) {
        let dropView = ComposeDropView(frame: NSRect(origin: .zero, size: window.frame.size))
        dropView.onDropFiles = { [weak self] urls in self?.addAttachments(from: urls) }
        window.contentView = dropView

        let header = NSStackView(views: [fromRow, toRow, ccRow, bccRow, subjectRow])
        header.orientation = .vertical
        header.alignment = .width
        header.spacing = 0
        // The stack must hug its rows exactly, or the solver stretches it instead of the scroll view.
        header.setHuggingPriority(.required, for: .vertical)
        header.translatesAutoresizingMaskIntoConstraints = false
        ccRow.isHidden = true
        bccRow.isHidden = true

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let document = ComposeDocumentView()
        document.editor = textView
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(textView)
        document.addSubview(quoteView)
        scrollView.documentView = document

        let barSeparator = NSBox()
        barSeparator.boxType = .separator
        barSeparator.translatesAutoresizingMaskIntoConstraints = false

        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        sendButton.translatesAutoresizingMaskIntoConstraints = false
        attachButton.translatesAutoresizingMaskIntoConstraints = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(sendButton)
        bar.addSubview(attachButton)
        bar.addSubview(spinner)
        bar.addSubview(statusLabel)

        dropView.addSubview(header)
        dropView.addSubview(scrollView)
        dropView.addSubview(attachmentStrip)
        dropView.addSubview(barSeparator)
        dropView.addSubview(bar)

        let clip = scrollView.contentView
        let fillsPage = quoteView.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        fillsPage.priority = .defaultLow
        let editorMinimum = textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120)
        editorMinimum.priority = .defaultHigh

        let constraints = [
            header.topAnchor.constraint(equalTo: dropView.topAnchor),
            header.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),

            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            document.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),

            textView.topAnchor.constraint(equalTo: document.topAnchor),
            textView.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            editorMinimum,
            quoteView.topAnchor.constraint(equalTo: textView.bottomAnchor),
            quoteView.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            quoteView.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            quoteView.bottomAnchor.constraint(lessThanOrEqualTo: document.bottomAnchor),
            fillsPage,

            attachmentStrip.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            attachmentStrip.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            attachmentStrip.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),

            barSeparator.topAnchor.constraint(equalTo: attachmentStrip.bottomAnchor),
            barSeparator.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            barSeparator.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            barSeparator.heightAnchor.constraint(equalToConstant: 1),

            bar.topAnchor.constraint(equalTo: barSeparator.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: dropView.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: dropView.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: dropView.bottomAnchor),
            bar.heightAnchor.constraint(equalToConstant: 50),

            sendButton.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 14),
            sendButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            attachButton.leadingAnchor.constraint(equalTo: sendButton.trailingAnchor, constant: 8),
            attachButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -14),
            statusLabel.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: attachButton.trailingAnchor, constant: 12),
            spinner.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -6),
            spinner.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
        ]
        NSLayoutConstraint.activate(constraints)
        // The stack's own alignment yields to a control's hugging (the From popup would shrink to its title).
        rowEdgeConstraints = [fromRow, toRow, ccRow, bccRow, subjectRow].flatMap { row in
            [row.leadingAnchor.constraint(equalTo: header.leadingAnchor), row.trailingAnchor.constraint(equalTo: header.trailingAnchor)]
        }
        NSLayoutConstraint.activate(rowEdgeConstraints)

        scrollView.setContentHuggingPriority(.defaultLow, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        attachmentStrip.setContentHuggingPriority(.required, for: .vertical)
    }

    private func wireControls() {
        let store = client.store
        let provider: AddressTokenField.SuggestionProvider = { prefix, limit in
            try store.suggestAddresses(prefix: prefix, limit: limit)
        }
        for field in [toField, ccField, bccField] {
            field.suggestionProvider = provider
        }
        toField.placeholderString = "Recipient"

        fromPopup.isBordered = false
        fromPopup.font = .systemFont(ofSize: 13)
        fromPopup.target = self
        fromPopup.action = #selector(fromChanged(_:))

        ccBccButton.isBordered = false
        ccBccButton.setButtonType(.momentaryChange)
        ccBccButton.attributedTitle = NSAttributedString(string: "Cc Bcc", attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
        ])
        ccBccButton.target = self
        ccBccButton.action = #selector(revealCcBcc(_:))
        ccBccButton.toolTip = "Add Cc and Bcc recipients"

        subjectField.isBordered = false
        subjectField.drawsBackground = false
        subjectField.focusRingType = .none
        subjectField.font = .systemFont(ofSize: 13)
        subjectField.placeholderString = "Subject"
        subjectField.lineBreakMode = .byTruncatingTail
        subjectField.cell?.usesSingleLineMode = true
        subjectField.cell?.isScrollable = true
        subjectField.delegate = self

        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.keyEquivalentModifierMask = [.command]
        sendButton.target = self
        sendButton.action = #selector(send(_:))
        sendButton.toolTip = "Send (⌘↩)"

        attachButton.bezelStyle = .rounded
        attachButton.imagePosition = .imageOnly
        attachButton.keyEquivalent = "a"
        attachButton.keyEquivalentModifierMask = [.command, .shift]
        attachButton.target = self
        attachButton.action = #selector(attachFile(_:))
        attachButton.toolTip = "Attach File (⇧⌘A)"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        attachmentStrip.onRemove = { [weak self] id in self?.removeAttachment(id: id) }

        toField.nextKeyView = ccField
        ccField.nextKeyView = bccField
        bccField.nextKeyView = subjectField
        subjectField.nextKeyView = textView
        textView.nextKeyView = toField
        window?.initialFirstResponder = toField
    }

    private func populateFromPopup() {
        fromPopup.removeAllItems()
        for candidate in accounts {
            fromPopup.addItem(withTitle: Self.senderTitle(for: candidate))
            fromPopup.lastItem?.representedObject = candidate.id.rawValue
        }
        selectAccountInFromPopup()
        fromPopup.isEnabled = accounts.count > 1
    }

    private func selectAccountInFromPopup() {
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            fromPopup.selectItem(at: index)
        }
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
            window?.makeFirstResponder(toField.addresses.isEmpty ? toField : textView)
        }
    }

    // MARK: Header actions

    @objc private func fromChanged(_ sender: Any?) {
        guard let raw = fromPopup.selectedItem?.representedObject as? String,
              let chosen = accounts.first(where: { $0.id.rawValue == raw }) else { return }
        account = chosen
    }

    @objc private func revealCcBcc(_ sender: Any?) {
        showCcBccRows()
        window?.makeFirstResponder(ccField)
    }

    /// Message › Add Cc Field / Add Bcc Field (spec §5.35).
    @objc func addCcField(_ sender: Any?) {
        showCcBccRows()
        window?.makeFirstResponder(ccField)
    }

    @objc func addBccField(_ sender: Any?) {
        showCcBccRows()
        window?.makeFirstResponder(bccField)
    }

    /// Message › Discard Draft… (spec §5.20, §5.33): the one way to throw a draft away; closing keeps it.
    @objc func discardDraft(_ sender: Any?) {
        guard let window, !isSending else { return }
        let recipient = toField.addresses.first.map { $0.name?.isEmpty == false ? $0.name ?? $0.address : $0.address }
        AppAlert.discardDraft(recipient: recipient).present(on: window) { [weak self] choice in
            guard choice == 1, let self else { return }
            self.closesWithoutPrompt = true
            self.close()
        }
    }

    private func showCcBccRows() {
        ccRow.isHidden = false
        bccRow.isHidden = false
        NSLayoutConstraint.activate(rowEdgeConstraints)
        toRow.setAccessoryHidden(true)
    }

    private func updateTitle() {
        let subject = subjectField.stringValue.trimmingCharacters(in: .whitespaces)
        window?.title = subject.isEmpty ? "New Message" : subject
    }

    // MARK: NSTextFieldDelegate (subject)

    func controlTextDidChange(_ obj: Notification) {
        updateTitle()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Return in the subject moves on to the body instead of inserting nothing.
        guard control === subjectField, commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
        window?.makeFirstResponder(self.textView)
        return true
    }

    // MARK: Prefill

    private func beginPrefill() {
        guard let originalID = mode.originalMessageID else { return }
        isPrefilling = true
        setStatus("Loading original message…", busy: true)
        updateSendEnabled()
        prefillTask = Task { [weak self] in
            guard let self else { return }
            await self.prefill(originalID: originalID)
        }
    }

    private func prefill(originalID: MessageID) async {
        guard let original = try? client.store.message(originalID) else {
            finishPrefill(status: "The original message is no longer available.")
            return
        }
        applyHeaders(from: original)

        let body: StoredBody
        do {
            body = try await client.ensureBody(for: originalID)
        } catch {
            guard !Task.isCancelled else { return }
            Self.logger.error("Compose prefill could not load the original body: \(String(describing: error))")
            finishPrefill(status: "Couldn't load the original message; it won't be quoted.")
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

        var failures = 0
        for part in QuotedReply.partsToCarry(from: body.body.attachments, quotedHTML: rendering.html, isForward: isForward) {
            do {
                let data = try await client.attachmentData(for: originalID, attachmentID: part.info.id)
                guard !Task.isCancelled else { return }
                let attachment = ComposeAttachment(info: part.info, data: data, contentID: part.contentID)
                attachments.append(attachment)
                baseline.attachmentIDs.insert(attachment.id)
            } catch {
                guard !Task.isCancelled else { return }
                failures += 1
                Self.logger.error("Compose prefill could not load an attachment: \(String(describing: error))")
            }
        }
        finishPrefill(status: failures == 0 ? "" : (failures == 1 ? "One attachment couldn't be loaded." : "\(failures) attachments couldn't be loaded."))
    }

    private func applyHeaders(from original: MessageMetadata) {
        switch mode {
        case .reply(_, let all):
            let recipients = ReplyRecipients.compute(for: original, all: all, ownAddresses: [account.email])
            toField.addresses = recipients.to
            ccField.addresses = recipients.cc
            if !recipients.cc.isEmpty { showCcBccRows() }
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
        updateTitle()
    }

    private func finishPrefill(status: String) {
        isPrefilling = false
        setStatus(status, busy: false)
        updateSendEnabled()
    }

    // MARK: Draft state

    private func currentDraft() -> ComposeDraft {
        ComposeDraft(
            mode: mode,
            account: account,
            to: toField.addresses,
            cc: ccField.addresses,
            bcc: bccField.addresses,
            subject: subjectField.stringValue,
            body: NSAttributedString(attributedString: textView.attributedString()),
            attachments: attachments,
            quoted: quoted,
            threading: threading
        )
    }

    private func restore(_ draft: ComposeDraft) {
        // The draft remembers the From the user chose, which `init` replaced with the original's owner.
        account = draft.account
        selectAccountInFromPopup()
        toField.addresses = draft.to
        ccField.addresses = draft.cc
        bccField.addresses = draft.bcc
        if !draft.cc.isEmpty || !draft.bcc.isEmpty { showCcBccRows() }
        subjectField.stringValue = draft.subject
        textView.replaceContents(with: draft.body)
        attachments = draft.attachments
        quoted = draft.quoted
        threading = draft.threading
        // Everything here is the user's own work, so closing must ask.
        baseline = ComposeDraft.Fingerprint()
        updateTitle()
    }

    private var hasUnsavedChanges: Bool {
        currentDraft().fingerprint != baseline
    }

    // MARK: Attachments

    @objc private func attachFile(_ sender: Any?) {
        guard let window else { return }
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

    private func addAttachments(from urls: [URL]) {
        var rejected: [String] = []
        for url in urls {
            do {
                attachments.append(try ComposeAttachment(fileURL: url))
            } catch {
                rejected.append(url.lastPathComponent)
            }
        }
        guard !rejected.isEmpty else { return }
        presentError(title: "Some items couldn't be attached", message: "Folders and unreadable files are skipped: " + rejected.joined(separator: ", "))
    }

    private func removeAttachment(id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: Sending

    @objc private func send(_ sender: Any?) {
        guard !isSending, !isPrefilling, validateRecipients() else {
            NSSound.beep()
            return
        }
        if subjectField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty, let window {
            let alert = NSAlert()
            alert.messageText = "Send without a subject?"
            alert.informativeText = "This message has no subject."
            alert.addButton(withTitle: "Send")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] response in
                MainActor.assumeIsolated {
                    guard response == .alertFirstButtonReturn else { return }
                    self?.performSend()
                }
            }
            return
        }
        performSend()
    }

    /// Commits whatever is still being typed, outlines the fields that would be rejected and reports
    /// whether the message has somewhere to go.
    private func validateRecipients() -> Bool {
        let ccValid = ccField.validateForSend()
        let bccValid = bccField.validateForSend()
        let hasOtherRecipient = !ccField.addresses.isEmpty || !bccField.addresses.isEmpty
        let toValid = toField.validateForSend(requireRecipient: !hasOtherRecipient)
        if !toValid {
            window?.makeFirstResponder(toField)
        } else if !ccValid {
            window?.makeFirstResponder(ccField)
        } else if !bccValid {
            window?.makeFirstResponder(bccField)
        }
        return toValid && ccValid && bccValid
    }

    private func performSend() {
        let draft = currentDraft()
        let normalized = ComposeBodyNormalizer.normalize(draft.body)
        let pending = draft.attachments
        isSending = true
        updateSendEnabled()
        setStatus("Sending…", busy: true)

        Task { [weak self] in
            // File-backed attachments are read here, off the main thread, so a large file never stalls the window.
            let outcome: (parts: [OutgoingAttachment], failure: String?) = await Task.detached(priority: .userInitiated) {
                var parts: [OutgoingAttachment] = []
                for attachment in pending {
                    do {
                        parts.append(try attachment.outgoing())
                    } catch {
                        return ([], attachment.filename)
                    }
                }
                return (parts, nil)
            }.value
            guard let self else { return }
            if let failure = outcome.failure {
                self.sendFailed(title: "Couldn't read “\(failure)”", message: "The file may have been moved or deleted. Remove it and try again.")
                return
            }
            let message = draft.outgoingMessage(normalizedBody: normalized, loadedAttachments: outcome.parts)
            do {
                let sendID = try self.client.send(message, undoWindow: Self.undoWindow)
                self.closesWithoutPrompt = true
                self.close()
                UndoSendPanel.show(client: self.client, accounts: self.accounts, sendID: sendID, draft: draft, undoWindow: Self.undoWindow)
            } catch {
                Self.logger.error("Queueing a send failed: \(String(describing: error))")
                self.sendFailed(title: "Couldn't send the message", message: "The message was not queued. Please try again.")
            }
        }
    }

    private func sendFailed(title: String, message: String) {
        isSending = false
        updateSendEnabled()
        setStatus("", busy: false)
        presentError(title: title, message: message)
    }

    private func updateSendEnabled() {
        sendButton.isEnabled = !isSending && !isPrefilling
    }

    private func setStatus(_ text: String, busy: Bool) {
        statusLabel.stringValue = text
        if busy {
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
        }
    }

    private func presentError(title: String, message: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if closesWithoutPrompt { return true }
        // A send in progress holds the draft; closing underneath it would lose the error if it fails.
        guard !isSending else { return false }
        guard hasUnsavedChanges else { return true }
        let alert = NSAlert()
        alert.messageText = "Discard this message?"
        alert.informativeText = "Your changes will be lost."
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Keep Writing")
        alert.beginSheetModal(for: sender) { [weak self] response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn, let self else { return }
                self.closesWithoutPrompt = true
                self.close()
            }
        }
        return false
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        saveSize()
    }

    func windowWillClose(_ notification: Notification) {
        prefillTask?.cancel()
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
