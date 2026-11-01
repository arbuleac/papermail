import AppKit
import SSCore

/// The reply box docked under the conversation: one line until focused, then it grows with the text.
///
/// The view owns no mail logic. It reports the typed text on Cmd+Return, tells its owner when focus
/// changes or Escape is pressed, and shows a transient status strip ("Sent · Undo") on request.
@MainActor
final class QuickReplyView: NSView {
    static let collapsedHeight: CGFloat = 40
    static let expandedMinHeight: CGFloat = 112
    static let expandedMaxHeight: CGFloat = 280

    var onSend: ((String) -> Void)?
    var onEscape: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    var placeholderName: String = "" {
        didSet { updatePlaceholder() }
    }

    var text: String {
        get { textView.string }
        set {
            textView.string = newValue
            textDidChange()
        }
    }

    private(set) var isExpanded = false
    private(set) var isFocused = false

    private let scrollView = NSScrollView()
    private let textView = QuickReplyTextView()
    private let placeholder = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private let strip = NSView()
    private let stripLabel = NSTextField(labelWithString: "")
    private let stripButton = NSButton(title: "Undo", target: nil, action: nil)
    private var heightConstraint = NSLayoutConstraint()
    private var stripTimer: Timer?
    private var stripAction: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) {
        nil
    }

    // MARK: Public controls

    func focus() {
        window?.makeFirstResponder(textView)
    }

    /// Hands focus back to the window; the owner decides where it should go next via `onEscape`.
    func blur() {
        if window?.firstResponder === textView {
            window?.makeFirstResponder(nil)
        }
    }

    func clear() {
        text = ""
        collapseIfEmpty()
    }

    func restoreDraft(_ draft: String) {
        text = draft
        if !draft.isEmpty { expand() }
    }

    /// Shows `message` with an optional button for `duration` seconds. Calling again replaces the strip.
    func showStrip(_ message: String, buttonTitle: String? = nil, duration: TimeInterval = 5, action: (() -> Void)? = nil) {
        stripTimer?.invalidate()
        // Reads as one phrase, "Sent · Undo", with the verb on the button.
        stripLabel.stringValue = buttonTitle == nil ? message : message + " ·"
        stripButton.title = buttonTitle ?? ""
        stripButton.isHidden = buttonTitle == nil
        stripAction = action
        strip.isHidden = false
        stripTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideStrip() }
        }
    }

    func hideStrip() {
        stripTimer?.invalidate()
        stripTimer = nil
        stripAction = nil
        strip.isHidden = true
    }

    func expand() {
        isExpanded = true
        scrollView.hasVerticalScroller = true
        updateHeight(animated: true)
    }

    func collapseIfEmpty() {
        guard text.isEmpty else { return }
        isExpanded = false
        scrollView.hasVerticalScroller = false
        updateHeight(animated: true)
    }

    // MARK: Building

    private func build() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView
        addSubview(scrollView)

        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainerInset = NSSize(width: 8, height: 10)
        textView.font = NSFont.systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = false
        textView.delegate = self
        textView.onCommandReturn = { [weak self] in self?.send() }
        textView.onEscape = { [weak self] in self?.escape() }
        textView.onFocusChange = { [weak self] focused in self?.focusDidChange(focused) }

        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.textColor = .placeholderTextColor
        placeholder.font = NSFont.systemFont(ofSize: 13)
        placeholder.lineBreakMode = .byTruncatingTail
        placeholder.isSelectable = false
        addSubview(placeholder)

        strip.translatesAutoresizingMaskIntoConstraints = false
        strip.wantsLayer = true
        strip.layer?.cornerRadius = 8
        strip.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        strip.isHidden = true
        stripLabel.translatesAutoresizingMaskIntoConstraints = false
        stripLabel.textColor = .white
        stripLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        stripButton.translatesAutoresizingMaskIntoConstraints = false
        stripButton.bezelStyle = .inline
        stripButton.controlSize = .small
        stripButton.target = self
        stripButton.action = #selector(stripButtonPressed)
        strip.addSubview(stripLabel)
        strip.addSubview(stripButton)
        addSubview(strip)

        heightConstraint = heightAnchor.constraint(equalToConstant: Self.collapsedHeight)
        heightConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            heightConstraint,
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            placeholder.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor, constant: 13),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -8),
            placeholder.topAnchor.constraint(equalTo: scrollView.topAnchor, constant: 10),
            strip.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            strip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            strip.heightAnchor.constraint(equalToConstant: 26),
            stripLabel.leadingAnchor.constraint(equalTo: strip.leadingAnchor, constant: 10),
            stripLabel.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
            stripButton.leadingAnchor.constraint(equalTo: stripLabel.trailingAnchor, constant: 6),
            stripButton.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -6),
            stripButton.centerYAnchor.constraint(equalTo: strip.centerYAnchor),
        ])
        updatePlaceholder()
    }

    override func layout() {
        super.layout()
        // The document view tracks the clip width; without this the first layout leaves it at zero.
        textView.frame.size.width = scrollView.contentSize.width
    }

    // MARK: Behavior

    private func send() {
        let typed = text
        guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onSend?(typed)
    }

    private func escape() {
        blur()
        onEscape?()
    }

    private func focusDidChange(_ focused: Bool) {
        isFocused = focused
        if focused {
            expand()
        } else {
            collapseIfEmpty()
        }
        onFocusChange?(focused)
    }

    private func updatePlaceholder() {
        let name = placeholderName.trimmingCharacters(in: .whitespacesAndNewlines)
        placeholder.stringValue = name.isEmpty ? "Reply…" : "Reply to \(name)…"
        placeholder.isHidden = !text.isEmpty
    }

    private func updateHeight(animated: Bool) {
        let target: CGFloat
        if isExpanded {
            let content = contentHeight() + 2
            target = min(Self.expandedMaxHeight, max(Self.expandedMinHeight, content))
        } else {
            target = Self.collapsedHeight
        }
        guard abs(heightConstraint.constant - target) > 0.5 else { return }
        if animated, window != nil {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                context.allowsImplicitAnimation = true
                heightConstraint.animator().constant = target
                superview?.layoutSubtreeIfNeeded()
            }
        } else {
            heightConstraint.constant = target
        }
    }

    private func contentHeight() -> CGFloat {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else {
            return Self.expandedMinHeight
        }
        layoutManager.ensureLayout(for: container)
        return layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
    }

    @objc private func stripButtonPressed() {
        let action = stripAction
        hideStrip()
        action?()
    }
}

extension QuickReplyView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        textDidChange()
    }

    private func textDidChange() {
        placeholder.isHidden = !text.isEmpty
        if isExpanded { updateHeight(animated: false) }
    }
}

/// Catches the keys the delegate protocol cannot: Cmd+Return is not a text command, and Escape must
/// blur rather than cancel completion.
private final class QuickReplyTextView: NSTextView {
    var onCommandReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        if ReaderShortcuts.isSend(keyCode: event.keyCode, rawModifierFlags: event.modifierFlags.rawValue) {
            onCommandReturn?()
            return
        }
        super.keyDown(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocusChange?(true) }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let accepted = super.resignFirstResponder()
        if accepted { onFocusChange?(false) }
        return accepted
    }
}
