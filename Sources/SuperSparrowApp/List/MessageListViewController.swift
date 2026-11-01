import AppKit
import os
import SSCore

/// The message list: one observed `ConversationQuery` rendered as fixed-height rows.
///
/// Every refresh from the store is turned into row-level edits so the table never rebuilds what it already shows,
/// and the selected conversation survives those edits by id, not by row number. Keys are not mapped here: the
/// controller exposes `selectNext`/`selectPrevious` and lets the window controller own the shortcut table.
@MainActor
final class MessageListViewController: NSViewController {
    // MARK: Public surface

    var query: ConversationQuery {
        didSet {
            guard query != oldValue, isViewLoaded else { return }
            subscribe()
        }
    }

    private(set) var conversations: [ConversationSummary] = []

    /// Setting it moves the highlight and scrolls the row into view without reporting a selection change,
    /// because the caller already knows. User moves, j/k and archive fall-through do report.
    var selectedConversationID: ConversationID? {
        get { selectedID }
        set { select(newValue, notify: false, scroll: true) }
    }

    var onSelectionChange: ((ConversationID?) -> Void)?
    var onOpen: ((ConversationID) -> Void)?

    var accountsByID: [AccountID: Account] = [:] {
        didSet {
            accountColors = accountsByID.compactMapValues { NSColor(hexString: $0.colorHex) }
            reconfigureVisibleRows()
        }
    }

    /// Past this many row edits a batch of inserts and removes costs more than starting over.
    var reloadThreshold = 500

