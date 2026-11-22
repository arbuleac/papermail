import AppKit
import PaperCore
import PaperDesign

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

/// The rail (spec §5.2): an opaque `spine` column with the traffic lights in its title-bar zone, the six views as
/// folder tiles from y = 62 (Inbox to Trash at a 44 pt pitch, a short hairline, All Mail), and at its foot the
/// account group anchored just above Add: All Inboxes, a short hairline, the account tiles at a 50 pt pitch, then
/// Add and Settings. The view's selection is a raised folder tile; the scope's is the margin rule at x = 0.
/// Inbox, Starred, Trash and All Mail take rows dragged from the list; the window decides and acts. Two folders show only
/// while they hold something (`ConditionalFolders`): Later, directly below Inbox, while something in the scope is
/// snoozed, and the Outbox, between Drafts and Trash, while a send in the scope waits to go (§5.53). Every folder below a
/// shown one, the hairline and All Mail included, moves down one pitch for it; neither takes a drop.
///
/// The account group rises as accounts are added until All Inboxes would come within `groupGap` of All Mail;
/// from then on the account tiles scroll inside their own clip, which ends 12 pt above Add, so tiles never
/// overlap the folders or the utilities. While tiles are clipped a hairline marks the clipped edge.
@MainActor
final class AccountStripViewController: NSViewController {
    var onSelect: ((AccountScope) -> Void)?
    /// A folder tile was clicked or chosen with ↑/↓: switch the view as the title menu does.
    var onSelectView: ((MailboxView) -> Void)?
    /// Add's menu picked a provider (§5.44).
    var onAddAccount: ((ProviderKind) -> Void)?
    var onOpenSettings: (() -> Void)?
    /// Rows dragged from the list over a folder that takes drops (Inbox, Starred, Trash, All Mail; §5.2):
    /// whether the window would act on these conversations there.
    var acceptsDrop: ((MailboxView, [ConversationID]) -> Bool)?
    /// The rows were dropped on that folder: act on them, true when the window took them.
    var onDrop: ((MailboxView, [ConversationID]) -> Bool)?

    /// The rail's width, derived from the traffic lights by the window (76 on macOS 15, 84 from 26 on).
    var railWidth: CGFloat = Quire.Layout.Rail.width {
        didSet { if oldValue != railWidth { view.needsLayout = true } }
    }

    private(set) var accounts: [Account] = []
    private(set) var scope: AccountScope = .unified
    private(set) var mailboxView: MailboxView = .inbox
    /// Which conditional folders show (§5.2). The window decides.
    private(set) var conditionalFolders = ConditionalFolders()
    /// Something in the scope is snoozed: the Later tile shows below Inbox.
    var showsLater: Bool { conditionalFolders.later }
    /// A send in the scope waits to go: the Outbox tile shows after Drafts (§5.53).
    var showsOutbox: Bool { conditionalFolders.outbox }

    private let railView = RailView()
    private let zone = TitleBarZoneView()
    /// One tile per view, in the title menu's order.
    private(set) var folderTiles: [AccountStripButton] = []
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

        railView.addSubview(zone)
        for entry in TitleMenu.entries {
            let tile = AccountStripButton(content: .folder(symbol: entry.symbol))
            tile.toolTip = "\(entry.title)  \(entry.sequence)"
            tile.setAccessibilityLabel(entry.title)
            tile.isSelected = entry.view == mailboxView
            tile.isHidden = !conditionalFolders.shows(entry.view)
            tile.target = self
            tile.action = #selector(folderClicked(_:))
            let view = entry.view
            tile.onArrow = { [weak self] delta in self?.moveView(from: view, by: delta) }
            railView.addSubview(tile)
            folderTiles.append(tile)
        }

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

