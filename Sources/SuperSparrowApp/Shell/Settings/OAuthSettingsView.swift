import AppKit
import SSDesign
import SwiftUI

/// Settings › OAuth (spec §5.40): one form, row by row, with the incoming or failure notice above it, the
/// caption under the last field, and Show File in Finder · “Saved” · Save at the bottom.
struct OAuthSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let s = Quire.Layout.Settings.self
        VStack(alignment: .leading, spacing: 0) {
            if let notice {
                notice.padding(.bottom, s.noticeGap)
            }
            QuireSettingsGrid {
                QuireSettingsSection("Google", isFirst: true)
                QuireSettingsFieldRow("Client ID") {
                    TextField("", text: $model.oauth.googleClientID, prompt: QuireFieldStyle.prompt("….apps.googleusercontent.com"))
                        .quireFieldStyle(.mono, error: SettingsModel.googleClientIDError(model.oauth.googleClientID))
                        .accessibilityLabel("Google client ID")
                }
                QuireSettingsRow("Client secret") {
                    QuireSecureField("Google client secret", text: $model.oauth.googleClientSecret, prompt: "GOCSPX-…")
                }
                QuireSettingsSection("Microsoft")
                QuireSettingsFieldRow("Client ID") {
                    TextField("", text: $model.oauth.microsoftClientID, prompt: QuireFieldStyle.prompt("00000000-0000-0000-0000-000000000000"))
                        .quireFieldStyle(.mono, error: SettingsModel.microsoftClientIDError(model.oauth.microsoftClientID))
                        .accessibilityLabel("Microsoft client ID")
                }
                QuireSettingsRow("Tenant") {
                    TextField("", text: $model.oauth.microsoftTenant, prompt: QuireFieldStyle.prompt("common"))
                        .quireFieldStyle(.mono)
                        .accessibilityLabel("Microsoft tenant")
                }
                QuireSettingsCaption("Register a Desktop app client in Google Cloud Console with the Gmail API enabled, and a Mobile and "
                                     + "desktop app in Microsoft Entra with http://localhost as its redirect URI. Leave Tenant as common to "
                                     + "allow both work and personal Microsoft accounts.",
                                     link: ("How to create these…", OAuthSettingsView.openSetupGuide), spacingBelow: s.sectionGap)
                QuireSettingsRow(nil, minHeight: s.fieldHeight) {
                    HStack(spacing: s.savedGap) {
                        Button("Show File in Finder") {
                            NSWorkspace.shared.activateFileViewerSelecting([model.oauthFileURL])
                        }
                        .buttonStyle(.quire(.secondary, size: .small))
                        .disabled(!model.oauthFileExists)
                        Spacer(minLength: 0)
                        if model.oauthSaved {
                            OAuthSavedStatus()
                        }
                        Button("Save") { model.saveOAuth() }
                            .buttonStyle(.quire(.primary, size: .small))
                            .keyboardShortcut(.defaultAction)
                            .disabled(!model.oauthChanged)
                    }
                }
            }
        }
        .settingsTabContent()
    }

    private var notice: QuireBanner? {
        switch model.oauthNotice {
        case .needsClient(let kind)?:
            let company = kind == .gmail ? "Google" : "Microsoft"
            let service = kind == .gmail ? "a Gmail account" : "a Microsoft account"
            return QuireBanner(.info, "To add \(service), SuperSparrow needs your own \(company) OAuth client ID. Enter it below and click "
                               + "Save, then try again.", link: ("How to create one…", OAuthSettingsView.openSetupGuide))
        case .unreadable(let reason)?:
            return QuireBanner(.danger, "Couldn't read the OAuth settings. \(reason) Correct the fields below and click Save.")
        case .saveFailed(let reason)?:
            return QuireBanner(.danger, "Couldn't save the OAuth settings. \(reason)")
        case nil:
            return nil
        }
    }

    /// docs/OAUTH-SETUP.md, bundled by scripts/build-app.sh; without it (a `swift run` build) Google's guide to
    /// desktop OAuth clients, the step most people need.
    static func openSetupGuide() {
        if let guide = Bundle.main.url(forResource: "OAUTH-SETUP", withExtension: "md") {
            NSWorkspace.shared.open(guide)
        } else if let url = URL(string: "https://developers.google.com/identity/protocols/oauth2/native-app") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// “Saved” beside Save, from a successful save until the next edit: a status, not a banner (§5.40).
struct OAuthSavedStatus: View {
    var body: some View {
        let s = Quire.Layout.Settings.self
        HStack(spacing: s.statusGlyphGap) {
            if let glyph = QuireSymbol.image(Quire.Icon.success, size: .custom(s.statusGlyph)) {
                Image(nsImage: glyph)
                    .renderingMode(.template)
                    .foregroundStyle(Color.qSuccess)
            }
            Text("Saved")
                .font(.quire(.snippet))
                .tracking(QuireFont.Role.snippet.tracking)
                .foregroundStyle(Color.qInk2)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Saved")
    }
}
