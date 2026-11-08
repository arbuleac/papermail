import SSDesign
import SwiftUI

/// Settings › General (spec §5.40): a two-column grid, hairlines between the reading group, the mail group and Mail
/// links. Font applies live across the app (spec §4.4).
struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var defaultMailApp: DefaultMailAppModel

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
            QuireSettingsDivider()
            QuireSettingsRow("Mail links") {
                DefaultMailAppControl(model: defaultMailApp)
            }
            if let failure = defaultMailApp.row.failure {
                QuireSettingsCaption(failure, isError: true)
            }
        }
        .settingsTabContent()
        // The user can pick another mail app in Mail's settings while this tab is away; the window asks again as it
        // reopens on this tab and as the app comes back to the front.
        .onAppear { defaultMailApp.refresh() }
    }

    /// The user's own choice ends the seven-accounts automatic state for good (§5.40).
    private var accountInitials: Binding<Bool> {
        Binding(get: { settings.showAccountInitials }, set: { settings.setShowAccountInitialsByUser($0) })
    }
}

/// Mail links' control (§5.40): the words while SuperSparrow opens mail links, otherwise the button, disabled while
/// macOS asks the user to confirm. Nothing until the first answer, rather than a button that may vanish.
struct DefaultMailAppControl: View {
    @ObservedObject var model: DefaultMailAppModel

    var body: some View {
        let row = model.row
        if let words = row.words {
            SettingsSuccessStatus(words: words)
        } else if let title = row.buttonTitle {
            Button(title) { model.makeDefault() }
                .buttonStyle(.quire(.secondary, size: .small))
                .disabled(!row.isButtonEnabled)
        } else {
            Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
        }
    }
}