        railView.addSubview(unifiedTile)
        railView.addSubview(scrollView)
        railView.addSubview(addButton)
        railView.addSubview(settingsButton)
        railView.onLayout = { [weak self] in self?.layoutRail() }
        // The rail, not each folder, is the drag destination (see `dropTarget(at:)`). Only the list's rows:
        // files, text and anything else dragged in are refused before the rail is asked.
        railView.registerForDraggedTypes([MessageListViewController.conversationPasteboardType])
        railView.drops = self
        view = railView
    }

    // MARK: Layout

    /// The folders that show only while they hold something (§5.2): Later while something in the scope is snoozed, the
    /// Outbox while a send in the scope waits to go (§5.53). Either, both or neither may show; each one shown takes a
    /// folder pitch in the column.
    struct ConditionalFolders: Equatable {
        var later = false
        var outbox = false

        /// Whether `view`'s tile is in the rail now: every other folder always is.
        func shows(_ view: MailboxView) -> Bool {
            switch view {
            case .later: return later
            case .outbox: return outbox
            default: return true
            }
        }
    }

    /// The top edge of `view`'s folder tile: the shown folders in the title menu's order from Inbox at the folder pitch
    /// (Inbox, Later while it shows, Starred, Sent, Drafts, the Outbox while it shows, Trash), and All Mail below the
    /// folders' hairline, which moves down with them.
    static func folderTop(for view: MailboxView, showing shown: ConditionalFolders = ConditionalFolders()) -> CGFloat {
        let r = Quire.Layout.Rail.self
        if view == .all { return r.allMailTop + folderShift(shown) }
        let visible = TitleMenu.entries.filter { $0.view != .all && shown.shows($0.view) }
        let position = visible.firstIndex { $0.view == view } ?? 0
        return r.folderTop + CGFloat(position) * r.folderPitch
    }

    /// How far the hairline and All Mail move down: one pitch for every conditional tile shown, since both tiles sit above
    /// them, so with Later and the Outbox both there they sit two pitches lower. The folders' own places are `folderTop`'s.
    static func folderShift(_ shown: ConditionalFolders) -> CGFloat {
        CGFloat([shown.later, shown.outbox].filter { $0 }.count) * Quire.Layout.Rail.folderPitch
    }

    /// Where the account group sits in a rail `railHeight` tall with `tileCount` tiles (accounts and the pending
    /// tile), all values top edges in rail coordinates (§5.2).
    struct AccountGroupLayout: Equatable {
        var unifiedTop: CGFloat
        var dividerY: CGFloat
        /// The account tiles' clip: from `stackInset` above the first tile to 12 pt above Add.
        var clipTop: CGFloat
        var clipBottom: CGFloat
        /// The tiles' own height inside the clip, `stackInset` at both ends included.
        var contentHeight: CGFloat

        var scrolls: Bool { contentHeight > clipBottom - clipTop + 0.5 }
    }

    static func accountGroupLayout(railHeight: CGFloat, tileCount: Int,
                                   showing shown: ConditionalFolders = ConditionalFolders()) -> AccountGroupLayout {
        let r = Quire.Layout.Rail.self
        let allMailTop = r.allMailTop + folderShift(shown)
        let clipBottom = railHeight - r.addTopFromBottom - r.stackBottomGap
        let others = CGFloat(max(0, tileCount - 1)) * r.accountPitch
        // Anchored above Add: the last tile ends `stackInset` inside the clip's bottom.
        let naturalFirstTop = clipBottom - r.stackInset - r.tile - others
        let naturalUnifiedTop = naturalFirstTop - r.accountGap - r.dividerGap - r.tile
        // …but never closer than `groupGap` to All Mail: from there on the tiles scroll.
        let unifiedTop = max(allMailTop + r.tile + r.groupGap, naturalUnifiedTop)
        let dividerY = unifiedTop + r.tile + r.dividerGap
        let clipTop = dividerY + r.accountGap - r.stackInset
        let content = tileCount == 0 ? 0 : 2 * r.stackInset + others + r.tile
        return AccountGroupLayout(unifiedTop: unifiedTop, dividerY: dividerY, clipTop: clipTop,
                                  clipBottom: max(clipTop, clipBottom), contentHeight: content)
    }

    private func layoutRail() {
        // Centred on the whole rail, its trailing hairline included (§3.2: x = width / 2), not on this pane,
        // which ends where the split's divider (that hairline) begins.
        let width = max(railView.bounds.width, railWidth)
        let height = railView.bounds.height
        let r = Quire.Layout.Rail.self
        let margin = AccountStripButton.verticalMargin
        zone.frame = NSRect(x: 0, y: 0, width: width, height: Quire.Layout.Window.titlebarZone)
        for (entry, tile) in zip(TitleMenu.entries, folderTiles) {
            tile.isHidden = !conditionalFolders.shows(entry.view)
            tile.frame = NSRect(x: 0, y: Self.folderTop(for: entry.view, showing: conditionalFolders) - margin, width: width,
                                height: AccountStripButton.height)
        }

        let utility = r.utility
        let utilityX = ((width - utility) / 2).rounded()
        let addTop = height - r.addTopFromBottom
        addButton.frame = addButton.frame(forVisualRect: NSRect(x: utilityX, y: addTop, width: utility, height: utility))
        settingsButton.frame = settingsButton.frame(forVisualRect: NSRect(x: utilityX, y: height - r.settingsTopFromBottom,
                                                                          width: utility, height: utility))

        let tiles = orderedTiles
        let group = Self.accountGroupLayout(railHeight: height, tileCount: tiles.count, showing: conditionalFolders)
        unifiedTile.frame = NSRect(x: 0, y: group.unifiedTop - margin, width: width, height: AccountStripButton.height)
        let clipHeight = group.clipBottom - group.clipTop
        scrollView.frame = NSRect(x: 0, y: group.clipTop, width: width, height: clipHeight)
        stackView.frame = NSRect(x: 0, y: 0, width: width, height: max(clipHeight, group.contentHeight))
        for (index, tile) in tiles.enumerated() {
            let top = r.stackInset + CGFloat(index) * r.accountPitch
            tile.frame = NSRect(x: 0, y: top - margin, width: width, height: AccountStripButton.height)
        }
        let dividerX = ((width - r.dividerWidth) / 2).rounded()
        railView.dividerRects = [NSRect(x: dividerX, y: r.folderDividerY + Self.folderShift(conditionalFolders), width: r.dividerWidth, height: 1),
                                 NSRect(x: dividerX, y: group.dividerY, width: r.dividerWidth, height: 1)]
        updateClipEdges()
    }

    /// A sign-in adding an account is waiting for the browser (§5.44).
    var showsPendingTile: Bool { pendingTile != nil }

    /// Account tiles in rail order, then the pending tile.
    private var orderedTiles: [AccountStripButton] {
        accounts.compactMap { accountTiles[$0.id] } + (pendingTile.map { [$0] } ?? [])
    }

    /// The hairline between Trash and All Mail, in rail coordinates (the app's tests check it moves with Later and the
    /// Outbox).
    var folderDividerRect: NSRect {
        view.layoutSubtreeIfNeeded()
        return railView.dividerRects.first ?? .zero
    }

    /// The account tiles' clip, in rail coordinates (the app's tests check what it shows).
    var accountClipFrame: NSRect { scrollView.frame }

    /// The account and pending tiles' 38 pt squares in rail coordinates, as drawn now (scrolled or not).
    var accountTileRects: [NSRect] {
        view.layoutSubtreeIfNeeded()
        return orderedTiles.map { $0.convert($0.tileRect, to: railView) }
    }

    /// The tile `scope` selects (All Inboxes or an account), for the app's tests.
    func tile(for scope: AccountScope) -> AccountStripButton? {
        switch scope {
        case .unified: return unifiedTile
        case .account(let id): return accountTiles[id]
        }
    }

    @objc private func clipDidScroll(_ note: Notification) {
        updateClipEdges()
        // Their rects are cut to what the clip showed when AppKit last asked.
        for case let tile as AccountStripButton in stackView.subviews { tile.pointerRegionsDidChange() }
    }

    private func updateClipEdges() {
        let clip = scrollView.contentView.bounds
        let documentHeight = stackView.frame.height
        let frame = scrollView.frame
        let clippedBelow = clip.maxY < documentHeight - 0.5 && documentHeight > frame.height
        let clippedAbove = clip.minY > 0.5
        railView.clipEdges = (top: clippedAbove ? frame.minY : nil, bottom: clippedBelow ? frame.maxY : nil)
    }

    /// The clipped-edge hairlines drawn now, for tests: the clip's top once scrolled, its bottom while tiles
    /// are hidden below.
    var clipEdges: (top: CGFloat?, bottom: CGFloat?) { railView.clipEdges }

    // MARK: Accounts

    func setAccounts(_ accounts: [Account]) {
        self.accounts = accounts
        let faces = AccountFaces.faces(for: accounts)
        var tiles: [AccountID: AccountStripButton] = [:]
        for account in accounts {
            let content = AccountStripButton.Content.account(face: faces[account.id] ?? .monogram("?"), slot: account.inkSlot)
            let tile = accountTiles[account.id] ?? makeAccountTile(content)
            tile.content = content
            tiles[account.id] = tile
        }
        for (id, tile) in accountTiles where tiles[id] == nil { tile.removeFromSuperview() }
        accountTiles = tiles
        refreshTileDetails()
        if case .account(let id) = scope, tiles[id] == nil {
            // The rail's own step, as the account goes, not a move the user made.
            Analytics.quietly { select(.unified, notify: true) }
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

    /// The Inbox tile's badge: the unread Inbox count of the current scope, as the title menu's Inbox item shows.
    func setInboxUnread(_ count: Int) {
        folderTiles.first?.unreadCount = count
    }

    /// Shows or hides the Later tile below Inbox (§5.2); the folders below it move by one pitch, instantly, as the
    /// rail moves everything.
    func setShowsLater(_ shows: Bool) {
        var shown = conditionalFolders
        shown.later = shows
        setConditionalFolders(shown)
    }

    /// Shows or hides the Outbox tile between Drafts and Trash (§5.2, §5.53), as `setShowsLater` does Later's.
    func setShowsOutbox(_ shows: Bool) {
        var shown = conditionalFolders
        shown.outbox = shows
        setConditionalFolders(shown)
    }

    private func setConditionalFolders(_ shown: ConditionalFolders) {
        guard shown != conditionalFolders else { return }
        conditionalFolders = shown
        guard isViewLoaded else { return }
        // AppKit hands a hidden first responder's focus to the window, leaving no ring and dead arrows. The keyboard goes
        // to the Inbox tile instead, the view the window turns to as a conditional folder goes.
        if let window = view.window, let inbox = folderTiles.first,
           let focused = zip(TitleMenu.entries, folderTiles).first(where: { window.firstResponder === $0.1 }), !shown.shows(focused.0.view) {
            window.makeFirstResponder(inbox)
        }
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
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
            let name = AccountLabels.name(for: account)
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

    /// Shows `view` as the selected folder. `notify` is for the rail's own clicks and arrows; the window calls
    /// it without, whenever the view changes from anywhere (G-sequences, menus, a notification).
    func selectView(_ view: MailboxView, notify: Bool) {
        mailboxView = view
        for (entry, tile) in zip(TitleMenu.entries, folderTiles) { tile.isSelected = entry.view == view }
        if notify { onSelectView?(view) }
    }

    /// ↑/↓ on a focused folder: choose the neighbour view and keep the keyboard on its tile. A hidden Later or Outbox tile
    /// is stepped over.
    private func moveView(from current: MailboxView, by delta: Int) {
        let visible = TitleMenu.entries.indices.filter { conditionalFolders.shows(TitleMenu.entries[$0].view) }
        guard let position = visible.firstIndex(where: { TitleMenu.entries[$0].view == current }) else { return }
        let next = position + delta
        guard visible.indices.contains(next) else { return }
        let index = visible[next]
        selectView(TitleMenu.entries[index].view, notify: true)
        view.window?.makeFirstResponder(folderTiles[index])
    }

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
        scrollSelectionIntoView()
        if notify { onSelect?(scope) }
    }

    /// A rail not yet in a window (the launch restoring the last scope) has no size: an offset worked out then
    /// survives the window's sizing and can hide tiles above or the chosen one below. It waits for the rail to
    /// appear, by then at the window's final frame.
    private var scrollsSelectionOnAppear = false

    override func viewDidAppear() {
        super.viewDidAppear()
        if scrollsSelectionOnAppear { scrollSelectionIntoView() }
    }

    private func scrollSelectionIntoView() {
        scrollsSelectionOnAppear = false
        guard case .account(let id) = scope, let tile = accountTiles[id] else { return }
        guard view.window != nil else {
            scrollsSelectionOnAppear = true
            return
        }
        scrollIntoView(tile)
    }

    private func refreshSelection() {
        unifiedTile.isSelected = scope == .unified
        for (id, tile) in accountTiles { tile.isSelected = scope == .account(id) }
    }

    /// Instantly, as ⌘1…⌘9 and ↑/↓ want (§5.2).
    private func scrollIntoView(_ tile: AccountStripButton) {
        view.layoutSubtreeIfNeeded()
        let rect = tile.convert(tile.tileRect.insetBy(dx: 0, dy: -Quire.Layout.Rail.stackInset), to: stackView)
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

    /// The tile that takes the keyboard when Tab reaches the accounts: the selected one.
    var selectedTile: NSView {
        if case .account(let id) = scope, let tile = accountTiles[id] { return tile }
        return unifiedTile
    }

    /// The folder that takes the keyboard when Tab enters the rail: the current view's.
    var selectedFolderTile: NSView {
        let index = TitleMenu.entries.firstIndex { $0.view == mailboxView } ?? 0
        return folderTiles[index]
    }

    /// The rail's key views in order: the selected folder, the selected account tile, Add, Settings.
    var keyViews: [NSView] { [selectedFolderTile, selectedTile, addButton, settingsButton] }

    // MARK: Actions

    @objc private func folderClicked(_ sender: AccountStripButton) {
        guard let index = folderTiles.firstIndex(where: { $0 === sender }) else { return }
        Analytics.from(.rail) { selectView(TitleMenu.entries[index].view, notify: true) }
    }

    @objc private func tileClicked(_ sender: AccountStripButton) {
        Analytics.from(.rail) {
            if sender === unifiedTile {
                select(.unified, notify: true)
            } else if let id = accountTiles.first(where: { $0.value === sender })?.key {
                select(.account(id), notify: true)
            }
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

    // MARK: Dropping rows (§5.2)

    /// The folder under the drag and whether it takes it, asked again only when the pointer reaches another
    /// folder: the rows and the view do not change while the pointer moves.
    private var dropFolder: (tile: AccountStripButton, view: MailboxView, accepts: Bool)?

    /// The folder taking drops (Inbox, Starred, Trash, All Mail) whose 44 pt hit square holds the drag. AppKit
    /// routes a drag by view frames and never asks `hitTest`, and each folder's full-width frame overlaps its
    /// neighbours' by 10 pt, so tiles registered on their own would let a drag at a square's rim land on the
    /// next folder down. The rail routes by the square a click uses instead, and the squares abut.
    private func dropTarget(at info: NSDraggingInfo) -> (tile: AccountStripButton, view: MailboxView)? {
        // Later and the Outbox take no drop (`RailDrop`); their squares only push the folders below them down.
        for (entry, tile) in zip(TitleMenu.entries, folderTiles) where RailDrop.change(for: entry.view) != nil && !tile.isHidden {
            if tile.hitRect.contains(tile.convert(info.draggingLocation, from: nil)) { return (tile, entry.view) }
        }
        return nil
    }

    /// The conversations a drag carries, when it comes from this app's list. A drag from another app has no
    /// source here (`draggingSource` is nil across apps), so rows from another copy of Paper, which name
    /// conversations of a different store, are refused with the files and text.
    private static func draggedConversations(_ info: NSDraggingInfo) -> [ConversationID] {
        guard info.draggingSource != nil else { return [] }
        return MessageListViewController.conversationIDs(on: info.draggingPasteboard)
    }

    /// A drag entered the rail: nothing from an earlier drag is kept.
    fileprivate func dragEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        dragEnded()
        return dragMoved(info)
    }

    /// The drag moved over the rail, or stood still while AppKit asked again: light the folder under it if
    /// that folder takes it.
    fileprivate func dragMoved(_ info: NSDraggingInfo) -> NSDragOperation {
        let target = dropTarget(at: info)
        if target?.tile !== dropFolder?.tile {
            dropFolder?.tile.isDropTarget = false
            dropFolder = target.map { target in
                let ids = Self.draggedConversations(info)
                return (target.tile, target.view, !ids.isEmpty && acceptsDrop?(target.view, ids) == true)
            }
        }
        guard let dropFolder, dropFolder.accepts else { return [] }
        // A drop does the same whatever modifier is held, so the cursor shows the plainest operation the list
        // allows now: a move, or a copy while ⌥ narrows the list's mask to it. Read on every move, because the
        // mask changes under a still pointer as modifiers are pressed; ⌘ empties it and the folder goes dark.
        let allowed = info.draggingSourceOperationMask
        let operation = [NSDragOperation.move, .copy].first { allowed.contains($0) } ?? []
        dropFolder.tile.isDropTarget = !operation.isEmpty
        return operation
    }

    /// The drag left the rail, ended, or dropped.
    fileprivate func dragEnded() {
        dropFolder?.tile.isDropTarget = false
        dropFolder = nil
    }

    fileprivate func performDrop(_ info: NSDraggingInfo) -> Bool {
        defer { dragEnded() }
        let ids = Self.draggedConversations(info)
        guard let target = dropTarget(at: info), !ids.isEmpty else { return false }
        return onDrop?(target.view, ids) ?? false
    }
}

/// The rail's own surface: opaque `spine`, the two 20 pt divider hairlines (under Trash, under All Inboxes) and
/// the clip-edge hairlines. The split view's divider is the rail's trailing hairline.
@MainActor
private final class RailView: NonDraggingView {
    var onLayout: (() -> Void)?
    /// Routes rows dragged over the rail to the folder under them (§5.2).
    weak var drops: AccountStripViewController?
    var dividerRects: [NSRect] = [] { didSet { if oldValue != dividerRects { needsDisplay = true } } }
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

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { drops?.dragEntered(sender) ?? [] }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { drops?.dragMoved(sender) ?? [] }
    override func draggingExited(_ sender: NSDraggingInfo?) { drops?.dragEnded() }
    override func draggingEnded(_ sender: NSDraggingInfo) { drops?.dragEnded() }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { drops?.performDrop(sender) ?? false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qSpine.setFill()
        // Views do not clip to their bounds by default, so the fill is limited to them by hand.
        dirtyRect.intersection(bounds).fill()
        let hairline = QuireHairline.width(for: self)
        NSColor.qRule.setFill()
        for divider in dividerRects {
            NSRect(x: divider.minX, y: divider.minY, width: divider.width, height: hairline).fill()
        }
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
    override func accessibilityLabel() -> String? { "Mailboxes and accounts" }
    override func isAccessibilityElement() -> Bool { true }
}
