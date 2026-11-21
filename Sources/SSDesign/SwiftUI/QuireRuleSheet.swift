import SwiftUI

/// A Settings sheet that lists rules and removes them one by one (spec §5.40, §5.52, the Senders sheet):
/// `settings.sendersWidth` pt wide on `canvas`, padded as a tab's content (20 24 22); its title in `title` `ink`, the
/// caption under it in `meta` `ink3` 8 pt below, an optional notice banner (§5.38) 16 pt below that, the
/// `QuireRemovableList` 16 pt below the caption or the notice, and 20 pt under the list one row holding the optional foot
/// (`QuireRuleSheetFoot`, leading) and Done (small primary, trailing, the default button, so ↩ and Esc close it). Nothing
/// to save: each − acts at once, as it says.
public struct QuireRuleSheet: View {
    let title: String
    let caption: String
    let notice: QuireBanner?
    let rows: [QuireRemovableList.Row]
    let emptyTitle: String
    let emptyHint: String
    let foot: QuireRuleSheetFoot?
    let onRemove: (QuireRemovableList.Row) -> Void
    let onDone: () -> Void

    public init(title: String, caption: String, notice: QuireBanner? = nil, rows: [QuireRemovableList.Row], emptyTitle: String,
                emptyHint: String, foot: QuireRuleSheetFoot? = nil, onRemove: @escaping (QuireRemovableList.Row) -> Void,
                onDone: @escaping () -> Void) {
        self.title = title
        self.caption = caption
        self.notice = notice
        self.rows = rows
        self.emptyTitle = emptyTitle
        self.emptyHint = emptyHint
        self.foot = foot
        self.onRemove = onRemove
        self.onDone = onDone
    }

    public var body: some View {
        let s = Quire.Layout.Settings.self
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .quireLine(.title)
                .foregroundStyle(.qInk)
                .accessibilityAddTraits(.isHeader)
            Text(caption)
                .quireParagraph(.meta)
                .foregroundStyle(.qInk3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, s.captionGap)
            if let notice {
                notice.padding(.top, s.noticeGap)
            }
            QuireRemovableList(rows: rows, emptyTitle: emptyTitle, emptyHint: emptyHint, onRemove: onRemove)
                .padding(.top, s.noticeGap)
            HStack(alignment: .center, spacing: 0) {
                if let foot {
                    QuireRuleSheetFootLine(foot: foot)
                }
                Spacer(minLength: s.senderActionGap)
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
        .background(.qCanvas)
        .onExitCommand(perform: onDone)
    }
}

/// The foot's one line: the spinner, then the words with the link inline after them (a “·” between), wrapping under
/// themselves should they ever outgrow the room beside Done.
struct QuireRuleSheetFootLine: View {
    let foot: QuireRuleSheetFoot

    var body: some View {
        let s = Quire.Layout.Settings.self
        HStack(alignment: .center, spacing: s.statusGlyphGap) {
            if foot.isWorking {
                QuireSpinner(.small)
            }
            QuireInlineLinkText(message, link: foot.link, role: .meta, linkRole: .meta)
                .foregroundStyle(.qInk3)
        }
        .accessibilityElement(children: .contain)
    }

    private var message: String {
        guard let words = foot.words else { return "" }
        return foot.link == nil ? words : words + " ·"
    }
}