    init(store: MailStoring, query: ConversationQuery = ConversationQuery()) {
        self.store = store
        self.query = query
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    // MARK: Collaborators

    private let store: MailStoring
    private let scrollView = NSScrollView()
    private let tableView = MessageListTableView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let footerView = NSView()
    private let footerLabel = NSTextField(labelWithString: "Loading…")
    private let rowContentCache = RowContentCache()
    private let avatarCache = AvatarCache(diameter: ConversationCellView.Metrics.avatarDiameter)
    private let signposter = ListSignposts.signposter
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SuperSparrow", category: "list")

    private static let footerHeight: CGFloat = 20
    /// Rows left below the viewport before the next page is requested.
    private static let loadMoreLookahead = 10

    // MARK: State

    private var selectedID: ConversationID?
    private var indexByID: [ConversationID: Int] = [:]
    private var accountColors: [AccountID: NSColor] = [:]
    private var observation: StoreObservation?
    /// Bumped on every re-subscribe so a callback from a cancelled observation cannot overwrite newer rows.
    private var subscriptionGeneration = 0
    private var hasReceivedFirstPage = false
    /// Pages fetched with `query.before` beyond the observed head, refreshed on every head update.
    private var tailPageCount = 0
    private var reachedEnd = false
    private var isLoadingMore = false
    /// True while the table's selection is being driven from `selectedID`, so the delegate stays quiet.
    private var suppressSelectionCallbacks = false

    // MARK: View lifecycle

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        container.wantsLayer = true
        container.autoresizesSubviews = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = ConversationCellView.Metrics.rowHeight
        tableView.intercellSpacing = .zero
        tableView.usesAutomaticRowHeights = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.style = .fullWidth
        tableView.gridStyleMask = []
        tableView.allowsTypeSelect = false
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.focusRingType = .none
        tableView.backgroundColor = .controlBackgroundColor
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.wantsLayer = true
        tableView.setAccessibilityLabel("Conversations")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(didDoubleClick(_:))
        tableView.onReturn = { [weak self] in self?.openSelection() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.wantsLayer = true
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.contentView.postsBoundsChangedNotifications = true
        container.addSubview(scrollView)

        emptyLabel.font = NSFont.systemFont(ofSize: 15, weight: .medium)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        container.addSubview(emptyLabel)

        footerView.wantsLayer = true
        footerView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        footerView.frame = NSRect(x: 0, y: 0, width: container.bounds.width, height: MessageListViewController.footerHeight)
        footerView.autoresizingMask = [.width, .maxYMargin]
        footerView.isHidden = true
        footerLabel.font = NSFont.systemFont(ofSize: 11)
        footerLabel.textColor = .secondaryLabelColor
        footerLabel.alignment = .center
        footerLabel.frame = footerView.bounds
        footerLabel.autoresizingMask = [.width, .height]
        footerView.addSubview(footerLabel)
        container.addSubview(footerView)

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipViewBoundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(calendarDayChanged(_:)),
            name: .NSCalendarDayChanged,
            object: nil
        )
        subscribe()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        emptyLabel.sizeToFit()
        let size = emptyLabel.frame.size
        emptyLabel.frame = NSRect(
            x: ((view.bounds.width - size.width) / 2).rounded(),
            y: ((view.bounds.height - size.height) / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    // MARK: Navigation

    func selectNext() {
        moveSelection(by: 1)
    }

    func selectPrevious() {
        moveSelection(by: -1)
    }

    /// The rows the conversation view should pre-render around `id`.
    func neighbors(of id: ConversationID) -> (previous: ConversationID?, next: ConversationID?, nextUnread: ConversationID?) {
        guard let row = indexByID[id] else { return (nil, nil, nil) }
        let previous = row > 0 ? conversations[row - 1].id : nil
        let next = row + 1 < conversations.count ? conversations[row + 1].id : nil
        let nextUnread = conversations[(row + 1)...].first { $0.unreadCount > 0 }?.id
        return (previous, next, nextUnread)
    }

    /// Fetches the page after the last row with `query.before` off the main thread and appends it. The head
    /// observation keeps delivering, so a later refresh re-reads the tail pages to keep every row live.
    func loadMore() {
        guard !isLoadingMore, !reachedEnd, hasReceivedFirstPage, let cursor = conversations.last?.latestDate else { return }
        isLoadingMore = true
        setFooterVisible(true)
        var pageQuery = query
        pageQuery.before = cursor
        let generation = subscriptionGeneration
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let page: [ConversationSummary]
            do {
                page = try store.conversations(pageQuery)
            } catch {
                page = []
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishLoadMore(page, generation: generation) }
            }
        }
    }

    private func moveSelection(by delta: Int) {
        guard !conversations.isEmpty else { return }
        let target: Int
        if let id = selectedID, let row = indexByID[id] {
            target = min(max(row + delta, 0), conversations.count - 1)
        } else {
            target = 0
        }
        let id = conversations[target].id
        guard id != selectedID else { return }
        select(id, notify: true, scroll: true)
        // Walking down with j should never hit the end of the loaded data before the next page is there.
        if delta > 0, target >= conversations.count - MessageListViewController.loadMoreLookahead {
            loadMore()
        }
    }

    private func openSelection() {
        guard let id = selectedID else { return }
        onOpen?(id)
    }

    @objc private func didDoubleClick(_ sender: Any?) {
        let row = tableView.clickedRow
        guard row >= 0, row < conversations.count else { return }
        onOpen?(conversations[row].id)
    }

    // MARK: Selection

    private func select(_ id: ConversationID?, notify: Bool, scroll: Bool) {
        selectedID = id
        syncTableSelection(scroll: scroll)
        if notify { onSelectionChange?(id) }
    }

    /// Drives the table's selection from `selectedID` without the delegate reporting it as a user change.
    private func syncTableSelection(scroll: Bool) {
        let wasSuppressed = suppressSelectionCallbacks
        suppressSelectionCallbacks = true
        defer { suppressSelectionCallbacks = wasSuppressed }
        if let id = selectedID, let row = indexByID[id] {
            if tableView.selectedRow != row {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            if scroll { tableView.scrollRowToVisible(row) }
        } else if tableView.selectedRow >= 0 {
            tableView.deselectAll(nil)
        }
    }

    // MARK: Store observation

    private func subscribe() {
        observation?.cancel()
        subscriptionGeneration += 1
        let generation = subscriptionGeneration
        hasReceivedFirstPage = false
        tailPageCount = 0
        reachedEnd = false
        isLoadingMore = false
        setFooterVisible(false)
        observation = store.observeConversations(query) { [weak self] rows in
            // The store contract delivers on the main thread; assumeIsolated turns that promise into a check.
            MainActor.assumeIsolated {
                guard let self, self.subscriptionGeneration == generation else { return }
                self.handleHeadUpdate(rows)
            }
        }
    }

    private func handleHeadUpdate(_ rows: [ConversationSummary]) {
        let state = signposter.beginInterval("list.refresh")
        defer { signposter.endInterval("list.refresh", state) }
        hasReceivedFirstPage = true
        reachedEnd = rows.count < query.limit
        var merged = rows
        if reachedEnd {
            tailPageCount = 0
        } else if tailPageCount > 0 {
            merged += fetchTails(after: rows, pages: tailPageCount)
        }
        apply(merged)
    }

    /// Re-reads the tail pages from the current head so that rows below the first page stay as live as the
    /// head. Each page is one indexed read; the count is bounded by how far the user scrolled.
    private func fetchTails(after head: [ConversationSummary], pages: Int) -> [ConversationSummary] {
        var tail: [ConversationSummary] = []
        var seen = Set(head.map(\.id))
        var cursor = head.last?.latestDate
        for _ in 0..<pages {
            guard let before = cursor else { break }
            var pageQuery = query
            pageQuery.before = before
            let page: [ConversationSummary]
            do {
                page = try store.conversations(pageQuery)
            } catch {
                log.debug("tail page read failed: \(String(describing: error), privacy: .public)")
                break
            }
            for summary in page where seen.insert(summary.id).inserted {
                tail.append(summary)
            }
            if page.count < query.limit {
                reachedEnd = true
                break
            }
            cursor = page.last?.latestDate
        }
        return tail
    }

    private func finishLoadMore(_ page: [ConversationSummary], generation: Int) {
        guard generation == subscriptionGeneration else { return }
        isLoadingMore = false
        setFooterVisible(false)
        if page.count < query.limit { reachedEnd = true }
        guard !page.isEmpty else { return }
        tailPageCount += 1
        var seen = Set(conversations.map(\.id))
        let additions = page.filter { seen.insert($0.id).inserted }
        guard !additions.isEmpty else { return }
        apply(conversations + additions)
    }

    // MARK: Applying rows

    private func apply(_ incoming: [ConversationSummary]) {
        rowContentCache.refreshReference()
        let old = conversations
        let oldIndexByID = indexByID
        let previousSelection = selectedID

        let diffState = signposter.beginInterval("list.diff")
        conversations = incoming
        rebuildIndex()
        suppressSelectionCallbacks = true
        if old.isEmpty || incoming.isEmpty {
            tableView.reloadData()
        } else {
            let diff = ListDiff.compute(old: old.map(\.id), new: incoming.map(\.id))
            if diff.changeCount > reloadThreshold {
                tableView.reloadData()
            } else {
                if !diff.isEmpty {
                    tableView.beginUpdates()
                    if !diff.removals.isEmpty {
                        tableView.removeRows(at: IndexSet(diff.removals))
                    }
                    for move in diff.moves {
                        tableView.moveRow(at: move.from, to: move.to)
                    }
                    if !diff.insertions.isEmpty {
                        tableView.insertRows(at: IndexSet(diff.insertions))
                    }
                    tableView.endUpdates()
                }
                reloadChangedRows(old: old)
            }
        }
        signposter.endInterval("list.diff", diffState)

        let selectionMoved = reconcileSelection(previous: previousSelection, oldIndexByID: oldIndexByID, old: old)
        suppressSelectionCallbacks = false
        updateEmptyState()
        if selectionMoved { onSelectionChange?(selectedID) }
    }

    private func rebuildIndex() {
        var index: [ConversationID: Int] = [:]
        index.reserveCapacity(conversations.count)
        for (row, summary) in conversations.enumerated() { index[summary.id] = row }
        indexByID = index
    }

    /// Rows whose id survived but whose summary changed (read, starred, new reply) get reconfigured in place.
    private func reloadChangedRows(old: [ConversationSummary]) {
        var oldByID: [ConversationID: ConversationSummary] = [:]
        oldByID.reserveCapacity(old.count)
        for summary in old { oldByID[summary.id] = summary }
        var changed = IndexSet()
        for (row, summary) in conversations.enumerated() {
            if let previous = oldByID[summary.id], previous != summary { changed.insert(row) }
        }
        if !changed.isEmpty {
            tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        }
    }

    /// Returns true when the selection had to move to another conversation.
    private func reconcileSelection(
        previous: ConversationID?,
        oldIndexByID: [ConversationID: Int],
        old: [ConversationSummary]
    ) -> Bool {
        guard let previous, indexByID[previous] == nil, oldIndexByID[previous] != nil else {
            // Still listed, never listed yet (a selection made ahead of the data), or nothing selected.
            syncTableSelection(scroll: false)
            return false
        }
        // The selected conversation left this view (archived, trashed, read in an unread-only view). Hand the
        // selection to the row that took its place so the next j or k keeps moving through the list.
        selectedID = ListDiff.successor(ofRemoved: previous, in: old.map(\.id), new: conversations.map(\.id))
        syncTableSelection(scroll: true)
        return true
    }

    private func reconfigureVisibleRows() {
        guard isViewLoaded else { return }
        tableView.enumerateAvailableRowViews { [weak self] rowView, row in
            guard let self, row < self.conversations.count,
                  let cell = rowView.view(atColumn: 0) as? ConversationCellView else { return }
            self.configure(cell, with: self.conversations[row])
        }
    }

    private func configure(_ cell: ConversationCellView, with summary: ConversationSummary) {
        cell.configure(
            with: rowContentCache.content(for: summary),
            accountColor: accountColors[summary.id.accountID],
            avatarCache: avatarCache
        )
    }

    // MARK: Empty state and footer

    private func updateEmptyState() {
        let isEmpty = hasReceivedFirstPage && conversations.isEmpty
        if isEmpty { emptyLabel.stringValue = emptyStateText }
        emptyLabel.isHidden = !isEmpty
        view.needsLayout = true
    }

    private var emptyStateText: String {
        if let text = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            return "No results"
        }
        return query.view == .inbox ? "Inbox zero" : "Nothing here"
    }

    private func setFooterVisible(_ visible: Bool) {
        footerView.isHidden = !visible
    }

    // MARK: Notifications

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        guard hasReceivedFirstPage, !reachedEnd, !isLoadingMore, !conversations.isEmpty else { return }
        let visible = scrollView.contentView.bounds
        let remaining = tableView.bounds.height - visible.maxY
        if remaining < ConversationCellView.Metrics.rowHeight * CGFloat(MessageListViewController.loadMoreLookahead) {
            loadMore()
        }
    }

    /// Foundation does not promise a thread for this notification, so the work hops to the main actor itself.
    @objc nonisolated private func calendarDayChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.handleDayChange() }
        }
    }

    /// "14:05" becomes "Tue" at midnight; the cache keys include the day, so dropping the cache is enough.
    private func handleDayChange() {
        rowContentCache.refreshReference()
        rowContentCache.removeAll()
        reconfigureVisibleRows()
    }
}

// MARK: - NSTableViewDataSource

extension MessageListViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        conversations.count
    }
}

// MARK: - NSTableViewDelegate

extension MessageListViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        if let reused = tableView.makeView(withIdentifier: ConversationRowView.identifier, owner: nil) as? ConversationRowView {
            return reused
        }
        return ConversationRowView(frame: .zero)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < conversations.count else { return nil }
        let cell = (tableView.makeView(withIdentifier: ConversationCellView.identifier, owner: nil) as? ConversationCellView)
            ?? ConversationCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: tableView.rowHeight))
        configure(cell, with: conversations[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionCallbacks else { return }
        let row = tableView.selectedRow
        let id = row >= 0 && row < conversations.count ? conversations[row].id : nil
        guard id != selectedID else { return }
        selectedID = id
        onSelectionChange?(id)
    }
}
