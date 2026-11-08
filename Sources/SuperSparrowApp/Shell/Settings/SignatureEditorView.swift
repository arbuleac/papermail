import AppKit
import SSCore
import SSDesign

/// The editor inside Settings › Accounts › Signature (spec §5.40): the composer's own text view in a small scrolling
/// field, with the composer's inline formatting (bold, italic, underline and links, through the same commands,
/// shortcuts and link popover) and no lists or quotes. What it holds is saved as the HTML subset the composer sends,
/// once editing ends (focus leaves it, its window stops being key or closes, another account is chosen, the app quits
/// through `SettingsWindowController.endEditing`), never per keystroke, and only when it changed. The Quire field face
/// and ring around it are SwiftUI's (`QuireTextAreaStyle`).
@MainActor
final class SignatureEditorView: NSView, NSTextViewDelegate {
    /// The composer's editor, set for the field.
    let textView: ComposeTextView
    /// Called with the HTML to keep (nil for none) for the account being edited, when editing ends with a change.
    var onCommit: ((String?, AccountID) -> Void)?
    /// Called when the editor takes or gives up keyboard focus, for the field's ring.
    var onFocusChange: ((Bool) -> Void)?

    private let scrollView = NSScrollView()
    private let document = FlippedDocumentView()
    private var overlay: LinkPopoverOverlay?
    private var linkPopover: ComposeLinkPopover?
    private var focusObservation: NSKeyValueObservation?
    /// The account the editor holds the signature of.
    private(set) var accountID: AccountID?
    /// What the store holds for that account, as last loaded or saved.
    private var savedHTML: String?
    private var isDirty = false

    override init(frame frameRect: NSRect) {
        textView = ComposeTextView(frame: NSRect(origin: .zero, size: frameRect.size))
        super.init(frame: frameRect)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SignatureEditorView is built in code")
    }

    override var isFlipped: Bool { true }

    private func configure() {
        // The field's padding is the container's (8 pt at the sides); the first line sits where a one-line field's
        // text would, (24 - 21) / 2 pt from the top (`settings.fieldHeight`, `writing`).
        textView.leadingInset = 0
        textView.trailingInset = 0
        textView.topInset = (Quire.Layout.Settings.fieldHeight - ComposeTextView.bodyRole.lineHeight) / 2
        textView.allowsBlockFormatting = false
        textView.delegate = self
        textView.setAccessibilityLabel("Signature")
        textView.onLinkRequest = { [weak self] _ in self?.showLinkPopover() }
        textView.onFocusChange = { [weak self] focused in
            guard let self else { return }
            if !focused { self.commitIfNeeded() }
            self.onFocusChange?(focused)
        }

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(textView)
        scrollView.documentView = document
        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.widthAnchor.constraint(equalTo: clip.widthAnchor),
            textView.topAnchor.constraint(equalTo: document.topAnchor),
            textView.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            // At least the field's height, so a click anywhere in it places the caret; past three lines it grows and
            // the field scrolls.
            textView.heightAnchor.constraint(greaterThanOrEqualTo: clip.heightAnchor),
        ])
    }

    // MARK: Loading and saving

    /// Shows `html` as the signature of `account`. Edits not yet saved for the account shown before are saved first.
    /// The same signature for the same account changes nothing, so the editor never loses its caret to the
    /// store's echo of a save; a signature changed elsewhere while the field is being edited waits for editing to end.
    func load(_ html: String?, for account: AccountID) {
        let stored = Account.normalizedSignature(html)
        if account == accountID {
            guard stored != savedHTML, !isDirty, window?.firstResponder !== textView else { return }
        } else {
            commitIfNeeded()
        }
        // The popover's range points into the text about to go.
        linkPopover?.close()
        accountID = account
        savedHTML = stored
        isDirty = false
        textView.replaceContents(with: ComposeSignature.editable(html: stored))
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    /// Saves what the editor holds when it changed since it was loaded or last saved: sanitized to the composer's HTML
    /// subset, nil when it holds nothing but white space.
    func commitIfNeeded() {
        guard isDirty, let accountID else { return }
        isDirty = false
        let html = ComposeSignature.html(from: textView.attributedString())
        guard html != savedHTML else { return }
        savedHTML = html
        onCommit?(html, accountID)
    }

    func textDidChange(_ notification: Notification) {
        isDirty = true
    }

    /// A click on a link places the caret, as in the composer (§5.20).
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        textView.setSelectedRange(NSRange(location: charIndex, length: 0))
        return true
    }

    // MARK: Leaving

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
            focusObservation?.invalidate()
            focusObservation = nil
            if newWindow == nil { commitIfNeeded() }
        }
        overlay?.removeFromSuperview()
        overlay = nil
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Closing a window, or going to another one, does not take focus from its field, so a signature still being
        // edited is saved here: a composer opened from the main window next reads the accounts as they are then.
        // Quitting is `SettingsWindowController.endEditing`'s: AppKit's will-terminate comes after the store closes.
        NotificationCenter.default.addObserver(self, selector: #selector(editingWindowLeft(_:)), name: NSWindow.willCloseNotification,
                                               object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(editingWindowLeft(_:)), name: NSWindow.didResignKeyNotification,
                                               object: window)
        // As in the composer, the link popover belongs to the moment: focus going anywhere else dismisses it, before
        // the text its range points into can change. The window itself holds focus for a moment while a field ends
        // editing; that is not a place.
        focusObservation = window.observe(\.firstResponder) { [weak self] window, _ in
            MainActor.assumeIsolated {
                guard let popover = self?.linkPopover, let responder = window.firstResponder as? NSView,
                      !responder.isDescendant(of: popover) else { return }
                popover.close()
            }
        }
    }

    @objc private func editingWindowLeft(_ note: Notification) {
        commitIfNeeded()
    }

    // MARK: Link popover

    /// ⌘K: the composer's link popover, over the window's content so it is not cut to the field's bounds.
    private func showLinkPopover() {
        guard linkPopover == nil, let host = popoverHost() else { return }
        linkPopover = textView.presentLinkPopover(in: host) { [weak self] in self?.linkPopover = nil }
    }

    private func popoverHost() -> NSView? {
        if let overlay, overlay.superview != nil { return overlay }
        guard let content = window?.contentView else { return nil }
        let host = LinkPopoverOverlay(frame: content.bounds)
        host.autoresizingMask = [.width, .height]
        content.addSubview(host, positioned: .above, relativeTo: nil)
        overlay = host
        return host
    }
}

/// The scroll view's document: flipped, so the text starts at the top.
@MainActor
private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// A transparent, flipped layer over the Settings window's content that holds the link popover; clicks anywhere but
/// on the popover go through to the form below.
@MainActor
private final class LinkPopoverOverlay: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}
