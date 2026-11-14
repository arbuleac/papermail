import SwiftUI

/// A Settings sheet that lists rules and removes them one by one (spec §5.40, the Senders sheet of "Sender rules
/// (Q4.2)"): `settings.sendersWidth` pt wide on `canvas`, padded as a tab's content (20 24 22); its title in `title`
/// `ink`, the caption under it in `meta` `ink3` 8 pt below, the `QuireRemovableList` 16 pt below that, and Done (small
/// primary, the default button, so ↩ and Esc close it) trailing 20 pt under the list. Nothing to save: each − acts at
/// once, as it says.
public struct QuireRuleSheet: View {
    let title: String
    let caption: String
    let rows: [QuireRemovableList.Row]
    let emptyTitle: String
    let emptyHint: String
    let onRemove: (QuireRemovableList.Row) -> Void
    let onDone: () -> Void

    public init(title: String, caption: String, rows: [QuireRemovableList.Row], emptyTitle: String, emptyHint: String,
                onRemove: @escaping (QuireRemovableList.Row) -> Void, onDone: @escaping () -> Void) {
        self.title = title
        self.caption = caption
        self.rows = rows
        self.emptyTitle = emptyTitle
        self.emptyHint = emptyHint
        self.onRemove = onRemove
        self.onDone = onDone
    }

    public var body: some View {
        let s = Quire.Layout.Settings.self
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .quireLine(.title)
                .foregroundStyle(Color.qInk)
                .accessibilityAddTraits(.isHeader)
            Text(caption)
                .quireParagraph(.meta)
                .foregroundStyle(Color.qInk3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, s.captionGap)
            QuireRemovableList(rows: rows, emptyTitle: emptyTitle, emptyHint: emptyHint, onRemove: onRemove)
                .padding(.top, s.noticeGap)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button("Done", action: onDone)
                    .buttonStyle(.quire(.primary, size: .small))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, s.sectionGap)
        }
        .padding(.top, s.padTop)
        .padding(.horizontal, s.padX)
        .padding(.bottom, s.padBottom)
        .frame(width: s.sendersWidth, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.qCanvas)
        .onExitCommand(perform: onDone)
    }
}
