import AppKit
import SSCore
import SSDesign

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

/// The account rail (spec §5.2): an opaque `spine` column with the traffic lights in its title-bar zone, All
/// Inboxes at y = 62, a short hairline at 116, the account tiles from 130 at a 50 pt pitch, and Add and
/// Settings pinned to the bottom. The selection is the margin rule at x = 0.
///
/// The account stack scrolls inside a clip from y = 124 down to 12 pt above Add, so tiles never overlap the
/// utilities; while tiles are clipped a hairline marks the clipped edge.
@MainActor
final class AccountStripViewController: NSViewController {
    var onSelect: ((AccountScope) -> Void)?
    /// Add's menu picked a provider (§5.44).
    var onAddAccount: ((ProviderKind) -> Void)?
    var onOpenSettings: (() -> Void)?

    /// The rail's width, derived from the traffic lights by the window (76 on macOS 15, 84 from 26 on).
    var railWidth: CGFloat = Quire.Layout.Rail.width {
        didSet { if oldValue != railWidth { view.needsLayout = true } }
    }

    private(set) var accounts: [Account] = []
    private(set) var scope: AccountScope = .unified

    private let railView = RailView()
    private let zone = TitleBarZoneView()
    private let unifiedTile = AccountStripButton(content: .unified)
    private let scrollView = NSScrollView()
    private let stackView = NonDraggingView()
    private var accountTiles: [AccountID: AccountStripButton] = [:]
    private var pendingTile: AccountStripButton?
    private let addButton = QuireIconButton(symbolName: Quire.Icon.addAccount, size: .large, accessibilityLabel: "Add Account")
    private let settingsButton = QuireIconButton(symbolName: Quire.Icon.settings, size: .large, accessibilityLabel: "Settings")

    private var unreadByAccount: [AccountID: Int] = [:]
    private var statusByAccount: [AccountID: AccountStripButton.Status] = [:]
    private var reconnectingID: AccountID?

