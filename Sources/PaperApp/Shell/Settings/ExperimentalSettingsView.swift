import PaperDesign
import SwiftUI

/// Settings › Experimental (spec §5.58): the sixth tab, after AI, on General's grid. A lead caption, then one row per
/// experiment, each a toggle off by default with its caption, a hairline between them: Offer reader mode (the gate, which
/// turns reader mode on and off with it, §5.59) and Block trackers (§5.60). Each applies at once; the behaviour belongs to
/// the reader, which follows `AppSettings.readerModeChanged` and `trackerBlockingChanged`.
struct ExperimentalSettingsView: View {
    static let leadCaption = "Features still taking shape. They may change or go away."
    static let readerModeTitle = "Offer reader mode"
    static let readerModeCaption = "Shows each message's plain text version instead of its design. "
        + "Switch it with the reader's button or \u{21E7}\u{2318}R."
    static let trackersTitle = "Block trackers"
    static let trackersCaption = "Stops senders learning when and where you open their mail, even when images load."

    @ObservedObject var settings: AppSettings

    var body: some View {
        QuireSettingsGrid {
            // In the field column, as every caption is, and a caption's gap above the first row's own space.
            QuireSettingsCaption(Self.leadCaption, spacingBelow: Quire.Layout.Settings.captionGap)
            QuireSettingsRow("Reader mode") {
                Toggle(Self.readerModeTitle, isOn: $settings.offersReaderMode).toggleStyle(.quire)
            }
            QuireSettingsCaption(Self.readerModeCaption)
            QuireSettingsDivider()
            QuireSettingsRow("Trackers") {
                Toggle(Self.trackersTitle, isOn: $settings.blocksTrackers).toggleStyle(.quire)
            }
            QuireSettingsCaption(Self.trackersCaption)
        }
        .settingsTabContent()
    }
}
