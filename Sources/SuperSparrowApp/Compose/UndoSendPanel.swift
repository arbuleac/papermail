import AppKit
import SSCore

/// The floating "Sending in 5 s · Undo" notice shown once the composer closes. Non-activating so it never
/// steals focus from whatever the user moved on to; Undo cancels the held send and reopens the composer
/// with the same content. Lives in `ComposeWindowRegistry` until it goes away.
@MainActor
final class UndoSendPanel: NSPanel {
    private static let panelSize = NSSize(width: 236, height: 44)
    private static let margin: CGFloat = 16

    private let client: MailClient
    private let accounts: [Account]
    private let sendID: String
    private let draft: ComposeDraft
    private let deadline: Date
    private let label = NSTextField(labelWithString: "")
    private let dot = NSTextField(labelWithString: "·")
    private let undoButton = NSButton(title: "Undo", target: nil, action: nil)
    private var timer: Timer?
    private var finished = false

    @discardableResult
    static func show(client: MailClient, accounts: [Account], sendID: String, draft: ComposeDraft, undoWindow: TimeInterval) -> UndoSendPanel {
        let panel = UndoSendPanel(client: client, accounts: accounts, sendID: sendID, draft: draft, undoWindow: undoWindow)
        ComposeWindowRegistry.shared.register(panel)
        panel.place()
        panel.orderFrontRegardless()
        panel.startCountdown()
        return panel
    }

    init(client: MailClient, accounts: [Account], sendID: String, draft: ComposeDraft, undoWindow: TimeInterval) {
        self.client = client
        self.accounts = accounts
        self.sendID = sendID
        self.draft = draft
        deadline = Date().addingTimeInterval(undoWindow)
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        animationBehavior = .utilityWindow
        buildContent()
        tick()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private func buildContent() {
        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 13)
        label.textColor = .labelColor
        dot.font = .systemFont(ofSize: 13)
        dot.textColor = .secondaryLabelColor

        undoButton.isBordered = false
        undoButton.setButtonType(.momentaryChange)
        undoButton.attributedTitle = NSAttributedString(string: "Undo", attributes: [
            .font: NSFont.boldSystemFont(ofSize: 13),
            .foregroundColor: NSColor.controlAccentColor,
        ])
        undoButton.target = self
        undoButton.action = #selector(undo(_:))
        undoButton.toolTip = "Cancel sending and reopen the message"

        let stack = NSStackView(views: [label, dot, undoButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect
    }

    /// Bottom-right of the main screen, stacked above any other undo panel still showing.
    private func place() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let slot = CGFloat(ComposeWindowRegistry.shared.slot(for: self))
        let origin = NSPoint(
            x: visible.maxX - Self.panelSize.width - Self.margin,
            y: visible.minY + Self.margin + slot * (Self.panelSize.height + 8)
        )
        setFrameOrigin(origin)
    }

    // MARK: Countdown

    private func startCountdown() {
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, target: self, selector: #selector(timerFired(_:)), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    @objc private func timerFired(_ timer: Timer) {
        tick()
    }

    private func tick() {
        guard !finished else { return }
        let remaining = deadline.timeIntervalSinceNow
        if remaining <= 0 {
            finish(message: "Sent")
        } else {
            label.stringValue = "Sending in \(Int(remaining.rounded(.up))) s"
        }
    }

    @objc private func undo(_ sender: Any?) {
        guard !finished else { return }
        let cancelled = (try? client.cancelSend(id: sendID)) ?? false
        guard cancelled else {
            finish(message: "Already sent")
            return
        }
        dismiss()
        ComposeWindowController.present(client: client, accounts: accounts, draft: draft)
    }

    private func finish(message: String) {
        finished = true
        timer?.invalidate()
        timer = nil
        label.stringValue = message
        dot.isHidden = true
        undoButton.isHidden = true
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            self?.dismiss()
        }
    }

    private func dismiss() {
        timer?.invalidate()
        timer = nil
        orderOut(nil)
        ComposeWindowRegistry.shared.unregister(self)
    }
}
