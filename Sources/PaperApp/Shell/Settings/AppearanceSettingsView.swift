import PaperDesign
import SwiftUI

/// Settings › Appearance (spec §5.40, §4.16): how mail looks, in the General grid. Theme (five tiles and the chosen
/// theme's caption), Appearance (which half of the theme's light and dark pair the app shows) and the Dark Mode default
/// for mail that sets its own colours; then, after a hairline, Font and Text size, which moved here from General so
/// General stays under its control cap and type sits beside the colours, as Mail keeps them.
///
/// Every change applies at once, Settings included: the tab is hosted in a `QuireThemeRoot`, so a theme redraws it in
/// place and keyboard focus stays on the tiles. Font applies live across the app (spec §4.4), Text size live to the
/// list, the reader and every composer (spec §4.15); Settings itself stays at Default. There is no Reset: choosing
/// Study is the reset.
struct AppearanceSettingsView: View {
    static let darkModeTitle = "Adapt mail that sets its own colours"
    static let darkModeCaption = "Off: it opens in the sender's colours, on a white page. ⇧⌘O switches one message."

    @ObservedObject var settings: AppSettings

    var body: some View {
        QuireSettingsGrid {
            // The label sits on the pictures' centre line, as every other row's sits on its control's.
            QuireSettingsRow("Theme", alignment: .top) {
                QuireThemePicker("Theme", selection: $settings.theme)
            }
            QuireSettingsRow("Appearance") {
                QuireRadioGroup("Appearance", selection: $settings.appearance, options: AppAppearance.allCases,
                                accessibilityLabel: Self.spokenTitle(for:), label: Self.title(for:))
            }
            QuireSettingsRow("Dark Mode") {
                Toggle(Self.darkModeTitle, isOn: $settings.adaptsMailColours)
                    .toggleStyle(.quireCheckbox)
                    // A light app shows no mail in a dark appearance, so the default would change nothing; Automatic
                    // keeps it, since night will come.
                    .disabled(settings.appearance == .light)
            }
            QuireSettingsCaption(Self.darkModeCaption)
            QuireSettingsDivider()
            QuireSettingsRow("Font") {
                QuirePopup("Font", selection: $settings.typeface, options: QuireFont.Typeface.allCases) { typeface in
                    typeface == .newYork ? "New York" : "SF Pro"
                }
            }
            QuireSettingsRow("Text size") {
                QuirePopup("Text size", selection: $settings.textSize, options: QuireFont.TextSize.allCases) { $0.title }
            }
        }
        .settingsTabContent()
    }

    static func title(for appearance: AppAppearance) -> String {
        switch appearance {
        case .automatic: return "Automatic"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Automatic alone says what it follows; the others say all there is.
    static func spokenTitle(for appearance: AppAppearance) -> String {
        appearance == .automatic ? "Automatic, follows macOS" : title(for: appearance)
    }
}
