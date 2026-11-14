import SSDesign
import SwiftUI

/// Settings › General (spec §5.40): a two-column grid, hairlines between the reading group, the mail group, Keep mail on
/// this Mac, and At login with Mail links. Font applies live across the app (spec §4.4), Text size live to the list, the
/// reader and every composer (spec §4.15). Settings itself stays at Default.
struct GeneralSettingsView: View {
    static let keepMailCaption = "Older mail stays in the list and in search, and downloads again when you open it."

    @ObservedObject var settings: AppSettings
    @ObservedObject var defaultMailApp: DefaultMailAppModel
    @ObservedObject var mailboxSize: MailboxSizeModel
    @ObservedObject var launchAtLogin: LaunchAtLoginModel

    var body: some View {
        QuireSettingsGrid {
            QuireSettingsRow("Font") {
                QuirePopup("Font", selection: $settings.typeface, options: QuireFont.Typeface.allCases) { typeface in
                    typeface == .newYork ? "New York" : "SF Pro"
                }
            }
            QuireSettingsRow("Text size") {
                QuirePopup("Text size", selection: $settings.textSize, options: QuireFont.TextSize.allCases) { $0.title }
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
            QuireSettingsRow("Keep mail on this Mac") {
                KeepMailControl(settings: settings, mailboxSize: mailboxSize)
            }
            QuireSettingsCaption(Self.keepMailCaption)
            QuireSettingsDivider()
            QuireSettingsRow("At login") {
                LaunchAtLoginToggle(model: launchAtLogin)
            }
            if launchAtLogin.row.needsApproval {
                QuireSettingsRow(nil) {
                    LaunchAtLoginApproval { launchAtLogin.openLoginItems() }
                }
            }
            if let caption = launchAtLogin.row.caption {
                QuireSettingsCaption(caption)
            }
            if let failure = launchAtLogin.row.failure {
                QuireSettingsCaption(failure, isError: true)
            }
            QuireSettingsRow("Mail links") {
                DefaultMailAppControl(model: defaultMailApp)
            }
            if let failure = defaultMailApp.row.failure {
                QuireSettingsCaption(failure, isError: true)
            }
        }
        .settingsTabContent()
        // The user can pick another mail app in Mail's settings, or approve the login item in System Settings, while
        // this tab is away; the window asks again as it reopens on this tab and as the app comes back to the front. The
        // mailbox's size is measured again as well.
        .onAppear {
            defaultMailApp.refresh()
            launchAtLogin.refresh()
            mailboxSize.refresh()
        }
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

/// At login's toggle (§5.40): where macOS says SuperSparrow stands, or where a change is taking it. Nothing until the
/// first answer, rather than a toggle that may flip.
struct LaunchAtLoginToggle: View {
    @ObservedObject var model: LaunchAtLoginModel

    var body: some View {
        let row = model.row
        if row.isOn != nil {
            Toggle(LaunchAtLoginModel.toggleTitle, isOn: Binding(get: { model.row.isOn ?? false }, set: { model.setOn($0) }))
                .toggleStyle(.quire)
                .disabled(!row.isToggleEnabled)
                .accessibilityLabel(LaunchAtLoginModel.accessibilityLabel)
        } else {
            Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
        }
    }
}

/// At login's second row while macOS waits for the user's approval (§5.40): the account rows' status shape, glyph and
/// words, then the button that takes the user to the one place the approval can be given.
struct LaunchAtLoginApproval: View {
    let openLoginItems: () -> Void

    var body: some View {
        let s = Quire.Layout.Settings.self
        HStack(spacing: s.statusButtonGap) {
            HStack(spacing: s.statusGlyphGap) {
                if let glyph = QuireSymbol.image(Quire.Icon.loginApproval, size: .custom(s.statusGlyph)) {
                    Image(nsImage: glyph)
                        .renderingMode(.template)
                        .foregroundStyle(Color.qInk2)
                }
                Text(LaunchAtLoginModel.approvalWords)
                    .font(.quire(.snippet))
                    .tracking(QuireFont.Role.snippet.tracking)
                    .foregroundStyle(Color.qInk2)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(LaunchAtLoginModel.approvalWords)
            Button(LaunchAtLoginModel.openLoginItemsTitle, action: openLoginItems)
                .buttonStyle(.quire(.secondary, size: .small))
        }
    }
}

/// Keep mail on this Mac's control (§5.40): the popup, and after it the mailbox's size on disk once measured. Nothing
/// stands in for the number before the first answer, so no placeholder flashes.
struct KeepMailControl: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var mailboxSize: MailboxSizeModel

    var body: some View {
        HStack(spacing: Quire.Layout.Settings.mailboxSizeGap) {
            QuirePopup("Keep mail on this Mac", selection: $settings.keepMail, options: AppSettings.keepMailChoices) { retention in
                AppSettings.title(for: retention)
            }
            if let size = mailboxSize.label {
                Text(size)
                    .font(.quire(.meta))
                    .tracking(QuireFont.Role.meta.tracking)
                    .foregroundStyle(Color.qInk2)
                    .help("The mail database and the attachment cache on this Mac")
                    .accessibilityLabel("\(size) on this Mac")
            }
        }
    }
}
