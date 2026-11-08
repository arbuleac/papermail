import AppKit
import SSCore
import SSDesign

/// The middle column: the 52 pt list header (masthead, which is the title menu in minimal mode, Demo tag, search,
/// compose), the message list, the 28 pt sync status line and the toast overlay.
@MainActor
final class ListPaneViewController: NSViewController {
    static let minimumWidth: CGFloat = Quire.Layout.List.minWidth
    static let maximumWidth: CGFloat = Quire.Layout.List.maxWidth
    static let preferredWidth: CGFloat = Quire.Layout.List.defaultWidth
    static let searchDebounce: TimeInterval = 0.12

    let list: MessageListViewController
    let header = ListHeaderView(frame: .zero)
    let statusBar = SyncStatusBar(frame: .zero)
    let toastView = ToastView()
    private(set) lazy var toasts = ToastPresenter(host: toastView)

    var onViewChange: ((MailboxView) -> Void)?
    var onSearchChange: ((String) -> Void)?
    /// Escape in an empty field, ↓ or Return: give the keyboard back to the list.
    var onLeaveSearch: (() -> Void)?
    var onCompose: (() -> Void)?
    /// The title menu's account items (minimal mode): 0 is All Inboxes, 1…9 the accounts in rail order.
    var onSelectAccountShortcut: ((Int) -> Void)?
    /// The Demo tag's menu.
    var onAddAccount: ((ProviderKind) -> Void)?
    var onLeaveDemo: (() -> Void)?
    /// What the title menu shows, read when it opens.
    var titleMenuModel: (() -> TitleMenu.Model)?

    private var searchTimer: Timer?
    private var mailboxView: MailboxView = .inbox
    private var isNarrowed = false

    init(list: MessageListViewController) {
        self.list = list
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = ListPaneView(frame: .zero)
        root.header = header
        root.statusBar = statusBar
        root.toastView = toastView
        addChild(list)
        root.listView = list.view
        root.addSubview(list.view)
        root.addSubview(header)
        root.addSubview(statusBar)
        root.addSubview(toastView)

        header.masthead.target = self
        header.masthead.action = #selector(mastheadClicked(_:))
        header.demoTag.target = self
        header.demoTag.action = #selector(demoTagClicked(_:))
        header.compose.target = self
        header.compose.action = #selector(composeClicked(_:))
        let search = header.search
        search.onQueryChange = { [weak self] _ in self?.queryChanged() }
        search.onCancel = { [weak self] in self?.onLeaveSearch?() }
        search.onSubmit = { [weak self] _ in self?.submitSearch() }
        search.onCommand = { [weak self] selector in
            guard selector == #selector(NSResponder.moveDown(_:)) else { return false }
            self?.submitSearch()
            return true
        }
        view = root
    }

    // MARK: State from the window controller

    func display(view mailboxView: MailboxView) {
        self.mailboxView = mailboxView
        header.masthead.title = TitleMenu.title(for: mailboxView)
        // The search field starts after the masthead, whose width follows the view's name.
        header.needsLayout = true
        updatePlaceholder()
    }

    /// Minimal mode (§5.1): the masthead moves past the would-be rail to `mastheadX` and becomes the title menu's
    /// button, because the folders and accounts the rail held are only reachable through it. With the rail it
    /// is a plain title at 16.
    func setMinimalMode(_ minimal: Bool, mastheadX: CGFloat) {
        header.mastheadX = mastheadX
        header.masthead.isMenu = minimal
        header.needsLayout = true
    }

    /// Narrowed to one account: “· alex@contoso.test” after the masthead, and “Search Inbox”; while the header line
    /// has no room for the address, the placeholder names the account instead (“Search Contoso”, §5.3).
    func setNarrowedAccount(address: String?, name: String?) {
        isNarrowed = address != nil
        header.address = address
        header.accountName = address == nil ? nil : name
        updatePlaceholder()
    }

    func setNewMailDot(_ shown: Bool) {
        header.showsNewMailDot = shown
    }

