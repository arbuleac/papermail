import AppKit

/// "Archived · Undo": a small pill at the bottom of the list that fades out after a few seconds.
@MainActor
final class ToastView: NSVisualEffectView {
    static let duration: TimeInterval = 4

    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Undo", target: nil, action: nil)
    private var hideTimer: Timer?
    private var action: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.masksToBounds = true
        isHidden = true
        alphaValue = 0

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        button.isBordered = false
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.contentTintColor = .controlAccentColor
        button.target = self
        button.action = #selector(undoClicked)
        button.translatesAutoresizingMaskIntoConstraints = false
        let separator = NSTextField(labelWithString: "·")
        separator.textColor = .tertiaryLabelColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView(views: [label, separator, button])
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    func show(_ text: String, buttonTitle: String? = "Undo", action: (() -> Void)? = nil) {
        label.stringValue = text
        button.title = buttonTitle ?? ""
        button.isHidden = buttonTitle == nil || action == nil
        self.action = action
        hideTimer?.invalidate()
        isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            animator().alphaValue = 1
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        hideTimer?.invalidate()
        hideTimer = nil
        action = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.isHidden = true
            }
        })
    }

    @objc private func undoClicked() {
        let action = self.action
        hide()
        action?()
    }
}
