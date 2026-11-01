import AppKit
import SSCore

/// The middle column: a header (view picker, Focused/Other, search), the message list, the sync status line
/// and the undo toast.
@MainActor
final class ListPaneViewController: NSViewController, NSSearchFieldDelegate {
    static let minimumWidth: CGFloat = 300
    static let preferredWidth: CGFloat = 380
    static let searchDebounce: TimeInterval = 0.12

    /// The section picker's choices. `nil` section means both.
    static let sections: [(title: String, section: InboxSection?)] = [("All", nil), ("Focused", .focused), ("Other", .other)]
    static let views: [(title: String, view: MailboxView)] = [
        ("Inbox", .inbox), ("Starred", .starred), ("Sent", .sent), ("Drafts", .drafts), ("Trash", .trash), ("All Mail", .all),
    ]

    let list: MessageListViewController
    let toast = ToastView()
    let statusBar = SyncStatusBar()

    var onViewChange: ((MailboxView) -> Void)?
    var onSectionChange: ((InboxSection?) -> Void)?
    var onSearchChange: ((String) -> Void)?
    /// Escape or ↓ in the search field: give the keyboard back to the list.
    var onLeaveSearch: (() -> Void)?

    private let viewPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sectionControl = NSSegmentedControl()
    private let searchField = NSSearchField()
    private var searchTimer: Timer?
    private var headerLeading: NSLayoutConstraint?

    init(list: MessageListViewController) {
        self.list = list
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        viewPopup.isBordered = false
        viewPopup.font = .systemFont(ofSize: 17, weight: .semibold)
        for entry in Self.views {
            viewPopup.addItem(withTitle: entry.title)
        }
        viewPopup.target = self
        viewPopup.action = #selector(viewPicked)
        viewPopup.setAccessibilityLabel("Mailbox")
        viewPopup.translatesAutoresizingMaskIntoConstraints = false

        sectionControl.segmentCount = Self.sections.count
        for (index, entry) in Self.sections.enumerated() {
            sectionControl.setLabel(entry.title, forSegment: index)
        }
        sectionControl.segmentStyle = .rounded
        sectionControl.controlSize = .small
        sectionControl.trackingMode = .selectOne
        sectionControl.selectedSegment = 0
        sectionControl.target = self
        sectionControl.action = #selector(sectionPicked)
        sectionControl.toolTip = "Focused shows people; Other shows newsletters and notifications (⌘\\)"
        sectionControl.translatesAutoresizingMaskIntoConstraints = false

        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addChild(list)
        let listView = list.view
        listView.translatesAutoresizingMaskIntoConstraints = false

        toast.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(viewPopup)
        root.addSubview(sectionControl)
        root.addSubview(searchField)
        root.addSubview(separator)
        root.addSubview(listView)
        root.addSubview(statusBar)
        root.addSubview(toast)

        let leading = viewPopup.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12)
        headerLeading = leading
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth),
            leading,
            viewPopup.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            viewPopup.heightAnchor.constraint(equalToConstant: 28),
            sectionControl.centerYAnchor.constraint(equalTo: viewPopup.centerYAnchor),
            sectionControl.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            sectionControl.leadingAnchor.constraint(greaterThanOrEqualTo: viewPopup.trailingAnchor, constant: 8),
            searchField.topAnchor.constraint(equalTo: viewPopup.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            separator.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            listView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            listView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            listView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            toast.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            toast.bottomAnchor.constraint(equalTo: statusBar.topAnchor, constant: -16),
        ])
        view = root
    }

    // MARK: State from the window controller

    func display(view mailboxView: MailboxView, section: InboxSection?) {
        if let index = Self.views.firstIndex(where: { $0.view == mailboxView }) {
            viewPopup.selectItem(at: index)
        }
        sectionControl.isHidden = mailboxView != .inbox
        sectionControl.selectedSegment = Self.sections.firstIndex { $0.section == section } ?? 0
    }

    /// Leaves room for the traffic lights when the account strip is collapsed and they sit over this pane.
    func setClearsTrafficLights(_ clears: Bool) {
        headerLeading?.constant = clears ? 76 : 12
    }

    var searchText: String { searchField.stringValue }

    var isSearchFocused: Bool {
        guard let editor = searchField.currentEditor() else { return false }
        return view.window?.firstResponder === editor
    }

    func focusSearch() {
        view.window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    func clearSearch() {
        searchTimer?.invalidate()
        guard !searchField.stringValue.isEmpty else { return }
        searchField.stringValue = ""
        onSearchChange?("")
    }

    // MARK: Actions

    @objc private func viewPicked() {
        let index = viewPopup.indexOfSelectedItem
        guard Self.views.indices.contains(index) else { return }
        onViewChange?(Self.views[index].view)
    }

    @objc private func sectionPicked() {
        let index = sectionControl.selectedSegment
        guard Self.sections.indices.contains(index) else { return }
        onSectionChange?(Self.sections[index].section)
    }

    // MARK: NSSearchFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        searchTimer?.invalidate()
        searchTimer = Timer.scheduledTimer(withTimeInterval: Self.searchDebounce, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.onSearchChange?(self.searchField.stringValue)
            }
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty {
                onLeaveSearch?()
            } else {
                clearSearch()
            }
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.insertNewline(_:)):
            searchTimer?.fire()
            onLeaveSearch?()
            return true
        default:
            return false
        }
    }
}