    override func loadView() {
        railView.wantsLayer = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.documentView = stackView
        NotificationCenter.default.addObserver(self, selector: #selector(clipDidScroll(_:)),
                                               name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        unifiedTile.toolTip = "All Inboxes  ⌘0"
        unifiedTile.setAccessibilityLabel("All Inboxes")
        unifiedTile.isSelected = true
        unifiedTile.target = self
        unifiedTile.action = #selector(tileClicked(_:))
        unifiedTile.onArrow = { [weak self] delta in self?.moveSelection(from: .unified, by: delta) }

        addButton.toolTip = "Add Account"
        addButton.target = self
        addButton.action = #selector(addClicked(_:))
        settingsButton.toolTip = "Settings  ⌘,"
        settingsButton.target = self
        settingsButton.action = #selector(settingsClicked(_:))

        railView.addSubview(zone)
        railView.addSubview(unifiedTile)
        railView.addSubview(scrollView)
        railView.addSubview(addButton)
        railView.addSubview(settingsButton)
        railView.onLayout = { [weak self] in self?.layoutRail() }
        view = railView
    }

    // MARK: Layout

    private func layoutRail() {
        let width = railView.bounds.width
        let height = railView.bounds.height
        let r = Quire.Layout.Rail.self
        let margin = AccountStripButton.verticalMargin
        zone.frame = NSRect(x: 0, y: 0, width: width, height: Quire.Layout.Window.titlebarZone)
        unifiedTile.frame = NSRect(x: 0, y: r.unifiedTop - margin, width: width, height: AccountStripButton.height)

        let utility = r.utility
        let utilityX = ((width - utility) / 2).rounded()
        let addTop = height - r.addTopFromBottom
        addButton.frame = addButton.frame(forVisualRect: NSRect(x: utilityX, y: addTop, width: utility, height: utility))
        settingsButton.frame = settingsButton.frame(forVisualRect: NSRect(x: utilityX, y: height - r.settingsTopFromBottom,
                                                                          width: utility, height: utility))

        let clipTop = r.accountTop - r.stackTopInset
        let clipHeight = max(0, addTop - r.stackBottomGap - clipTop)
        scrollView.frame = NSRect(x: 0, y: clipTop, width: width, height: clipHeight)
        let tiles = orderedTiles
        let contentHeight = tiles.isEmpty ? 0 : r.stackTopInset + CGFloat(tiles.count - 1) * r.accountPitch + r.tile + r.stackBottomGap
        stackView.frame = NSRect(x: 0, y: 0, width: width, height: max(clipHeight, contentHeight))
        for (index, tile) in tiles.enumerated() {
            let top = r.stackTopInset + CGFloat(index) * r.accountPitch
            tile.frame = NSRect(x: 0, y: top - margin, width: width, height: AccountStripButton.height)
        }
        railView.dividerRect = NSRect(x: ((width - r.dividerWidth) / 2).rounded(), y: r.dividerY, width: r.dividerWidth, height: 1)
        updateClipEdges()
    }

    /// A sign-in adding an account is waiting for the browser (§5.44).
    var showsPendingTile: Bool { pendingTile != nil }

    /// Account tiles in rail order, then the pending tile.
    private var orderedTiles: [AccountStripButton] {
        accounts.compactMap { accountTiles[$0.id] } + (pendingTile.map { [$0] } ?? [])
    }

    @objc private func clipDidScroll(_ note: Notification) {
        updateClipEdges()
    }

    private func updateClipEdges() {
        let clip = scrollView.contentView.bounds
        let documentHeight = stackView.frame.height
        let frame = scrollView.frame
        let clippedBelow = clip.maxY < documentHeight - 0.5 && documentHeight > frame.height
        let clippedAbove = clip.minY > 0.5
        railView.clipEdges = (top: clippedAbove ? frame.minY : nil, bottom: clippedBelow ? frame.maxY : nil)
    }

    // MARK: Accounts

    func setAccounts(_ accounts: [Account]) {
        self.accounts = accounts
        let monograms = AccountMonogram.monograms(for: accounts)
        var tiles: [AccountID: AccountStripButton] = [:]
        for account in accounts {
            let content = AccountStripButton.Content.account(monogram: monograms[account.id] ?? "?", slot: account.inkSlot)
            let tile = accountTiles[account.id] ?? makeAccountTile(content)
            tile.content = content
            tiles[account.id] = tile
        }
        for (id, tile) in accountTiles where tiles[id] == nil { tile.removeFromSuperview() }
        accountTiles = tiles
        refreshTileDetails()
        if case .account(let id) = scope, tiles[id] == nil {
            select(.unified, notify: true)
        } else {
            refreshSelection()
        }
        view.needsLayout = true
    }

    private func makeAccountTile(_ content: AccountStripButton.Content) -> AccountStripButton {
        let tile = AccountStripButton(content: content)
        tile.target = self
        tile.action = #selector(tileClicked(_:))
        stackView.addSubview(tile)
        return tile
    }

    func setUnreadCounts(unified: Int, perAccount: [AccountID: Int]) {
        unifiedTile.unreadCount = unified
        unreadByAccount = perAccount
        for (id, tile) in accountTiles { tile.unreadCount = perAccount[id] ?? 0 }
    }

    /// Needs sign-in and first download replace the badge; everything else leaves the count.
    func setStatuses(_ statuses: [AccountSyncStatus]) {
        var byAccount: [AccountID: AccountStripButton.Status] = [:]
        for status in statuses {
            switch status.phase {
            case .needsReauth: byAccount[status.accountID] = .needsSignIn
            case .bootstrapping: byAccount[status.accountID] = .firstSync
            default: byAccount[status.accountID] = .normal
            }
        }
        guard byAccount != statusByAccount else { return }
        statusByAccount = byAccount
        refreshTileDetails()
    }

    /// A browser sign-in is waiting (§5.44): adding shows the pending tile at the end of the stack;
    /// reconnecting keeps the account's attention badge and changes its tooltip. Add is disabled while any
    /// sign-in runs, wherever it started (Settings and the File menu too), because only one runs at a time.
    func setSignIn(active: Bool, adding: Bool, reconnecting: AccountID?) {
        reconnectingID = reconnecting
        addButton.isEnabled = !active
        if adding, pendingTile == nil {
            let tile = AccountStripButton(content: .pending)
            tile.toolTip = "Finish signing in in your browser…"
            tile.setAccessibilityLabel("Finish signing in in your browser")
            stackView.addSubview(tile)
            pendingTile = tile
        } else if !adding, let tile = pendingTile {
            tile.removeFromSuperview()
            pendingTile = nil
        }
        refreshTileDetails()
        view.needsLayout = true
        if let pendingTile { scrollIntoView(pendingTile) }
    }

    private func refreshTileDetails() {
        for (index, account) in accounts.enumerated() {
            guard let tile = accountTiles[account.id] else { continue }
            tile.status = statusByAccount[account.id] ?? .normal
            tile.unreadCount = unreadByAccount[account.id] ?? 0
            tile.onArrow = { [weak self] delta in self?.moveSelection(from: .account(account.id), by: delta) }
            let name = AccountMonogram.name(for: account)
            let shortcut = index < 9 ? "  ⌘\(index + 1)" : ""
            if reconnectingID == account.id {
                tile.toolTip = "Finish signing in in your browser…"
            } else if tile.status == .needsSignIn {
                tile.toolTip = "Sign in required"
            } else {
                tile.toolTip = "\(name) · \(account.email)\(shortcut)"
            }
            tile.setAccessibilityLabel("\(name), \(account.email)")
        }
    }

    // MARK: Selection

    /// ⌘0 is All Inboxes; ⌘1…⌘9 are accounts in rail order.
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
        if case .account(let id) = scope, let tile = accountTiles[id] { scrollIntoView(tile) }
        if notify { onSelect?(scope) }
    }

