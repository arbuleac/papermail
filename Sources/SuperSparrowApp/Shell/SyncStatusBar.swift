import AppKit
import SSCore

/// What the status line says, reduced from every account's status. Quiet unless there is something worth
/// knowing: a first download in progress, no network, or an account that needs signing in again.
struct SyncStatusSummary: Equatable {
    enum Kind: Equatable {
        case hidden
        case progress
        case offline
        case problem
        case reauth(AccountID)
    }

    var kind: Kind
    var text: String
    var detail: String?

    static func make(statuses: [AccountSyncStatus], accounts: [AccountID: Account]) -> SyncStatusSummary {
        if let reauth = statuses.first(where: { $0.phase == .needsReauth }) {
            let email = accounts[reauth.accountID]?.email ?? "an account"
            return SyncStatusSummary(kind: .reauth(reauth.accountID), text: "Sign in again to \(email)", detail: reauth.message)
        }
        let errors = statuses.filter { $0.phase == .error }
        if !errors.isEmpty, errors.allSatisfy({ ($0.message ?? "").hasPrefix("network") }) {
            return SyncStatusSummary(kind: .offline, text: "Offline", detail: "Changes are saved and will sync when you're back online.")
        }
        if let error = errors.first {
            let email = accounts[error.accountID]?.email ?? "an account"
            return SyncStatusSummary(kind: .problem, text: "Can't sync \(email)", detail: error.message)
        }
        let bootstrapping = statuses.filter { $0.phase == .bootstrapping }
        if !bootstrapping.isEmpty {
            let count = bootstrapping.compactMap(\.bootstrapProgress).reduce(0, +)
            let formatted = NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
            return SyncStatusSummary(kind: .progress, text: count > 0 ? "Downloading mail · \(formatted) messages" : "Downloading mail…")
        }
        return SyncStatusSummary(kind: .hidden, text: "")
    }
}

/// The status line under the message list.
@MainActor
final class SyncStatusBar: NSView {
    static let height: CGFloat = 24

    var onReconnect: ((AccountID) -> Void)?

    private let spinner = NSProgressIndicator()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let button = NSButton(title: "Reconnect", target: nil, action: nil)
    private var summary = SyncStatusSummary(kind: .hidden, text: "")
    private lazy var heightConstraint = heightAnchor.constraint(equalToConstant: 0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        button.bezelStyle = .inline
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.target = self
        button.action = #selector(reconnectClicked)
        let stack = NSStackView(views: [spinner, icon, label, NSView(), button])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,
        ])
        clipsToBounds = true
        apply(summary)
    }

    required init?(coder: NSCoder) {
        nil
    }

    func apply(_ summary: SyncStatusSummary) {
        self.summary = summary
        label.stringValue = summary.text
        toolTip = summary.detail
        button.isHidden = true
        icon.isHidden = true
        spinner.stopAnimation(nil)
        switch summary.kind {
        case .hidden:
            break
        case .progress:
            spinner.startAnimation(nil)
        case .offline:
            icon.image = NSImage(systemSymbolName: "wifi.slash", accessibilityDescription: "Offline")
            icon.isHidden = false
        case .problem:
            icon.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "Sync problem")
            icon.isHidden = false
        case .reauth:
            icon.image = NSImage(systemSymbolName: "person.crop.circle.badge.exclamationmark", accessibilityDescription: "Sign in required")
            icon.isHidden = false
            button.isHidden = false
        }
        heightConstraint.constant = summary.kind == .hidden ? 0 : Self.height
        isHidden = summary.kind == .hidden
    }

    @objc private func reconnectClicked() {
        if case .reauth(let id) = summary.kind { onReconnect?(id) }
    }
}
