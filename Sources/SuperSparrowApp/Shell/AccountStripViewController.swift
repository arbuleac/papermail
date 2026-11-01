import AppKit
import SSCore

/// What the list is narrowed to: every account (the unified inbox) or one.
enum AccountScope: Hashable {
    case unified
    case account(AccountID)

    var accountIDs: [AccountID]? {
        switch self {
        case .unified: return nil
        case .account(let id): return [id]
        }
    }
}

/// The thin column on the left: unified inbox, one avatar per account, add and settings at the bottom.
@MainActor
final class AccountStripViewController: NSViewController {
    static let width: CGFloat = 64
    /// Room for the traffic lights, which sit over the strip in the full-size content view.
    static let topInset: CGFloat = 44

    var onSelect: ((AccountScope) -> Void)?
    var onAddAccount: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private(set) var accounts: [Account] = []
    private(set) var scope: AccountScope = .unified

    private let unifiedButton = AccountStripButton(content: .unified)
    private let accountStack = NSStackView()
    private var accountButtons: [AccountID: AccountStripButton] = [:]
    private let addButton = AccountStripButton(content: .symbol("plus", "Add Account"))
    private let settingsButton = AccountStripButton(content: .symbol("gearshape", "Settings"))

    override func loadView() {
        let root = NSVisualEffectView()
        root.material = .sidebar
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState
        root.translatesAutoresizingMaskIntoConstraints = false

        unifiedButton.toolTip = "All Inboxes (⌘0)"
        unifiedButton.setAccessibilityLabel("All Inboxes")
        unifiedButton.isSelected = true
        unifiedButton.onClick = { [weak self] in self?.select(.unified, notify: true) }
        addButton.toolTip = "Add Account…"
        addButton.setAccessibilityLabel("Add Account")
        addButton.onClick = { [weak self] in self?.onAddAccount?() }
        settingsButton.toolTip = "Settings (⌘,)"
        settingsButton.setAccessibilityLabel("Settings")
        settingsButton.onClick = { [weak self] in self?.onOpenSettings?() }

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 28).isActive = true

        accountStack.orientation = .vertical
        accountStack.spacing = 8
        accountStack.alignment = .centerX

        let top = NSStackView(views: [unifiedButton, separator, accountStack])
        top.orientation = .vertical
        top.spacing = 8
        top.alignment = .centerX
        top.translatesAutoresizingMaskIntoConstraints = false

        let bottom = NSStackView(views: [addButton, settingsButton])
        bottom.orientation = .vertical
        bottom.spacing = 0
        bottom.alignment = .centerX
        bottom.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(top)
        root.addSubview(bottom)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            top.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.topInset),
            top.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            bottom.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            bottom.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            top.bottomAnchor.constraint(lessThanOrEqualTo: bottom.topAnchor, constant: -8),
        ])
        view = root
    }

    func setAccounts(_ accounts: [Account]) {
        guard accounts != self.accounts || accountButtons.count != accounts.count else { return }
        self.accounts = accounts
        accountStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var buttons: [AccountID: AccountStripButton] = [:]
        for (index, account) in accounts.enumerated() {
            let color = NSColor(hexString: account.colorHex) ?? .systemGray
            let button = accountButtons[account.id] ?? AccountStripButton(content: .account(initials: "", color: color))
            button.content = .account(initials: Self.initials(for: account), color: color)
            let shortcut = index < 9 ? " (⌘\(index + 1))" : ""
            button.toolTip = account.email + shortcut
            button.setAccessibilityLabel(account.email)
            button.onClick = { [weak self] in self?.select(.account(account.id), notify: true) }
            accountStack.addArrangedSubview(button)
            buttons[account.id] = button
        }
        accountButtons = buttons
        if case .account(let id) = scope, buttons[id] == nil {
            select(.unified, notify: true)
        } else {
            refreshSelection()
        }
    }

    func setUnreadCounts(unified: Int, perAccount: [AccountID: Int]) {
        unifiedButton.badgeCount = unified
        for (id, button) in accountButtons {
            button.badgeCount = perAccount[id] ?? 0
        }
    }

    /// ⌘0 is the unified inbox; ⌘1…⌘9 are accounts in strip order.
    func selectShortcut(_ number: Int) {
        if number == 0 {
            select(.unified, notify: true)
        } else if number - 1 < accounts.count {
            select(.account(accounts[number - 1].id), notify: true)
        }
    }

    func select(_ scope: AccountScope, notify: Bool) {
        self.scope = scope
        refreshSelection()
        if notify { onSelect?(scope) }
    }

    private func refreshSelection() {
        unifiedButton.isSelected = scope == .unified
        for (id, button) in accountButtons {
            button.isSelected = scope == .account(id)
        }
    }

    static func initials(for account: Account) -> String {
        let source = account.displayName.trimmingCharacters(in: .whitespaces).isEmpty ? account.email : account.displayName
        let words = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "@" || $0 == "_" })
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.joined().isEmpty ? "?" : letters.joined()
    }
}
