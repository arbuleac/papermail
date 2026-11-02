import SwiftUI

/// A section title in a `QuireSettingsGrid` (spec §5.40, OAuth): `title` `ink` at the content's leading edge,
/// spanning both columns, 20 pt below the rows before it (`settings.sectionGap`); the first section of a tab
/// sits at the top of the content.
public struct QuireSettingsSection: View {
    let title: String
    let isFirst: Bool

    public init(_ title: String, isFirst: Bool = false) {
        self.title = title
        self.isFirst = isFirst
    }

    public var body: some View {
        GridRow {
            Text(title)
                .quireLine(.title)
                .foregroundStyle(Color.qInk)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, isFirst ? 0 : Quire.Layout.Settings.sectionGap)
                .gridCellColumns(2)
                .gridCellAnchor(.leading)
        }
    }
}
