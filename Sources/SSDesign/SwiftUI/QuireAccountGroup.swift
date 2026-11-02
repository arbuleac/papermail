import SwiftUI

/// The Settings account group with its +/− buttons (spec §5.40, §8.3).
///
/// - A `sheet` group, radius 8, with a hairline edge, holding 56 pt `QuireAccountRow`s separated by hairlines
///   from x = 62 (hidden around the selected row). Not a `List(selection:)`, whose selection paints an accent
///   block with white text that cannot be restyled.
/// - At most 6 rows show (6 × 56 = 336 pt, `settings.groupMaxRows`); past that the rows scroll inside the
///   group, a `rule` hairline marks each clipped edge (bottom, and top once scrolled), and ↑/↓ bring the
///   selected row into view at once.
/// - One focusable stack: click selects (on mouse-down, as native source lists do), ↑/↓ move the selection,
///   ⌫ asks to remove, and Tab enters and leaves it as one stop, drawing the focus ring around the selected
///   row inset 2 pt. Each row reports `isSelected` to accessibility.
/// - Empty: one 56 pt row, “No accounts yet” over “Add one to start syncing.”, centred; − disabled.
/// - Busy: a pending account adds the pending row at the end and disables +; `isAddEnabled: false` disables it
///   too (a reconnect is running).
/// - +/− sit 8 pt below the group (`settings.plusMinusTop`); + opens `addMenu` (the add-account menu, §5.44);
///   − (and ⌫) call `onRemove`, enabled while a row is selected.
public struct QuireAccountGroup<AddMenu: View>: View {
    let accounts: [QuireAccountRowContent]
    @Binding var selection: String?
    let pending: QuireAccountPending?
    let isAddEnabled: Bool
    let onRemove: () -> Void
    let onRowAction: (QuireAccountRowContent) -> Void
    let isRowActionEnabled: (QuireAccountRowContent) -> Bool
    let emptyTitle: String
    let emptyHint: String
    let addMenu: () -> AddMenu
    let focus: FocusState<Bool>.Binding?

    @FocusState private var ownFocus: Bool
    @Environment(\.quireForcedStates) private var forced
    @Environment(\.controlActiveState) private var activeState
    @State private var edges = QuireScrollEdges(top: false, bottom: true)

    /// - Parameters:
    ///   - selection: the selected account's id.
    ///   - pending: an account still signing in (the pending row); + is disabled while it shows.
    ///   - isAddEnabled: false disables + (while a reconnect runs).
    ///   - onRowAction: the status action of a row (Reconnect, Cancel, Retry).
    ///   - isRowActionEnabled: false disables a row's action (every other Reconnect and Retry during a reconnect).
    ///   - focus: an external focus binding for the group, for a tab that moves focus itself.
    public init(accounts: [QuireAccountRowContent], selection: Binding<String?>, pending: QuireAccountPending? = nil,
                isAddEnabled: Bool = true, emptyTitle: String = "No accounts yet", emptyHint: String = "Add one to start syncing.",
                focus: FocusState<Bool>.Binding? = nil,
                onRemove: @escaping () -> Void, onRowAction: @escaping (QuireAccountRowContent) -> Void = { _ in },
                isRowActionEnabled: @escaping (QuireAccountRowContent) -> Bool = { _ in true },
                @ViewBuilder addMenu: @escaping () -> AddMenu) {
        self.focus = focus
        self.accounts = accounts
        _selection = selection
        self.pending = pending
        self.isAddEnabled = isAddEnabled
        self.emptyTitle = emptyTitle
        self.emptyHint = emptyHint
        self.onRemove = onRemove
        self.onRowAction = onRowAction
        self.isRowActionEnabled = isRowActionEnabled
        self.addMenu = addMenu
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Quire.Layout.Settings.plusMinusTop) {
            group
            QuirePlusMinus(isAddEnabled: isAddEnabled && pending == nil, isRemoveEnabled: selectedIndex != nil,
                           onRemove: onRemove, addMenu: addMenu)
        }
    }

    // MARK: Geometry

    /// Rows in the group: the accounts plus the pending row, or the single empty row.
    var rowCount: Int { QuireAccountGroup.rowCount(accounts: accounts.count, hasPending: pending != nil) }

    static func rowCount(accounts: Int, hasPending: Bool) -> Int {
        max(1, accounts + (hasPending ? 1 : 0))
    }

    /// The group's height: every row up to six, six beyond that.
    static func height(rows: Int) -> CGFloat {
        let s = Quire.Layout.Settings.self
        return CGFloat(min(rows, Int(s.groupMaxRows))) * s.accountRow
    }

    var scrolls: Bool { rowCount > Int(Quire.Layout.Settings.groupMaxRows) }

    private var selectedIndex: Int? {
        guard let selection else { return nil }
        return accounts.firstIndex { $0.id == selection }
    }

    // MARK: Group

    private var group: some View {
        let s = Quire.Layout.Settings.self
        let shape = RoundedRectangle(cornerRadius: s.groupRadius, style: .circular)
        let isFocused = focus?.wrappedValue ?? ownFocus
        let showsRing = (isFocused || forced.contains(.focused)) && activeState != .inactive
        return Group {
            if scrolls {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        rows(showsRing: showsRing)
                    }
                    .scrollIndicators(.automatic)
                    .frame(height: QuireAccountGroup.height(rows: rowCount))
                    .onScrollGeometryChange(for: QuireScrollEdges.self) { geometry in
                        QuireScrollEdges(geometry)
                    } action: { _, new in
                        edges = new
                    }
                    .onChange(of: selection) { _, id in
                        // Instantly, and only as far as needed: the ↑/↓ of a source list (spec §5.2, §5.40).
                        guard let id else { return }
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { proxy.scrollTo(id) }
                    }
                }
            } else {
                rows(showsRing: showsRing)
            }
        }
        .background(Color.qSheet)
        .clipShape(shape)
        .overlay(alignment: .top) {
            if scrolls && edges.top { QuireSettingsHairline() }
        }
        .overlay(alignment: .bottom) {
            if scrolls && edges.bottom { QuireSettingsHairline() }
        }
        .overlay { QuireGroupEdge(cornerRadius: s.groupRadius) }
        .focusable()
        .focusEffectDisabled()
        .focused(focus ?? $ownFocus)
        .onMoveCommand(perform: move)
        .onDeleteCommand {
            if selectedIndex != nil { onRemove() }
        }
        .accessibilityElement(children: .contain)
    }

    private func rows(showsRing: Bool) -> some View {
        VStack(spacing: 0) {
            if accounts.isEmpty && pending == nil {
                QuireAccountEmptyRow(title: emptyTitle, hint: emptyHint)
            }
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                let isSelected = account.id == selection
                QuireAccountRow(account, isSelected: isSelected, isActionEnabled: isRowActionEnabled(account),
                                onAction: { onRowAction(account) })
                    .focusRing(showsRing && isSelected)
                    .overlay(alignment: .top) {
                        if index > 0 && !hidesSeparator(above: index) {
                            QuireRowSeparator()
                        }
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in
                        if selection != account.id { selection = account.id }
                    })
                    .id(account.id)
            }
            if let pending {
                QuireAccountPendingRow(pending: pending)
                    .overlay(alignment: .top) {
                        if !accounts.isEmpty && accounts.last?.id != selection {
                            QuireRowSeparator()
                        }
                    }
            }
        }
    }

    /// Separators are hidden around the selected row: the one above it and the one below it.
    private func hidesSeparator(above index: Int) -> Bool {
        guard let selected = selectedIndex else { return false }
        return index == selected || index == selected + 1
    }

    private func move(_ direction: MoveCommandDirection) {
        let offset: Int
        switch direction {
        case .up: offset = -1
        case .down: offset = 1
        default: return
        }
        guard let next = QuireStep.index(after: selectedIndex, by: offset, count: accounts.count) else { return }
        selection = accounts[next].id
    }
}

