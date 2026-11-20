import SSCore
import SSDesign
import SwiftUI

/// Settings › AI (spec §5.40, §5.56): on General's grid, a fifth tab after Appearance that never scrolls. Provider (Off,
/// then by where mail goes: Anthropic's Claude with an API key or Claude Code with the user's sign-in, OpenAI's API or
/// Codex), its status line, the API key (Check, Remove) or the CLI (Choose…), the model, then the caption that says where
/// a conversation goes and when, and the permission the consent sheet recorded, with Forget.
struct AISettingsView: View {
    static let offCaption = "Off: Help Me Write sends nothing anywhere. Choose a provider to draft replies with \u{2318}J."

    @ObservedObject var model: AISettingsModel

    var body: some View {
        QuireSettingsGrid {
            QuireSettingsRow("Provider") {
                QuirePopup("Provider", selection: provider, sections: Self.providerSections) { Self.title(for: $0) }
            }
            if model.provider != nil {
                QuireSettingsRow(nil) { AIStatusLine(status: model.status) }
            }
            if let kind = model.provider {
                if kind.usesAPIKey {
                    QuireSettingsRow("API key") { keyControls }
                    if let failure = model.keyFailure {
                        QuireSettingsCaption(failure, isError: true)
                    }
                }
                if kind.executableName != nil {
                    QuireSettingsRow("Command") { cliControls(kind) }
                }
                QuireSettingsRow("Model") {
                    QuirePopup("Model", selection: modelChoice, options: model.modelChoices.map(\.model)) { choice in
                        model.modelChoices.first { $0.model == choice }?.title ?? "Default"
                    }
                }
                QuireSettingsDivider()
                if let caption = model.caption {
                    // The permission line sits a little apart: it is about this Mac's answer, not where mail goes.
                    QuireSettingsCaption(caption, spacingBelow: model.hasConsent ? Self.permissionGap : 0)
                }
                if model.hasConsent {
                    QuireSettingsCaption(AISettingsModel.permissionWords + " \u{00b7}", link: ("Forget", { model.forgetConsent() }))
                }
            } else {
                QuireSettingsCaption(Self.offCaption)
            }
        }
        .settingsTabContent()
        .onAppear { model.refresh() }
        .onDisappear { model.commitKey() }
    }

    private var keyControls: some View {
        let s = Quire.Layout.Settings.self
        return HStack(spacing: s.statusButtonGap) {
            QuireSecureField("API key", text: $model.keyText, prompt: model.keyPrompt, onCommit: { model.commitKey() })
                .frame(width: Self.keyFieldWidth)
            Button("Check") { model.check() }
                .buttonStyle(.quire(.secondary, size: .small))
                .disabled(!model.hasKey)
            if model.hasKey {
                Button("Remove") { model.removeKey() }
                    .buttonStyle(.quire(.ghost, size: .small))
            }
        }
    }

    private func cliControls(_ kind: AIProviderKind) -> some View {
        let s = Quire.Layout.Settings.self
        let path = model.cliPath.map(AISettingsModel.displayPath)
        return HStack(spacing: s.statusButtonGap) {
            Text(path ?? "Not found")
                .font(.quire(path == nil ? .snippet : .mono))
                .foregroundStyle(path == nil ? Color.qInk3 : Color.qInk2)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(path ?? "")
                .accessibilityLabel(path.map { "\(kind.displayName) at \($0)" } ?? "\(kind.displayName) not found")
            Button("Choose\u{2026}") { model.chooseCLI() }
                .buttonStyle(.quire(.secondary, size: .small))
        }
    }

    /// “Permission given · Forget” under the caption (§5.40).
    static let permissionGap = Quire.Layout.Settings.aiPermissionGap

    /// The key field leaves room for Check and Remove inside the field column.
    static let keyFieldWidth = Quire.Layout.Settings.aiKeyFieldWidth

    // MARK: Choices

    static let providerSections: [(title: String?, options: [AIProviderKind?])] = [
        (nil, [nil]),
        (AIDestination.anthropic.displayName, [.claudeAPI, .claudeCode]),
        (AIDestination.openAI.displayName, [.openAIAPI, .codex]),
    ]

    static func title(for kind: AIProviderKind?) -> String {
        switch kind {
        case nil: return "Off"
        case .claudeAPI?: return "Claude (API key)"
        case .claudeCode?: return "Claude Code (your sign-in)"
        case .openAIAPI?: return "OpenAI (API key)"
        case .codex?: return "Codex (your sign-in)"
        case .demo?: return "Demo"
        }
    }

    private var provider: Binding<AIProviderKind?> {
        Binding(get: { model.provider }, set: { model.setProvider($0) })
    }

    private var modelChoice: Binding<String?> {
        Binding(get: { model.model }, set: { model.setModel($0) })
    }
}

/// The status line under Provider (§5.40): the account rows' status shape, a glyph and the words. Ready in `ink2` with
/// the success check; needs setup in `ink2` with the warning glyph in `warning`; unavailable with the error glyph;
/// checking with a spinner.
struct AIStatusLine: View {
    let status: AISettingsModel.Status

    var body: some View {
        let s = Quire.Layout.Settings.self
        HStack(spacing: s.statusGlyphGap) {
            switch status {
            case .checking:
                QuireSpinner(.small, color: .qInk3, delay: 0)
            case .ready:
                glyph(Quire.Icon.success, color: .qSuccess)
            case .needsSetup:
                glyph(Quire.Icon.warning, color: .qWarning)
            case .unavailable:
                glyph(Quire.Icon.error, color: .qInk3)
            case .none:
                EmptyView()
            }
            Text(status.words ?? "")
                .font(.quire(.snippet))
                .tracking(QuireFont.Role.snippet.tracking)
                .foregroundStyle(.qInk2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: s.fieldWidth, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.words ?? "")
    }

    private func glyph(_ name: String, color: Color) -> some View {
        Group {
            if let image = QuireSymbol.image(name, size: .custom(Quire.Layout.Settings.statusGlyph)) {
                Image(nsImage: image).renderingMode(.template).foregroundStyle(color)
            }
        }
    }
}
