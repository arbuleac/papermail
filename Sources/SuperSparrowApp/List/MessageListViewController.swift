import AppKit
import os
import SSCore
import SSDesign

/// The message list: one observed `ConversationQuery` rendered as fixed-height rows under running heads.
///
/// Every refresh from the store is turned into row-level edits so the table never rebuilds what it already shows,
/// and the selected conversation survives those edits by id, not by row number. Table rows are conversations,
/// the running heads between them (spec §5.8) and the paging footer (spec §5.10); `ListLayout` maps between
/// the two index spaces, so j/k, next-unread and selection restore only ever see conversations. Keys are not
/// mapped here: the controller exposes `selectNext`/`selectPrevious` and lets the window controller own the
/// shortcut table.
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

    /// Every selected conversation, in list order, when the host has turned on `allowsMultipleSelection`;
    /// otherwise the single selection. `selectedConversationID` stays the lead row.
    var selectedConversationIDs: [ConversationID] {
        guard isViewLoaded else { return selectedID.map { [$0] } ?? [] }
        let ids = tableView.selectedRowIndexes.compactMap { layout.conversationIndex(atRow: $0) }.map { conversations[$0].id }
        return ids.isEmpty ? (selectedID.map { [$0] } ?? []) : ids
    }

    /// Called with the whole selection whenever it changes. Multi-selection (⇧-click, ⌘-click, ⇧J / ⇧K) is
    /// off until the host turns `allowsMultipleSelection` on: it must then act on every selected conversation,
    /// which today's single-selection actions do not.
    var onSelectionSetChange: (([ConversationID]) -> Void)?

    var allowsMultipleSelection = false {
        didSet { if isViewLoaded { tableView.allowsMultipleSelection = allowsMultipleSelection } }
    }

    var accountsByID: [AccountID: Account] = [:] {
        didSet {
            rebuildAccountMarks()
            reconfigureVisibleRows()
        }
    }

    /// Every account's sync state, for the empty list's words (offline, first sync finished) and the first-sync
    /// skeleton. The store does not know whether the network is up, so the host passes the engine's statuses.
    var syncStatuses: [AccountSyncStatus] = [] {
        didSet {
            guard syncStatuses != oldValue else { return }
            for status in syncStatuses where status.phase == .bootstrapping { bootstrappedThisSession.insert(status.accountID) }
            if isViewLoaded { updateEmptyState() }
        }
    }

    /// Past this many row edits a batch of inserts and removes costs more than starting over.
    var reloadThreshold = 500

    /// `settings` defaults to `AppSettings.shared`; tests pass their own.
    init(store: MailStoring, query: ConversationQuery = ConversationQuery(), settings: AppSettings? = nil) {
        let settings = settings ?? AppSettings.shared
        self.store = store
        self.query = query
        self.settings = settings
        rowContentCache = RowContentCache(store: store)
        density = settings.listDensity
        showsAccountInitials = settings.showAccountInitials
        readingFont = settings.readingFont
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    // MARK: Collaborators

    private let store: MailStoring
    private let settings: AppSettings
    // The views and the row cache are internal, not private, so the list's tests can drive and measure them.
    let scrollView = NSScrollView()
    let tableView = MessageListTableView()
    let emptyView = QuireEmptyStateView(sentence: "")
    let skeletonView = ListSkeletonView()
    private let focusOverlay = ListFocusRingOverlay()
    let rowContentCache: RowContentCache
    private let signposter = ListSignposts.signposter
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SuperSparrow", category: "list")

    /// Screens of rows left below the viewport before the next page is requested (spec §5.10: two).
    private static let loadMoreScreens: CGFloat = 2
    /// A conversation counts as opened, and its failed mark as seen, once it has been selected this long.
    private static let acknowledgeDelay: TimeInterval = 0.15

    // MARK: State

    private var selectedID: ConversationID?
    private var indexByID: [ConversationID: Int] = [:]
    private(set) var layout = ListLayout.empty
    private var itemIDs: [ListLayout.ItemID] = []
    private var density: AppSettings.ListDensity
    private var showsAccountInitials: Bool
    private var readingFont: AppSettings.ReadingFont
    private var environmentKey = ""
    private var marks: [AccountID: ConversationCellView.AccountMark] = [:]
    private var accountNames: [AccountID: String] = [:]
    private var ownAddresses: Set<String> = []
    private var bootstrappedThisSession: Set<AccountID> = []
    private var observation: StoreObservation?
    /// Bumped on every re-subscribe so a callback from a cancelled observation cannot overwrite newer rows.
    private var subscriptionGeneration = 0
    private var hasReceivedFirstPage = false
    /// Pages fetched with `query.before` beyond the observed head, refreshed on every head update.
    private var tailPageCount = 0
    private var reachedEnd = false
    private var isLoadingMore = false
    private var footerPhase = ListFooterRowView.Phase.idle
    /// True while the table's selection is being driven from `selectedID`, so the delegate stays quiet.
    private var suppressSelectionCallbacks = false
    private var acknowledgeTimer: Timer?
    private var selectionRestedID: ConversationID?
    /// Conversations whose failed mark is being cleared, so a refresh that lands meanwhile does not write again.
    private var acknowledging: Set<ConversationID> = []
    private var keyObservers: [NSObjectProtocol] = []

    // MARK: View lifecycle

    override func loadView() {
        let container = ListPaneBackgroundView(frame: NSRect(x: 0, y: 0, width: 360, height: 600))
        container.wantsLayer = true
        container.autoresizesSubviews = true
        container.onAppearanceChange = { [weak self] in self?.environmentDidChange() }

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("conversation"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = Quire.Layout.Row.height
        tableView.intercellSpacing = .zero
        tableView.usesAutomaticRowHeights = false
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.selectionHighlightStyle = .regular
        tableView.style = .fullWidth
        tableView.gridStyleMask = []
        tableView.floatsGroupRows = false
        tableView.allowsTypeSelect = false
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = allowsMultipleSelection
        tableView.focusRingType = .none
        tableView.backgroundColor = .qPaper
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.wantsLayer = true
        tableView.setAccessibilityLabel("Conversations")
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(didDoubleClick(_:))
        tableView.onReturn = { [weak self] in self?.openSelection() }
        tableView.isHoverableRow = { [weak self] row in
            guard let self else { return false }
            return self.layout.conversationIndex(atRow: row) != nil
        }
        tableView.onFocusChange = { [weak self] in self?.updateFocusOverlay() }

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .qPaper
        scrollView.wantsLayer = true
        scrollView.frame = container.bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.contentView.postsBoundsChangedNotifications = true
        container.addSubview(scrollView)

        skeletonView.frame = container.bounds
        skeletonView.autoresizingMask = [.width, .height]
        skeletonView.isHidden = true
        skeletonView.density = density
        container.addSubview(skeletonView)

        emptyView.frame = container.bounds
        emptyView.autoresizingMask = [.width, .height]
        emptyView.isHidden = true
        container.addSubview(emptyView)

        focusOverlay.frame = container.bounds
        focusOverlay.autoresizingMask = [.width, .height]
        container.addSubview(focusOverlay)

        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clipViewBoundsDidChange(_:)), name: NSView.boundsDidChangeNotification,
                           object: scrollView.contentView)
        center.addObserver(self, selector: #selector(willStartLiveScroll(_:)), name: NSScrollView.willStartLiveScrollNotification,
                           object: scrollView)
        center.addObserver(self, selector: #selector(didEndLiveScroll(_:)), name: NSScrollView.didEndLiveScrollNotification,
                           object: scrollView)
        center.addObserver(self, selector: #selector(calendarDayChanged(_:)), name: .NSCalendarDayChanged, object: nil)
        center.addObserver(self, selector: #selector(displayPreferencesChanged(_:)), name: AppSettings.displayPreferencesChanged,
                           object: settings)
        center.addObserver(self, selector: #selector(quireEnvironmentChanged(_:)), name: QuireEnvironment.didChangeNotification,
                           object: nil)
        environmentKey = makeEnvironmentKey()
        subscribe()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        observeWindowKeyState()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
        keyObservers = []
    }

    // MARK: Navigation

    func selectNext() {
        moveSelection(by: 1)
    }

    func selectPrevious() {
        moveSelection(by: -1)
    }

    /// ⇧J / ⇧K: grows the selection by one conversation and moves the lead there. Does nothing until the host
    /// turns on `allowsMultipleSelection`.
    func extendSelection(by delta: Int) {
        guard allowsMultipleSelection, !conversations.isEmpty else { return moveSelection(by: delta) }
        let current = selectedID.flatMap { indexByID[$0] } ?? 0
        let target = min(max(current + delta, 0), conversations.count - 1)
        guard let row = layout.row(ofConversation: target) else { return }
        let id = conversations[target].id
        let wasSuppressed = suppressSelectionCallbacks
        suppressSelectionCallbacks = true
        withoutAnimation {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: true)
            scrollToRow(row)
        }
        suppressSelectionCallbacks = wasSuppressed
        onSelectionSetChange?(selectedConversationIDs)
        guard id != selectedID else { return }
        selectedID = id
        selectionDidSettle()
        onSelectionChange?(id)
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
        setFooterPhase(.loading)
        var pageQuery = query
        pageQuery.before = cursor
        let generation = subscriptionGeneration
        let store = self.store
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let page: [ConversationSummary]?
            do {
                page = try store.conversations(pageQuery)
            } catch {
                page = nil
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.finishLoadMore(page, generation: generation) }
            }
        }
    }

    private func moveSelection(by delta: Int) {
        guard !conversations.isEmpty else { return }
        let state = signposter.beginInterval("list.select")
        defer { signposter.endInterval("list.select", state) }
        let target: Int
        if let id = selectedID, let index = indexByID[id] {
            target = min(max(index + delta, 0), conversations.count - 1)
        } else {
            target = 0
        }
        let id = conversations[target].id
        guard id != selectedID || tableView.selectedRowIndexes.count > 1 else { return }
        select(id, notify: true, scroll: true)
        // Walking down with j should never hit the end of the loaded data before the next page is there.
        if delta > 0, let row = layout.row(ofConversation: target), isWithinLoadMoreDistance(ofRow: row) {
            loadMore()
        }
    }

    private func openSelection() {
        guard let id = selectedID else { return }
        onOpen?(id)
    }

    @objc private func didDoubleClick(_ sender: Any?) {
        guard let index = layout.conversationIndex(atRow: tableView.clickedRow) else { return }
        onOpen?(conversations[index].id)
    }

    // MARK: Selection

    private func select(_ id: ConversationID?, notify: Bool, scroll: Bool) {
        selectedID = id
        syncTableSelection(scroll: scroll)
        selectionDidSettle()
        if notify {
            onSelectionChange?(id)
            onSelectionSetChange?(selectedConversationIDs)
        }
    }

    /// Drives the table's selection from `selectedID` without the delegate reporting it as a user change.
    /// Only the fill and the margin rule of the two rows involved redraw, in one frame (spec §5.7).
    private func syncTableSelection(scroll: Bool) {
        let wasSuppressed = suppressSelectionCallbacks
        suppressSelectionCallbacks = true
        defer { suppressSelectionCallbacks = wasSuppressed }
        withoutAnimation {
            if let id = selectedID, let index = indexByID[id], let row = layout.row(ofConversation: index) {
                if tableView.selectedRowIndexes != IndexSet(integer: row) {
                    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
                if scroll { scrollToRow(row) }
            } else if !tableView.selectedRowIndexes.isEmpty {
                tableView.deselectAll(nil)
            }
        }
        updateFocusOverlay()
    }

    /// Keeps a group's running head on screen with its first row, so walking up with k shows the head.
    private func scrollToRow(_ row: Int) {
        if row > 0, case .head? = layout.items.indices.contains(row - 1) ? layout.items[row - 1] : nil {
            tableView.scrollRowToVisible(row - 1)
        }
        tableView.scrollRowToVisible(row)
    }

    private func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: Failed operations

    /// Restarts the 150 ms clock after which the selected conversation counts as opened.
    private func selectionDidSettle() {
        acknowledgeTimer?.invalidate()
        selectionRestedID = nil
        guard selectedID != nil else { return }
        let timer = Timer(timeInterval: MessageListViewController.acknowledgeDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.selectionRestedID = self.selectedID
                self.acknowledgeFailedOperationIfNeeded()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        acknowledgeTimer = timer
    }

    /// Opening a conversation (selecting it for 150 ms) clears its failed mark (spec §5.7, §8.5). The write
    /// goes off the main thread; the observation brings the cleared row back.
    private func acknowledgeFailedOperationIfNeeded() {
        guard let id = selectionRestedID, id == selectedID, let index = indexByID[id],
              conversations[index].failedOperation != nil, acknowledging.insert(id).inserted else { return }
        let store = self.store
        let log = self.log
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try store.acknowledgeFailedOperation(conversationID: id)
            } catch {
                log.debug("acknowledge failed: \(String(describing: error), privacy: .public)")
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = self?.acknowledging.remove(id) }
            }
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
        footerPhase = .idle
        observation = store.observeConversations(query) { [weak self] rows in
            // The store contract delivers on the main thread; assumeIsolated turns that promise into a check.
            MainActor.assumeIsolated {
                guard let self, self.subscriptionGeneration == generation else { return }
                self.handleHeadUpdate(rows)
            }
        }
    }

    /// Internal so the refresh budget can be timed on its own.
    func handleHeadUpdate(_ rows: [ConversationSummary]) {
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

    private func finishLoadMore(_ page: [ConversationSummary]?, generation: Int) {
        guard generation == subscriptionGeneration else { return }
        isLoadingMore = false
        guard let page else {
            setFooterPhase(.failed)
            return
        }
        setFooterPhase(.idle)
        if page.count < query.limit { reachedEnd = true }
        tailPageCount += 1
        var seen = Set(conversations.map(\.id))
        let additions = page.filter { seen.insert($0.id).inserted }
        apply(conversations + additions)
    }

    // MARK: Applying rows

    private func makeLayout() -> ListLayout {
        let isSearch = !(query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        return ListLayout.make(
            dates: conversations.map(\.latestDate),
            showsHeads: RunningHead.showsHeads(conversationCount: conversations.count, isSearch: isSearch),
            showsFooter: hasReceivedFirstPage && !reachedEnd && !conversations.isEmpty,
            reference: rowContentCache.reference,
            formatter: rowContentCache.formatter
        )
    }

    private func apply(_ incoming: [ConversationSummary]) {
        rowContentCache.refreshReference()
        let old = conversations
        let oldItemIDs = itemIDs
        let oldIndexByID = indexByID
        let previousSelection = selectedID

        let diffState = signposter.beginInterval("list.diff")
        conversations = incoming
        rebuildIndex()
        layout = makeLayout()
        itemIDs = layout.itemIDs(conversationIDs: conversations.map(\.id))
        suppressSelectionCallbacks = true
        withoutAnimation {
            var rowsMoved = true
            if oldItemIDs.isEmpty || itemIDs.isEmpty {
                tableView.reloadData()
            } else {
                let diff = ListDiff.compute(old: oldItemIDs, new: itemIDs)
                rowsMoved = !diff.isEmpty
                if diff.changeCount > reloadThreshold {
                    tableView.reloadData()
                } else if !diff.isEmpty {
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
            }
            // Edits and reloads can put another conversation under the hovered index.
            if rowsMoved { tableView.refreshHoverAfterRowEdits() }
            // Changed summaries, and rows whose time format moved with the heads, pick up new content; unchanged
            // rows hit the cache and keep the content they draw.
            reconfigureVisibleRows()
        }
        signposter.endInterval("list.diff", diffState)

        let selectionMoved = reconcileSelection(previous: previousSelection, oldIndexByID: oldIndexByID, old: old)
        suppressSelectionCallbacks = false
        updateEmptyState()
        if selectionMoved {
            selectionDidSettle()
            onSelectionChange?(selectedID)
            onSelectionSetChange?(selectedConversationIDs)
        } else if selectionRestedID != nil {
            acknowledgeFailedOperationIfNeeded()
        }
    }

    private func rebuildIndex() {
        var index: [ConversationID: Int] = [:]
        index.reserveCapacity(conversations.count)
        for (row, summary) in conversations.enumerated() { index[summary.id] = row }
        indexByID = index
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

    // MARK: Row content

    private var rowKind: ConversationRowText.Kind {
        switch query.view {
        case .sent: return .sent
        case .drafts: return .draft
        case .inbox, .starred, .trash, .all: return .received
        }
    }

    /// Rows mark their account only where more than one account can show: the unified view of a Mac with one
    /// account is a single-account view, and a ring in the same ink on every face would say nothing (spec §5.7).
    private var isUnified: Bool {
        (query.accountIDs?.count ?? accountsByID.count) > 1
    }

    private var showsOtherTag: Bool {
        query.view == .inbox && query.section == nil && (query.searchText?.isEmpty ?? true)
    }

    private func context(forConversation index: Int) -> ConversationRowText.Context {
        let summary = conversations[index]
        return ConversationRowText.Context(
            kind: rowKind,
            timeStyle: layout.timeStyles.indices.contains(index) ? layout.timeStyles[index] : .relative,
            showsOtherTag: showsOtherTag,
            ownAddresses: ownAddresses,
            accountName: accountNames[summary.id.accountID]
        )
    }

    private func mark(for summary: ConversationSummary) -> ConversationCellView.AccountMark {
        guard isUnified else { return .none }
        var mark = marks[summary.id.accountID] ?? ConversationCellView.AccountMark(inkSlot: 0, initial: "?", isUnified: true,
                                                                                  showsInitial: false)
        mark.showsInitial = showsAccountInitials
        return mark
    }

    private func rebuildAccountMarks() {
        var marks: [AccountID: ConversationCellView.AccountMark] = [:]
        var names: [AccountID: String] = [:]
        var own: Set<String> = []
        for (id, account) in accountsByID {
            marks[id] = ConversationCellView.AccountMark(
                inkSlot: account.inkSlot,
                initial: ListAccountMark.initial(email: account.email, monogram: account.monogram),
                isUnified: true,
                showsInitial: false,
                accountAddress: account.email
            )
            names[id] = ListAccountMark.name(email: account.email)
            own.insert(account.email.lowercased())
        }
        self.marks = marks
        accountNames = names
        ownAddresses = own
    }

    private func configure(_ cell: ConversationCellView, forConversation index: Int) {
        let summary = conversations[index]
        let content = rowContentCache.content(for: summary, context: context(forConversation: index), environment: environmentKey)
        cell.configure(with: content, mark: mark(for: summary), density: density)
    }

    private func reconfigureVisibleRows() {
        guard isViewLoaded else { return }
        tableView.enumerateAvailableRowViews { [weak self] rowView, row in
            guard let self else { return }
            switch rowView {
            case let conversationRow as ConversationRowView:
                conversationRow.density = self.density
                if let index = self.layout.conversationIndex(atRow: row),
                   let cell = conversationRow.view(atColumn: 0) as? ConversationCellView {
                    self.configure(cell, forConversation: index)
                }
            case let headRow as RunningHeadRowView:
                self.configure(headRow, row: row)
            case let footerRow as ListFooterRowView:
                footerRow.phase = self.footerPhase
            default:
                break
            }
        }
    }

    private func configure(_ headRow: RunningHeadRowView, row: Int) {
        guard layout.items.indices.contains(row), case .head(let head) = layout.items[row] else { return }
        let title = rowContentCache.formatter.title(for: head, reference: rowContentCache.reference)
        headRow.spokenTitle = title
        headRow.title = RunningHeadRowView.title(title)
        headRow.density = density
    }

    private func makeEnvironmentKey() -> String {
        QuireEnvironment.cacheKey(for: view.effectiveAppearance) + "|" + readingFont.rawValue
    }

    // MARK: Empty state, skeleton and footer

    private func updateEmptyState() {
        let isEmpty = hasReceivedFirstPage && conversations.isEmpty
        let scope = Set(query.accountIDs ?? Array(accountsByID.keys))
        let scoped = syncStatuses.filter { scope.contains($0.accountID) }
        let firstSyncRunning = scoped.contains { $0.phase == .bootstrapping && $0.lastSuccessfulSyncAt == nil }
        let isSearch = !(query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if isEmpty, firstSyncRunning, !isSearch {
            emptyView.isHidden = true
            skeletonView.density = density
            skeletonView.reveal()
            return
        }
        skeletonView.conceal()
        guard isEmpty else {
            emptyView.isHidden = true
            return
        }
        let state = ListEmptyState.make(
            query: query,
            isOfflineWithNothingCached: isOfflineWithNothingCached(scoped),
            firstSyncFinishedAccount: firstSyncFinishedAccount(scoped)
        )
        emptyView.sentence = state.sentence
        emptyView.hint = state.hint.isEmpty ? [] : [.text(state.hint)]
        switch state.glyph {
        case .sparrow?: emptyView.glyph = .sparrow
        case .offline?: emptyView.glyph = .offline
        case nil: emptyView.glyph = nil
        }
        emptyView.isHidden = false
    }

    /// No network, and nothing in this view has ever synced: the same reading of the engine's statuses the sync
    /// line uses (network failures are reported with a "network" message).
    private func isOfflineWithNothingCached(_ scoped: [AccountSyncStatus]) -> Bool {
        let errors = scoped.filter { $0.phase == .error }
        guard !errors.isEmpty, errors.allSatisfy({ ($0.message ?? "").hasPrefix("network") }) else { return false }
        return scoped.allSatisfy { $0.lastSuccessfulSyncAt == nil }
    }

    /// The one account in view whose first sync this session has watched finish.
    private func firstSyncFinishedAccount(_ scoped: [AccountSyncStatus]) -> String? {
        let finished = scoped.filter { bootstrappedThisSession.contains($0.accountID) && $0.phase != .bootstrapping }
        guard finished.count == 1, scoped.count == 1, let account = accountsByID[finished[0].accountID] else { return nil }
        return ListAccountMark.name(email: account.email)
    }

    private func setFooterPhase(_ phase: ListFooterRowView.Phase) {
        footerPhase = phase
        guard isViewLoaded, let row = layout.footerRow,
              let footer = tableView.rowView(atRow: row, makeIfNecessary: false) as? ListFooterRowView else { return }
        footer.phase = phase
    }

    private func updateFocusOverlay() {
        focusOverlay.isShowing = NSApp.isFullKeyboardAccessEnabled && tableView.selectedRowIndexes.isEmpty
            && view.window?.firstResponder === tableView && view.window?.isKeyWindow == true && !conversations.isEmpty
    }

    // MARK: Notifications

    private func isWithinLoadMoreDistance(ofRow row: Int) -> Bool {
        let visible = scrollView.contentView.bounds
        let rowBottom = tableView.rect(ofRow: row).maxY
        return tableView.bounds.height - max(rowBottom, visible.maxY) < visible.height * MessageListViewController.loadMoreScreens
    }

    @objc private func clipViewBoundsDidChange(_ notification: Notification) {
        tableView.boundsDidScroll()
        guard hasReceivedFirstPage, !reachedEnd, !isLoadingMore, footerPhase != .failed, !conversations.isEmpty else { return }
        let visible = scrollView.contentView.bounds
        let remaining = tableView.bounds.height - visible.maxY
        if remaining < visible.height * MessageListViewController.loadMoreScreens {
            loadMore()
        }
    }

    @objc private func willStartLiveScroll(_ notification: Notification) {
        tableView.beginScrollHoverSuspension()
    }

    @objc private func didEndLiveScroll(_ notification: Notification) {
        tableView.endScrollHoverSuspension()
    }

    /// Foundation does not promise a thread for this notification, so the work hops to the main actor itself.
    @objc nonisolated private func calendarDayChanged(_ notification: Notification) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.handleDayChange() }
        }
    }

    /// "14:05" becomes "Tue" at midnight and rows move from Today to Yesterday; the heads are rebuilt and the
    /// cache keys include the day, so the rows rebuild with them.
    private func handleDayChange() {
        rowContentCache.refreshReference()
        rowContentCache.removeAll()
        apply(conversations)
    }

    /// Density and account initials switch the row layout live; the reading font is part of the cache key.
    @objc private func displayPreferencesChanged(_ notification: Notification) {
        let densityChanged = settings.listDensity != density
        density = settings.listDensity
        showsAccountInitials = settings.showAccountInitials
        if settings.readingFont != readingFont {
            readingFont = settings.readingFont
            environmentKey = makeEnvironmentKey()
        }
        guard isViewLoaded else { return }
        if densityChanged {
            // Row heights change, so every row is re-measured; the selection and the scroll position follow.
            withoutAnimation {
                tableView.reloadData()
            }
            tableView.refreshHoverAfterRowEdits()
            syncTableSelection(scroll: true)
            skeletonView.density = density
        } else {
            reconfigureVisibleRows()
        }
    }

    @objc private func quireEnvironmentChanged(_ notification: Notification) {
        environmentDidChange()
    }

    /// Appearance, Increase Contrast or Graphite changed: rows rebuild under the new environment key and every
    /// visible row view redraws its fill.
    private func environmentDidChange() {
        guard isViewLoaded else { return }
        let key = makeEnvironmentKey()
        guard key != environmentKey else { return }
        environmentKey = key
        reconfigureVisibleRows()
        tableView.enumerateAvailableRowViews { rowView, _ in
            rowView.needsDisplay = true
            // The footer's Retry link draws its own label.
            for subview in rowView.subviews { subview.needsDisplay = true }
        }
        // Increase Contrast and Graphite are not appearance changes, so AppKit does not redraw these on its own:
        // the paper below a short list, the skeleton bars and the focus ring would keep the old values.
        view.needsDisplay = true
        tableView.needsDisplay = true
        scrollView.contentView.needsDisplay = true
        skeletonView.needsDisplay = true
        focusOverlay.needsDisplay = true
    }

    /// The selection's wash and rule follow the window's key state, not the first responder (spec §3.4).
    private func observeWindowKeyState() {
        for observer in keyObservers { NotificationCenter.default.removeObserver(observer) }
        keyObservers = []
        guard let window = view.window else { return }
        let refresh: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.windowKeyStateChanged() }
        }
        keyObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window,
                                                                   queue: .main, using: refresh))
        keyObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                                                                   queue: .main, using: refresh))
    }

    private func windowKeyStateChanged() {
        withoutAnimation {
            for row in tableView.selectedRowIndexes {
                tableView.rowView(atRow: row, makeIfNecessary: false)?.needsDisplay = true
            }
        }
        updateFocusOverlay()
    }
}