    func setDemo(_ isDemo: Bool) {
        header.showsDemoTag = isDemo
    }

    /// No accounts: the field is disabled (§5.6).
    func setSearchEnabled(_ enabled: Bool) {
        header.search.isEnabled = enabled
    }

    private func updatePlaceholder() {
        let placeholder: String
        switch mailboxView {
        case .inbox: placeholder = isNarrowed ? "Search Inbox" : "Search"
        default: placeholder = "Search " + TitleMenu.title(for: mailboxView)
        }
        header.searchPlaceholder = placeholder
    }

    // MARK: Search

    var searchText: String { header.search.query }

    var isSearchFocused: Bool { header.search.hasKeyboardFocus }

    func focusSearch() {
        view.window?.makeFirstResponder(header.search.textField)
        header.search.textField.currentEditor()?.selectAll(nil)
    }

    /// Empties the field. `notify: false` is for callers that apply the resulting query themselves.
    func clearSearch(notify: Bool = true) {
        searchTimer?.invalidate()
        searchTimer = nil
        header.search.isSearching = false
        header.search.resultCount = nil
        guard !header.search.query.isEmpty else { return }
        header.search.query = ""
        if notify { onSearchChange?("") }
    }

    /// The list has rows for the current query: the count shows and the spinner stops. The list reads results a
    /// page at a time, so a full first page is a floor (“200+ results”) that stays put while later pages load.
    func listRowsDidChange() {
        guard !header.search.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            header.search.resultCount = nil
            header.search.isSearching = false
            return
        }
        guard searchTimer == nil else { return }
        header.search.isSearching = false
        let count = list.conversations.count
        let page = list.query.limit
        header.search.resultCountIsLowerBound = count >= page
        header.search.resultCount = min(count, page)
    }

    private func queryChanged() {
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: Self.searchDebounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendQuery() }
        }
    }

    private func sendQuery() {
        searchTimer?.invalidate()
        searchTimer = nil
        let query = header.search.query
        let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        // The field's spinner shows only once the first page has taken more than 150 ms (its own delay).
        header.search.isSearching = searching
        if !searching { header.search.resultCount = nil }
        onSearchChange?(query)
    }

    private func submitSearch() {
        if searchTimer != nil { sendQuery() }
        onLeaveSearch?()
    }

    /// Words typed less than the debounce ago that the list has not been given yet.
    var hasPendingSearch: Bool { searchTimer != nil }

    /// Gives the list the field's words now rather than when the debounce ends: ⌘↩ acts on what was typed.
    func sendPendingSearch() {
        if searchTimer != nil { sendQuery() }
    }

    // MARK: Menus

    @objc private func mastheadClicked(_ sender: Any?) {
        // Only minimal mode has a title menu; beside the rail the masthead is a plain title (§5.3).
        guard header.masthead.isMenu, let model = titleMenuModel?() else { return }
        let menu = TitleMenu.build(model, target: self, viewAction: #selector(viewPicked(_:)), scopeAction: #selector(scopePicked(_:)))
        // Left-aligned to the masthead text, 4 pt below it.
        let masthead = header.masthead
        let visual = masthead.alignmentRect(forFrame: masthead.frame)
        let origin = masthead.superview?.convert(NSPoint(x: visual.minX + Quire.Layout.ListHeader.mastheadHitPad, y: visual.maxY + 4),
                                                 to: header) ?? .zero
        masthead.isMenuOpen = true
        menu.popUp(positioning: nil, at: origin, in: header)
        masthead.isMenuOpen = false
    }

    @objc private func viewPicked(_ sender: NSMenuItem) {
        guard MailboxView.allCases.indices.contains(sender.tag) else { return }
        onViewChange?(MailboxView.allCases[sender.tag])
    }

    @objc private func scopePicked(_ sender: NSMenuItem) {
        onSelectAccountShortcut?(sender.tag)
    }

    @objc private func demoTagClicked(_ sender: Any?) {
        let menu = NSMenu(title: "Demo")
        menu.autoenablesItems = false
        let add = NSMenuItem(title: "Add a Real Account…", action: nil, keyEquivalent: "")
        add.image = QuireSymbol.image(Quire.Icon.addAccountProvider, size: .inText)
        let submenu = NSMenu(title: "Add a Real Account…")
        for (title, kind) in [("Add Gmail Account…", ProviderKind.gmail), ("Add Microsoft Account…", .microsoft)] {
            let item = NSMenuItem(title: title, action: #selector(addRealAccount(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = kind.rawValue
            submenu.addItem(item)
        }
        add.submenu = submenu
        menu.addItem(add)
        menu.addItem(.separator())
        let leave = NSMenuItem(title: "Leave Demo…", action: #selector(leaveDemo(_:)), keyEquivalent: "")
        leave.target = self
        leave.image = QuireSymbol.image(Quire.Icon.undo, size: .inText)
        menu.addItem(leave)
        let tag = header.demoTag
        let visual = tag.alignmentRect(forFrame: tag.frame)
        let origin = tag.superview?.convert(NSPoint(x: visual.minX, y: visual.maxY + 4), to: header) ?? .zero
        tag.isMenuOpen = true
        menu.popUp(positioning: nil, at: origin, in: header)
        tag.isMenuOpen = false
    }

    @objc private func addRealAccount(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let kind = ProviderKind(rawValue: raw) else { return }
        onAddAccount?(kind)
    }

    @objc private func leaveDemo(_ sender: Any?) {
        onLeaveDemo?()
    }

    @objc private func composeClicked(_ sender: Any?) {
        onCompose?()
    }

    /// The pane's key views in Tab order: the masthead (minimal mode only, when it is the title menu), Demo tag,
    /// search, compose, the list, the server row's link (while a search's list ends with it), the sync line's action
    /// (only while it carries one), the sync line itself and a toast's action (both with Full Keyboard Access only;
    /// the window drops views that cannot take focus).
    var keyViews: [NSView] {
        var views: [NSView] = header.masthead.isMenu ? [header.masthead] : []
        if !header.demoTag.isHidden { views.append(header.demoTag) }
        views.append(header.search.textField)
        views.append(header.compose)
        if let table = Self.firstTable(in: list.view) { views.append(table) }
        // The end of a search's results: its link (§5.10), while the row is on screen.
        if let link = list.serverSearchLink { views.append(link) }
        if !statusBar.actionButton.isHidden { views.append(statusBar.actionButton) }
        views.append(statusBar)
        if let action = toastView.slip?.actionButton { views.append(action) }
        return views
    }

    private static func firstTable(in view: NSView) -> NSTableView? {
        for subview in view.subviews {
            if let table = subview as? NSTableView { return table }
            if let table = firstTable(in: subview) { return table }
        }
        return nil
    }
}

/// The pane's own surface: `paper`, the header on top, the list, the sync line pinned to the bottom and the
/// toast overlay between the header and the sync line. Laid out by hand so the horizon is exact.
@MainActor
private final class ListPaneView: NonDraggingView {
    weak var header: NSView?
    weak var listView: NSView?
    weak var statusBar: NSView?
    weak var toastView: NSView?

    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Increase Contrast and Graphite change token values without an appearance change (QuireEnvironment).
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
        let width = bounds.width
        let headerHeight = Quire.Layout.ListHeader.height
        let lineHeight = Quire.Layout.SyncLine.height
        header?.frame = NSRect(x: 0, y: 0, width: width, height: headerHeight)
        statusBar?.frame = NSRect(x: 0, y: bounds.height - lineHeight, width: width, height: lineHeight)
        let listFrame = NSRect(x: 0, y: headerHeight, width: width, height: max(0, bounds.height - headerHeight - lineHeight))
        listView?.frame = listFrame
        toastView?.frame = listFrame
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.qPaper.setFill()
        // Views do not clip to their bounds by default, so the fill is limited to them by hand.
        dirtyRect.intersection(bounds).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
