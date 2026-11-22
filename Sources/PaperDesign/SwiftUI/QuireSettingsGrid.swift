import SwiftUI

/// The Settings form layout (spec §5.40, §8.3): a `Grid` whose first column holds `body` `ink` labels,
/// right-aligned in 140 pt (`settings.labelColumn`), with controls starting 12 pt after it
/// (`settings.labelGap`) on 40 pt rows (`settings.row`), each control centred in its row. It is a plain
/// `Grid`, not `Form` with `.formStyle(.columns)`, which would bring native control styling back.
///
///     QuireSettingsGrid {
///         QuireSettingsSection("Google", isFirst: true)
///         QuireSettingsRow("Client ID") { TextField(…).quireFieldStyle(.mono) }
///         QuireSettingsCaption("Register a Desktop app client…", link: ("How to create these…", { … }))
///         QuireSettingsDivider()
///         QuireSettingsRow("Remote images") { Toggle("Load by default", isOn: $images).toggleStyle(.quire) }
///     }
///
/// Its children are `QuireSettingsRow`, `QuireSettingsSection`, `QuireSettingsCaption` and
/// `QuireSettingsDivider` (or any `GridRow`). Modifiers on a child turn it into a full-width cell, so spacing
/// belongs inside the rows, which take it as parameters.
public struct QuireSettingsGrid<Content: View>: View {
    let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Quire.Layout.Settings.labelGap, verticalSpacing: 0) {
            content
        }
    }
}