// MARK: - NSTableViewDataSource

extension MessageListViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        layout.rowCount
    }
}

// MARK: - NSTableViewDelegate

extension MessageListViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard layout.items.indices.contains(row) else { return Quire.Layout.Row.height }
        let compact = density == .compact
        switch layout.items[row] {
        case .conversation: return compact ? Quire.Layout.RowCompact.height : Quire.Layout.Row.height
        case .head: return compact ? Quire.Layout.RunningHead.compactHeight : Quire.Layout.RunningHead.height
        case .footer: return Quire.Layout.ListFooter.height
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard layout.items.indices.contains(row) else { return nil }
        switch layout.items[row] {
        case .conversation:
            let rowView = (tableView.makeView(withIdentifier: ConversationRowView.identifier, owner: nil) as? ConversationRowView)
                ?? ConversationRowView(frame: .zero)
            rowView.density = density
            return rowView
        case .head:
            let rowView = (tableView.makeView(withIdentifier: RunningHeadRowView.identifier, owner: nil) as? RunningHeadRowView)
                ?? RunningHeadRowView(frame: .zero)
            configure(rowView, row: row)
            return rowView
        case .footer:
            let rowView = (tableView.makeView(withIdentifier: ListFooterRowView.identifier, owner: nil) as? ListFooterRowView)
                ?? ListFooterRowView(frame: .zero)
            rowView.phase = footerPhase
            rowView.onRetry = { [weak self] in self?.loadMore() }
            return rowView
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let index = layout.conversationIndex(atRow: row) else { return nil }
        let cell = (tableView.makeView(withIdentifier: ConversationCellView.identifier, owner: nil) as? ConversationCellView)
            ?? ConversationCellView(frame: NSRect(x: 0, y: 0, width: tableView.bounds.width, height: tableView.rowHeight))
        configure(cell, forConversation: index)
        return cell
    }

    /// Heads and the footer are never selectable or focusable (spec §5.8, §5.10).
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        layout.conversationIndex(atRow: row) != nil
    }

    /// AppKit asks this instead of `shouldSelectRow` for clicks. A click on a head or the footer proposes only
    /// that row; filtering it out would leave an empty set and clear the selection, so such a click keeps the
    /// selection as it is. A click on empty space below the rows still proposes nothing and still deselects.
    func tableView(_ tableView: NSTableView, selectionIndexesForProposedSelection proposedSelectionIndexes: IndexSet) -> IndexSet {
        let selectable = IndexSet(proposedSelectionIndexes.filter { layout.conversationIndex(atRow: $0) != nil })
        if selectable.isEmpty, !proposedSelectionIndexes.isEmpty { return tableView.selectedRowIndexes }
        return selectable
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateFocusOverlay()
        guard !suppressSelectionCallbacks else { return }
        let rows = tableView.selectedRowIndexes
        let selected = rows.compactMap { layout.conversationIndex(atRow: $0) }.map { conversations[$0].id }
        let lead: ConversationID?
        if selected.count <= 1 {
            lead = selected.first
        } else if let clicked = layout.conversationIndex(atRow: tableView.clickedRow), rows.contains(tableView.clickedRow) {
            // ⌘-click and ⇧-click move the lead to the row clicked, as the reader follows the newest pick.
            lead = conversations[clicked].id
        } else {
            lead = selectedID.flatMap { selected.contains($0) ? $0 : nil } ?? selected.last
        }
        onSelectionSetChange?(selected)
        guard lead != selectedID else { return }
        selectedID = lead
        selectionDidSettle()
        onSelectionChange?(lead)
    }
}
