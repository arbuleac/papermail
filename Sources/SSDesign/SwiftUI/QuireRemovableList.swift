import SwiftUI

/// A list whose rows are each removed on their own (spec §5.40, the Senders sheet of "Sender rules (Q4.2)").
///
/// - A `sheet` group, radius 8, with a hairline edge, as the account group is, of `settings.senderRow` pt rows: the
///   title in `body` `ink` from x = `settings.senderRowX`, cut in the middle (an address keeps its start and its
///   domain), then the detail in `snippet` `ink2` and, while the row is not settled, “ · ” and its state in `snippet`
///   `ink3` (“Saving to Gmail…”), then 12 pt (`settings.senderActionGap`) and a − button `settings.senderRemoveInset`
///   from the trailing edge, so the button sits centred in the row's last 40 pt. A row that cannot be removed again (one
///   already on its way out) draws its − disabled.
/// - The − is the +/− pair's half on its own: 22 pt, `raised`, a 1 pt `ruleStrong` edge, radius `r.sm`, `minus`
///   11 pt `ink2`, hover `raised + hover` with the glyph `ink`, pressed `raised + pressed`, the Quire ring on focus.
///   Each − is a Tab stop, named “Remove” and the row's title for VoiceOver.
/// - No selection: nothing here is chosen before acting, so rows take no wash. Hairlines between rows from the text
///   column.
/// - Past `settings.senderRowsMax` rows the group scrolls inside, a `rule` hairline marking each clipped edge.
/// - Empty: one 56 pt row, `emptyTitle` (`body` `ink2`) over `emptyHint` (`snippet` `ink3`), centred.
public struct QuireRemovableList: View {
    public struct Row: Identifiable, Equatable, Sendable {
        public var id: String
        public var title: String
        public var detail: String
        /// Where the row stands while it is not settled (“Saving to Gmail…”, “Removing…”), after the detail in `ink3`;
        /// nil once it is.
        public var state: String?
        /// Whether the − acts. A row already on its way out has nothing more to remove, so its − is disabled rather than
        /// gone, keeping every row's detail in the same column.
        public var isRemovable: Bool

        public init(id: String, title: String, detail: String, state: String? = nil, isRemovable: Bool = true) {
            self.id = id
            self.title = title
            self.detail = detail
            self.state = state
            self.isRemovable = isRemovable
        }
    }

    let rows: [Row]
    let emptyTitle: String
    let emptyHint: String
    let onRemove: (Row) -> Void

    @State private var edges = QuireScrollEdges(top: false, bottom: true)

    public init(rows: [Row], emptyTitle: String, emptyHint: String, onRemove: @escaping (Row) -> Void) {
        self.rows = rows
        self.emptyTitle = emptyTitle
        self.emptyHint = emptyHint
        self.onRemove = onRemove
    }

    /// The group's height: every row up to the cap, the cap beyond it; the empty row's own height with none.
    static func height(rows: Int) -> CGFloat {
        let s = Quire.Layout.Settings.self
        guard rows > 0 else { return s.accountRow }
        return CGFloat(min(rows, Int(s.senderRowsMax))) * s.senderRow
    }

    var scrolls: Bool { rows.count > Int(Quire.Layout.Settings.senderRowsMax) }

    public var body: some View {
        let s = Quire.Layout.Settings.self
        let shape = RoundedRectangle(cornerRadius: s.groupRadius, style: .circular)
        Group {
            if scrolls {
                ScrollView(.vertical) {
                    content
                }
                .scrollIndicators(.automatic)
                .frame(height: QuireRemovableList.height(rows: rows.count))
                .onScrollGeometryChange(for: QuireScrollEdges.self) { geometry in
                    QuireScrollEdges(geometry)
                } action: { _, new in
                    edges = new
                }
            } else {
                content
            }
        }
        .background(.qSheet)
        .clipShape(shape)
        .overlay(alignment: .top) {
            if scrolls && edges.top { QuireSettingsHairline() }
        }
        .overlay(alignment: .bottom) {
            if scrolls && edges.bottom { QuireSettingsHairline() }
        }
        .overlay { QuireGroupEdge(cornerRadius: s.groupRadius) }
        .accessibilityElement(children: .contain)
    }

    private var content: some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                QuireAccountEmptyRow(title: emptyTitle, hint: emptyHint)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                QuireRemovableRow(row: row) { onRemove(row) }
                    .overlay(alignment: .top) {
                        if index > 0 {
                            QuireSettingsHairline()
                                .padding(.leading, Quire.Layout.Settings.senderRowX)
                        }
                    }
            }
        }
    }
}

/// One row of `QuireRemovableList`.
struct QuireRemovableRow: View {
    let row: QuireRemovableList.Row
    let onRemove: () -> Void

    var body: some View {
        let s = Quire.Layout.Settings.self
        HStack(spacing: 0) {
            Text(verbatim: row.title)
                .quireLine(.body)
                .truncationMode(.middle)
                .foregroundStyle(.qInk)
                .padding(.leading, s.senderRowX)
            Spacer(minLength: s.senderActionGap)
            HStack(spacing: 0) {
                Text(verbatim: row.detail)
                    .foregroundStyle(.qInk2)
                if let state = row.state {
                    // Quieter than what the rule does: the state passes, the rule stays.
                    Text(verbatim: " · " + state)
                        .foregroundStyle(.qInk3)
                }
            }
            .quireLine(.snippet)
            .fixedSize()
            .padding(.trailing, s.senderActionGap)
            Button(action: onRemove) {
                QuireSymbolImage(name: Quire.Icon.removeRule, size: .custom(s.plusMinusGlyph))
            }
            .buttonStyle(QuireRemoveButtonStyle())
            .focusEffectDisabled()
            .disabled(!row.isRemovable)
            .accessibilityLabel("Remove \(row.title)")
            .padding(.trailing, s.senderRemoveInset)
        }
        .frame(height: s.senderRow)
        .accessibilityElement(children: .contain)
    }
}

/// The − on its own: one half of the +/− pair with all four corners rounded and the pair's states
/// (`QuireJoinedButtonAppearance`).
struct QuireRemoveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuireRemoveButtonChrome(isPressed: configuration.isPressed) {
            configuration.label
        }
    }
}

struct QuireRemoveButtonChrome<Label: View>: View {
    let isPressed: Bool
    @ViewBuilder let label: () -> Label

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.quireForcedStates) private var forced
    @State private var isHovered = false

    var body: some View {
        let side = Quire.Layout.Settings.plusMinus
        let radius = Quire.Radius.sm
        let state = QuireControlState(isHovered: isHovered, isPressed: isPressed, isFocused: isFocused, isEnabled: isEnabled,
                                      isWindowKey: activeState != .inactive).forcing(forced)
        let look = QuireJoinedButtonAppearance.resolve(state: state)
        let shape = RoundedRectangle(cornerRadius: radius, style: .circular)
        label()
            .foregroundStyle(look.glyph.style)
            .frame(width: side, height: side)
            .background { QuireFace(shape: shape, fill: look.face, edge: look.edge) }
            .overlay {
                if let gap = look.ringGap {
                    QuireFocusRingView(shape: .roundedRectangle(cornerRadius: radius), gap: gap)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(shape)
            .quireMinimumHitArea(width: side, height: side)
            .quirePointer()
            .onHover { isHovered = $0 }
    }
}
