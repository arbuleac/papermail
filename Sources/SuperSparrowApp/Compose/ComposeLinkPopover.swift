import AppKit
import SSCore
import SSDesign

/// The link popover (spec §5.20, ⌘K or the Link toggle), app-drawn because it anchors to the selection:
/// `raised`, `e2`, radius 8, padding 12, 320 pt wide (a `ruleStrong` edge in Increase Contrast). A “Link” field
/// (placeholder “https://”, focused on open) and, only when nothing is selected, a “Text” field; then ghost
/// “Remove Link” when editing an existing link, and trailing ghost “Cancel” and small primary “Add Link”
/// (“Save” when editing). ↩ confirms, Esc cancels, Tab cycles inside. It fades in and out over `dur.quick`.
@MainActor
final class ComposeLinkPopover: NSView, NSTextFieldDelegate {
    struct Request {
        var range: NSRange
        var existingTarget: String?
        var needsText: Bool
    }

    /// Called with the normalized target and, for a caret, the text to insert.
    var onConfirm: ((String, String?) -> Void)?
    var onRemove: (() -> Void)?
    var onClose: (() -> Void)?

    let request: Request
    private let sheet = QuireSheetView(frame: .zero)
    private let linkField = QuireTextField(placeholder: "https://")
    private let textField = QuireTextField(placeholder: nil)
    private let removeButton = QuireButton(title: "Remove Link", variant: .ghost, size: .small)
    private let cancelButton = QuireButton(title: "Cancel", variant: .ghost, size: .small)
    private let confirmButton: QuireButton
    private var isClosing = false

    private static let labelColumn: CGFloat = 36

    init(request: Request) {
        self.request = request
        confirmButton = QuireButton(title: request.existingTarget == nil ? "Add Link" : "Save", variant: .primary, size: .small)
        super.init(frame: .zero)
        sheet.fillColor = .qRaised
        sheet.elevation = Quire.Elevation.e2
        sheet.cornerRadius = Quire.Layout.Composer.linkPopoverRadius
        sheet.showsEdge = false
        addSubview(sheet)
        linkField.stringValue = request.existingTarget ?? ""
        linkField.textField.delegate = self
        linkField.textField.setAccessibilityLabel("Link")
        textField.textField.delegate = self
        textField.textField.setAccessibilityLabel("Text")
        textField.isHidden = !request.needsText
        removeButton.isHidden = request.existingTarget == nil
        removeButton.target = self
        removeButton.action = #selector(removeLink(_:))
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        confirmButton.target = self
        confirmButton.action = #selector(confirm(_:))
        sheet.contentView.addSubview(labels)
        for view in [linkField, textField, removeButton, cancelButton, confirmButton] as [NSView] {
            sheet.contentView.addSubview(view)
        }
        wireKeyLoop()
        setAccessibilityElement(true)
        setAccessibilityRole(.popover)
        setAccessibilityLabel(request.existingTarget == nil ? "Add Link" : "Edit Link")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ComposeLinkPopover is built in code")
    }

    override var isFlipped: Bool { true }

    private func wireKeyLoop() {
        var loop: [NSView] = [linkField.textField]
        if request.needsText { loop.append(textField.textField) }
        if request.existingTarget != nil { loop.append(removeButton) }
        loop += [cancelButton, confirmButton]
        for (index, view) in loop.enumerated() {
            view.nextKeyView = loop[(index + 1) % loop.count]
        }
    }

    // MARK: Geometry

    var preferredSize: NSSize {
        let c = Quire.Layout.Composer.self
        var height = c.linkPopoverPad + linkField.intrinsicContentSize.height
        if request.needsText { height += c.linkPopoverGap + textField.intrinsicContentSize.height }
        height += c.linkPopoverGap + Quire.Layout.Button.Small.height + c.linkPopoverPad
        return NSSize(width: c.linkPopoverWidth, height: ceil(height))
    }