/// Which edges of the scrolling group clip rows.
struct QuireScrollEdges: Equatable {
    var top: Bool
    var bottom: Bool

    init(top: Bool, bottom: Bool) {
        self.top = top
        self.bottom = bottom
    }

    init(_ geometry: ScrollGeometry) {
        let slack: CGFloat = 0.5
        top = geometry.contentOffset.y > slack
        bottom = geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - slack
    }
}

/// The group's hairline edge, outside its outline as the specimen's `0 0 0 1px` shadow is.
struct QuireGroupEdge: View {
    let cornerRadius: CGFloat

    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let width = QuireSettingsHairline.width(displayScale: displayScale, increasedContrast: contrast == .increased)
        // An inset stroke of a shape one hairline larger: whole-pixel geometry at every scale (see
        // `QuireFocusRingView`).
        RoundedRectangle(cornerRadius: cornerRadius + width, style: .circular)
            .strokeBorder(Color.qRule, lineWidth: width)
            .padding(-width)
            .allowsHitTesting(false)
    }
}

/// A separator from the text column (x = 62) to the trailing edge.
struct QuireRowSeparator: View {
    var body: some View {
        QuireSettingsHairline()
            .padding(.leading, Quire.Layout.Settings.accountHairlineX)
    }
}

/// The empty group's single row.
struct QuireAccountEmptyRow: View {
    let title: String
    let hint: String

    var body: some View {
        VStack(spacing: 0) {
            Text(title).quireLine(.body).foregroundStyle(Color.qInk2)
            Text(hint).quireLine(.snippet).foregroundStyle(Color.qInk3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: Quire.Layout.Settings.accountRow)
        .accessibilityElement(children: .combine)
    }
}

/// The pending row of an account signing in.
struct QuireAccountPendingRow: View {
    let pending: QuireAccountPending

    var body: some View {
        let s = Quire.Layout.Settings.self
        HStack(spacing: 0) {
            QuireAvatarView.pending(diameter: s.accountFace)
                .padding(.leading, s.accountFaceX)
                .padding(.trailing, s.accountHairlineX - s.accountFaceX - s.accountFace)
            VStack(alignment: .leading, spacing: 0) {
                Text(pending.title).quireLine(.body).foregroundStyle(Color.qInk)
                Text(pending.provider).quireLine(.snippet).foregroundStyle(Color.qInk2)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: s.statusGap)
            Button(pending.cancelTitle, action: pending.onCancel)
                .buttonStyle(.quire(.secondary, size: .small))
                .padding(.trailing, s.statusTrailing)
        }
        .frame(height: s.accountRow)
    }
}
