import AppKit
import SSCore

/// First run with no accounts: what this is, two ways in, and the demo for the curious.
@MainActor
final class WelcomeViewController: NSViewController {
    var onAddAccount: ((ProviderKind) -> Void)?
    var onTryDemo: (() -> Void)?
    var onCancelSignIn: (() -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var buttons: [NSButton] = []
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 96),
            icon.heightAnchor.constraint(equalToConstant: 96),
        ])

        let title = NSTextField(labelWithString: "Welcome to SuperSparrow")
        title.font = .systemFont(ofSize: 26, weight: .bold)
        title.alignment = .center

        let subtitle = NSTextField(wrappingLabelWithString: "A fast, simple home for your Gmail and Microsoft mail.\nYour mail stays on this Mac; sign-in happens in your browser.")
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.preferredMaxLayoutWidth = 380

        let gmail = makeButton("Add Gmail account", symbol: "envelope", action: #selector(addGmail))
        let microsoft = makeButton("Add Microsoft account", symbol: "envelope.badge", action: #selector(addMicrosoft))
        gmail.keyEquivalent = "\r"

        let demo = NSButton(title: "Try the demo", target: self, action: #selector(tryDemo))
        demo.isBordered = false
        demo.contentTintColor = .linkColor
        demo.font = .systemFont(ofSize: 13)
        demo.toolTip = "Explore SuperSparrow with two made-up mailboxes. Nothing leaves this Mac."

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        cancelButton.target = self
        cancelButton.action = #selector(cancelSignIn)
        cancelButton.bezelStyle = .push
        cancelButton.controlSize = .small
        cancelButton.isHidden = true
        let status = NSStackView(views: [spinner, statusLabel, cancelButton])
        status.spacing = 8

        let stack = NSStackView(views: [icon, title, subtitle, gmail, microsoft, demo, status])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.setCustomSpacing(8, after: title)
        stack.setCustomSpacing(24, after: subtitle)
        stack.setCustomSpacing(8, after: gmail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            gmail.widthAnchor.constraint(equalToConstant: 240),
            microsoft.widthAnchor.constraint(equalToConstant: 240),
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: 480),
            root.heightAnchor.constraint(greaterThanOrEqualToConstant: 480),
        ])
        view = root
    }

    private func makeButton(_ title: String, symbol: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .push
        button.controlSize = .large
        button.translatesAutoresizingMaskIntoConstraints = false
        buttons.append(button)
        return button
    }

    /// While a browser sign-in is under way the add buttons stay disabled and the line says what to do. Cancel
    /// and "Try the demo" stay usable: a closed browser tab otherwise leaves the screen stuck until the sign-in
    /// times out minutes later.
    func setBusy(_ message: String?) {
        loadViewIfNeeded()
        statusLabel.stringValue = message ?? ""
        if message == nil { spinner.stopAnimation(nil) } else { spinner.startAnimation(nil) }
        buttons.forEach { $0.isEnabled = message == nil }
        cancelButton.isHidden = message == nil
    }

    @objc private func addGmail() { onAddAccount?(.gmail) }
    @objc private func addMicrosoft() { onAddAccount?(.microsoft) }
    @objc private func tryDemo() { onTryDemo?() }
    @objc private func cancelSignIn() { onCancelSignIn?() }
}