    override func layout() {
        super.layout()
        let c = Quire.Layout.Composer.self
        sheet.frame = bounds
        let pad = c.linkPopoverPad
        let fieldX = pad + Self.labelColumn + c.linkPopoverGap
        let fieldWidth = bounds.width - fieldX - pad
        var y = pad
        linkField.frame = linkField.frame(forVisualRect: NSRect(x: fieldX, y: y, width: fieldWidth, height: linkField.intrinsicContentSize.height))
        y += linkField.intrinsicContentSize.height + c.linkPopoverGap
        if request.needsText {
            textField.frame = textField.frame(forVisualRect: NSRect(x: fieldX, y: y, width: fieldWidth, height: textField.intrinsicContentSize.height))
            y += textField.intrinsicContentSize.height + c.linkPopoverGap
        }
        let buttonGap: CGFloat = 6
        var trailing = bounds.width - pad
        for button in [confirmButton, cancelButton] {
            let size = button.intrinsicContentSize
            button.frame = button.frame(forVisualRect: NSRect(x: trailing - size.width, y: y, width: size.width, height: size.height))
            trailing -= size.width + buttonGap
        }
        let removeSize = removeButton.intrinsicContentSize
        removeButton.frame = removeButton.frame(forVisualRect: NSRect(x: pad, y: y, width: removeSize.width, height: removeSize.height))
        // The “Link” and “Text” labels, `snippet` `ink3`, in their 36 pt column, centred on their fields.
        labels.frame = sheet.contentView.bounds
        let linkTop = linkField.alignmentRect(forFrame: linkField.frame).minY
        let textTop = textField.alignmentRect(forFrame: textField.frame).minY
        labels.entries = [("Link", linkTop)] + (request.needsText ? [("Text", textTop)] : [])
    }

    private let labels = PopoverLabels()

    // MARK: Showing

    func present(in host: NSView, frame: NSRect) {
        self.frame = frame
        alphaValue = 0
        host.addSubview(self, positioned: .above, relativeTo: nil)
        layoutSubtreeIfNeeded()
        window?.makeFirstResponder(linkField.textField)
        wantsLayer = true
        Quire.Motion.run(Quire.Motion.quick, .settle, reduced: .keep, participants: [self]) { _ in
            self.animator().alphaValue = 1
        }
    }

    func close() {
        guard !isClosing else { return }
        isClosing = true
        onClose?()
        Quire.Motion.run(Quire.Motion.quick, .leave, reduced: .keep, participants: [self]) { _ in
            self.animator().alphaValue = 0
        } completion: { [weak self] in
            self?.removeFromSuperview()
        }
    }

    // MARK: Actions

    @objc private func confirm(_ sender: Any?) {
        guard let target = ComposeLink.normalized(linkField.stringValue) else {
            linkField.errorMessage = ComposeLink.invalidMessage
            relayoutForError()
            window?.makeFirstResponder(linkField.textField)
            return
        }
        let text = request.needsText ? textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        onConfirm?(target, text?.isEmpty == true ? nil : text)
        close()
    }

    @objc private func cancel(_ sender: Any?) {
        close()
    }

    @objc private func removeLink(_ sender: Any?) {
        onRemove?()
        close()
    }

    private func relayoutForError() {
        var rect = frame
        let height = preferredSize.height
        rect.size.height = height
        frame = rect
        needsLayout = true
    }

    // MARK: Text field delegate

    func controlTextDidChange(_ obj: Notification) {
        if (obj.object as? NSTextField) === linkField.textField, linkField.errorMessage != nil {
            linkField.errorMessage = nil
            relayoutForError()
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            confirm(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel(nil)
            return true
        default:
            return false
        }
    }

    override func cancelOperation(_ sender: Any?) {
        cancel(nil)
    }

    override func mouseDown(with event: NSEvent) {
        // Clicks on the popover's own surface stay in it.
    }
}

/// Draws the field labels of the link popover.
@MainActor
private final class PopoverLabels: NSView {
    var entries: [(String, CGFloat)] = [] {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let role = QuireFont.Role.snippet
        let fieldHeight = Quire.Layout.TextField.height
        for (title, top) in entries {
            QuireFont.attributedString(title, role: role, color: .qInk3)
                .draw(with: NSRect(x: Quire.Layout.Composer.linkPopoverPad, y: (top + (fieldHeight - role.lineHeight) / 2).rounded(),
                                   width: 36, height: role.lineHeight), options: QuireFont.drawingOptions, context: nil)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
