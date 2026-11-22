import SwiftUI

/// A Settings grid row whose value is wrapping text (spec §5.40, the account detail's Last error): the label in
/// the 140 pt column, the text in the field column, up to `maxLines` lines at most 360 pt wide. One line makes
/// a 40 pt row with the line centred in it, like every other row; each further line adds one line height
/// (14 pt in `meta`). The full text is the tooltip, so nothing cut by the line limit is lost.
///
/// The row is one cell across both columns, laid out inside: `Grid` measures second-column cells at an even
/// share of its width while it settles the columns, and wrapped text measured that narrow would reserve lines
/// it never draws (see `QuireWrapWidth`).
public struct QuireSettingsTextRow: View {
    let label: String
    let text: String
    let role: QuireFont.Role
    let color: Color
    let maxLines: Int

    public init(_ label: String, text: String, role: QuireFont.Role = .meta, color: Color = .qInk2,
                maxLines: Int = Int(Quire.Layout.Settings.lastErrorMaxLines)) {
        self.label = label
        self.text = text
        self.role = role
        self.color = color
        self.maxLines = maxLines
    }

    public var body: some View {
        let s = Quire.Layout.Settings.self
        GridRow {
            HStack(alignment: .top, spacing: s.labelGap) {
                QuireSettingsLabel(text: label, minHeight: s.row)
                Text(text)
                    .quireParagraph(role)
                    .foregroundStyle(color)
                    .lineLimit(maxLines)
                    .truncationMode(.tail)
                    .help(text)
                    .quireWrapWidth(s.captionMaxWidth)
                    .padding(.vertical, (s.row - role.lineHeight) / 2)
            }
            .gridCellColumns(2)
            .gridCellAnchor(.topLeading)
        }
    }
}
