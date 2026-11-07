import SSDesign
import SwiftUI

/// Settings › General (spec §5.40): a two-column grid, a hairline between the reading group and the mail
/// group. Font applies live across the app (spec §4.4).
struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        QuireSettingsGrid {
            QuireSettingsRow("Font") {
                QuirePopup("Font", selection: $settings.typeface, options: QuireFont.Typeface.allCases) { typeface in
                    typeface == .newYork ? "New York" : "SF Pro"
                }
            }
            QuireSettingsRow("List density") {
                QuireRadioGroup("List density", selection: $settings.listDensity, options: AppSettings.ListDensity.allCases) { density in
                    density == .standard ? "Standard" : "Compact"
                }
            }
            QuireSettingsRow("Rows") {
                Toggle("Show account initials in unified views", isOn: accountInitials)
                    .toggleStyle(.quireCheckbox)
            }
            if settings.showsSevenAccountsCaption {
                QuireSettingsCaption("Turned on when you added a seventh account.")
            }
            QuireSettingsRow("Undo send") {
                QuirePopup("Undo send", selection: $settings.undoSendDelay, options: AppSettings.undoSendChoices) { seconds in
                    "\(Int(seconds)) seconds"
                }
            }
            QuireSettingsDivider()
            QuireSettingsRow("Remote images") {
                Toggle("Load by default", isOn: $settings.loadRemoteImages).toggleStyle(.quire)
            }
            QuireSettingsCaption("Off: images load only when you ask, per message.")
            QuireSettingsRow("Notifications") {
                Toggle("New mail", isOn: $settings.notificationsEnabled).toggleStyle(.quire)
            }
            QuireSettingsRow(nil) {
                Toggle("Show sender and subject", isOn: $settings.showPreviews)
                    .toggleStyle(.quireCheckbox)
                    .disabled(!settings.notificationsEnabled)
            }
        }
        .settingsTabContent()
    }

    /// The user's own choice ends the seven-accounts automatic state for good (§5.40).
    private var accountInitials: Binding<Bool> {
        Binding(get: { settings.showAccountInitials }, set: { settings.setShowAccountInitialsByUser($0) })
    }
}
