import SwiftUI

/// A caption in the field column of a `QuireSettingsGrid` (spec §5.40): `meta` `ink3`, at most 360 pt wide
/// (`settings.captionMaxWidth`), 8 pt under the control above it (`settings.captionGap`), with an optional
/// inline `accent` link after the words (the OAuth caption's “How to create these…”).
///
/// A 24 pt control centred in its 40 pt row already ends 8 pt above the row's bottom, so the caption starts
/// right at the row's edge; `spacingBelow` is the gap to whatever follows (the OAuth buttons sit 20 pt under
/// their caption).
public struct QuireSettingsCaption: View {
    let text: String
    let link: (title: String, action: () -> Void)?
    let spacingBelow: CGFloat

    public init(_ text: String, link: (title: String, action: () -> Void)? = nil, spacingBelow: CGFloat = 0) {
        self.text = text
        self.link = link
        self.spacingBelow = spacingBelow
    }

    /// The caption's distance from the top of its grid row: the 8 pt gap minus what the row above leaves under
    /// a settings-height control.
    static var topPadding: CGFloat {
        let s = Quire.Layout.Settings.self
        return max(0, s.captionGap - (s.row - s.fieldHeight) / 2)
    }

    public var body: some View {
        let s = Quire.Layout.Settings.self
        // One cell across both columns, inset to the field column: `Grid` measures a cell of the second column
        // at an even share of the width while it settles the columns, and wrapped text measured that narrow
        // reserves lines it never uses. Across both columns it is measured at the full width, and
        // `quireWrapWidth` caps it at 360 pt for measuring and drawing alike.
        GridRow {
            QuireInlineLinkText(text, link: link, role: .meta, linkRole: .meta)
                .foregroundStyle(Color.qInk3)
                .quireWrapWidth(s.captionMaxWidth)
                .padding(.leading, s.labelColumn + s.labelGap)
                .padding(.top, QuireSettingsCaption.topPadding)
                .padding(.bottom, spacingBelow)
                .gridCellColumns(2)
                .gridCellAnchor(.topLeading)
        }
    }
}
