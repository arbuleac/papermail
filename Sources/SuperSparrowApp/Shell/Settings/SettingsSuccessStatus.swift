import SSDesign
import SwiftUI

/// A confirmation that sits in its row, not a banner (§5.40): the success glyph and the words in `snippet` `ink2`.
/// OAuth's “Saved” beside Save, from a successful save until the next edit; General's “SuperSparrow is your default
/// mail app.” while it is.
struct SettingsSuccessStatus: View {
    let words: String

    var body: some View {
        let s = Quire.Layout.Settings.self
        HStack(spacing: s.statusGlyphGap) {
            if let glyph = QuireSymbol.image(Quire.Icon.success, size: .custom(s.statusGlyph)) {
                Image(nsImage: glyph)
                    .renderingMode(.template)
                    .foregroundStyle(.qSuccess)
            }
            Text(words)
                .font(.quire(.snippet))
                .tracking(QuireFont.Role.snippet.tracking)
                .foregroundStyle(.qInk2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(words)
    }
}