    private func refreshSelection() {
        unifiedTile.isSelected = scope == .unified
        for (id, tile) in accountTiles { tile.isSelected = scope == .account(id) }
    }

    /// Instantly, as ⌘1…⌘9 and ↑/↓ want (§5.2).
    private func scrollIntoView(_ tile: AccountStripButton) {
        view.layoutSubtreeIfNeeded()
        let rect = tile.convert(tile.tileRect.insetBy(dx: 0, dy: -Quire.Layout.Rail.stackTopInset), to: stackView)
        stackView.scrollToVisible(rect)
    }

    /// ↑/↓ on a focused tile: choose the neighbour and keep the keyboard on it.
    private func moveSelection(from current: AccountScope, by delta: Int) {
        let order: [AccountScope] = [.unified] + accounts.map { .account($0.id) }
        guard let index = order.firstIndex(of: current) else { return }
        let next = index + delta
        guard order.indices.contains(next) else { return }
        let target = order[next]
        select(target, notify: true)
        let tile: AccountStripButton?
        switch target {
        case .unified: tile = unifiedTile
        case .account(let id): tile = accountTiles[id]
        }
        if let tile { view.window?.makeFirstResponder(tile) }
    }

    /// The tile that takes the keyboard when Tab enters the rail: the selected one.
    var selectedTile: NSView {
        if case .account(let id) = scope, let tile = accountTiles[id] { return tile }
        return unifiedTile
    }

    /// The rail's key views in order: the selected tile, Add, Settings.
    var keyViews: [NSView] { [selectedTile, addButton, settingsButton] }

    // MARK: Actions

    @objc private func tileClicked(_ sender: AccountStripButton) {
        if sender === unifiedTile {
            select(.unified, notify: true)
        } else if let id = accountTiles.first(where: { $0.value === sender })?.key {
            select(.account(id), notify: true)
        }
    }

    @objc private func addClicked(_ sender: Any?) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for (title, kind) in [("Add Gmail Account…", ProviderKind.gmail), ("Add Microsoft Account…", .microsoft)] {
            let item = NSMenuItem(title: title, action: #selector(addProviderPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            item.image = QuireSymbol.image(Quire.Icon.addAccountProvider, size: .inText)
            menu.addItem(item)
        }
        // Leading-aligned, 4 pt below the button; the button reads as pressed while its menu is open.
        let visual = addButton.alignmentRect(forFrame: addButton.frame)
        addButton.displayState = .pressed
        menu.popUp(positioning: nil, at: NSPoint(x: visual.minX, y: visual.maxY + Quire.Layout.Rail.addMenuOffsetY), in: railView)
        addButton.displayState = nil
    }

    @objc private func addProviderPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = ProviderKind(rawValue: raw) else { return }
        onAddAccount?(kind)
    }

    @objc private func settingsClicked(_ sender: Any?) {
        onOpenSettings?()
    }
}

/// The rail's own surface: opaque `spine`, the 20 pt divider hairline and the clip-edge hairlines. The split
/// view's divider is the rail's trailing hairline.
@MainActor
private final class RailView: NonDraggingView {
    var onLayout: (() -> Void)?
    var dividerRect: NSRect = .zero { didSet { if oldValue != dividerRect { needsDisplay = true } } }
    var clipEdges: (top: CGFloat?, bottom: CGFloat?) = (nil, nil) {
        didSet { if oldValue.top != clipEdges.top || oldValue.bottom != clipEdges.bottom { needsDisplay = true } }
    }

    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(environmentDidChange(_:)),
                                               name: QuireEnvironment.didChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("built in code") }

    @objc private func environmentDidChange(_ note: Notification) {
        needsDisplay = true
    }

    /// Frames are set by hand; a new size lays the contents out again.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        onLayout?()
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qSpine.setFill()
        // Views do not clip to their bounds by default, so the fill is limited to them by hand.
        dirtyRect.intersection(bounds).fill()
        let hairline = QuireHairline.width(for: self)
        NSColor.qRule.setFill()
        NSRect(x: dividerRect.minX, y: dividerRect.minY, width: dividerRect.width, height: hairline).fill()
        if let top = clipEdges.top {
            NSRect(x: 0, y: top, width: bounds.width, height: hairline).fill()
        }
        if let bottom = clipEdges.bottom {
            NSRect(x: 0, y: bottom - hairline, width: bounds.width, height: hairline).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsDisplay = true
    }

    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { "Accounts" }
    override func isAccessibilityElement() -> Bool { true }
}
