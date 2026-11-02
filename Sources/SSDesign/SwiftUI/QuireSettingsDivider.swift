import SwiftUI

/// The hairline between groups of a `QuireSettingsGrid` (spec §5.40, General): a `rule` hairline across the
/// whole content width, centred in a 40 pt row slot as the specimen draws it.
public struct QuireSettingsDivider: View {
    public init() {}

    public var body: some View {
        GridRow {
            QuireSettingsHairline()
                .frame(height: Quire.Layout.Settings.row)
                .gridCellColumns(2)
                .gridCellUnsizedAxes(.horizontal)
                .accessibilityHidden(true)
        }
    }
}
