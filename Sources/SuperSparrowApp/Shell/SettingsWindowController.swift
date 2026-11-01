import AppKit
import SSCore
import SwiftUI

/// What the settings window shows and does. The app delegate supplies the account actions, since sign-in
/// and removal go through the engine and may show alerts.
@MainActor
final class SettingsModel: ObservableObject {
    enum Tab: Hashable {
        case accounts
        case oauth
        case general
    }

    @Published var tab: Tab = .accounts
    @Published var accounts: [Account] = []
    @Published var statuses: [AccountID: AccountSyncStatus] = [:]
    @Published var oauth = OAuthClientFile()
    @Published var oauthNotice: String?
    @Published var oauthSaved = false
    @Published var busyMessage: String?

    let isDemo: Bool
    let oauthFileURL: URL
    var addAccount: (ProviderKind) -> Void = { _ in }
    var removeAccount: (Account) -> Void = { _ in }
    var reconnect: (Account) -> Void = { _ in }

    init(isDemo: Bool, oauthFileURL: URL) {
        self.isDemo = isDemo
        self.oauthFileURL = oauthFileURL
        oauth = OAuthClientFile.load(from: oauthFileURL)
    }

    func saveOAuth() {
        do {
            try oauth.save(to: oauthFileURL)
            oauthSaved = true
            oauthNotice = nil
        } catch {
            oauthSaved = false
            oauthNotice = "Couldn't save \(oauthFileURL.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func reloadOAuth() {
        oauth = OAuthClientFile.load(from: oauthFileURL)
        oauthSaved = false
    }

    func statusText(for account: Account) -> String {
        guard let status = statuses[account.id] else { return "Waiting to sync" }
        switch status.phase {
        case .idle:
            if let date = status.lastSuccessfulSyncAt {
                return "Up to date · " + date.formatted(date: .omitted, time: .shortened)
            }
            return "Up to date"
        case .bootstrapping:
            return status.bootstrapProgress.map { "Downloading · \($0) messages" } ?? "Downloading…"
        case .syncing: return "Checking for mail…"
        case .hydrating: return "Downloading messages…"
        case .paused: return status.message ?? "Paused"
        case .needsReauth: return "Signed out — reconnect to keep syncing"
        case .error: return status.message.map { "Error: \($0)" } ?? "Error"
        }
    }
}

/// Preferences: accounts, OAuth client registrations and general behavior.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel
    private var statusObservation: StoreObservation?
    private let environment: AppEnvironment

    init(environment: AppEnvironment, settings: AppSettings) {
        self.environment = environment
        model = SettingsModel(isDemo: environment.isDemo, oauthFileURL: environment.clientConfigurations.fileURL)
        let hosting = NSHostingController(rootView: SettingsView(model: model, settings: settings))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 420))
        super.init(window: window)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("Settings")
        refreshAccounts()
        statusObservation = environment.engine.observeStatus { [weak self] statuses in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.model.statuses = Dictionary(statuses.map { ($0.accountID, $0) }, uniquingKeysWith: { first, _ in first })
                self.refreshAccounts()
            }
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    func tearDown() {
        statusObservation?.cancel()
        statusObservation = nil
        window?.orderOut(nil)
    }

    func refreshAccounts() {
        let fresh = ((try? environment.store.accounts()) ?? []).sorted { $0.addedAt < $1.addedAt }
        if fresh != model.accounts { model.accounts = fresh }
    }

    func show(tab: SettingsModel.Tab? = nil, notice: String? = nil) {
        if let tab { model.tab = tab }
        if tab == .oauth {
            model.reloadOAuth()
            model.oauthNotice = notice
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

// MARK: - SwiftUI

struct SettingsView: View {
    @ObservedObject var model: SettingsModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        TabView(selection: $model.tab) {
            AccountsSettingsView(model: model)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
                .tag(SettingsModel.Tab.accounts)
            OAuthSettingsView(model: model)
                .tabItem { Label("OAuth", systemImage: "key") }
                .tag(SettingsModel.Tab.oauth)
            GeneralSettingsView(settings: settings)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsModel.Tab.general)
        }
        .padding(16)
        .frame(width: 560, height: 420)
    }
}

private struct AccountsSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if model.isDemo {
                Text("Demo mode: these mailboxes are made up and live only on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.accounts.isEmpty {
                Spacer()
                Text("No accounts yet. Add one to start syncing.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                List {
                    ForEach(model.accounts) { account in
                        AccountRow(model: model, account: account)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
            HStack(spacing: 8) {
                Button("Add Gmail Account…") { model.addAccount(.gmail) }
                Button("Add Microsoft Account…") { model.addAccount(.microsoft) }
                Spacer()
                if let busy = model.busyMessage {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(model.busyMessage != nil)
        }
        .padding(8)
    }
}

private struct AccountRow: View {
    @ObservedObject var model: SettingsModel
    let account: Account

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(nsColor: NSColor(hexString: account.colorHex) ?? .systemGray))
                .frame(width: 24, height: 24)
                .overlay(Text(AccountStripViewController.initials(for: account)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 2) {
                Text(account.email).font(.body)
                Text("\(account.kind == .gmail ? "Gmail" : "Microsoft") · \(model.statusText(for: account))")
                    .font(.caption)
                    .foregroundStyle(model.statuses[account.id]?.phase == .needsReauth ? Color.red : Color.secondary)
            }
            Spacer()
            if model.statuses[account.id]?.phase == .needsReauth {
                Button("Reconnect") { model.reconnect(account) }
            }
            Button("Remove…") { model.removeAccount(account) }
        }
        .padding(.vertical, 4)
    }
}

private struct OAuthSettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            if let notice = model.oauthNotice {
                Text(notice)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Google (Gmail)") {
                TextField("Client ID", text: $model.oauth.googleClientID, prompt: Text("….apps.googleusercontent.com"))
                SecureField("Client secret", text: $model.oauth.googleClientSecret)
            }
            Section("Microsoft (Microsoft 365 and Outlook.com)") {
                TextField("Client ID", text: $model.oauth.microsoftClientID, prompt: Text("00000000-0000-0000-0000-000000000000"))
                TextField("Tenant", text: $model.oauth.microsoftTenant, prompt: Text("common"))
            }
            Section {
                Text("Register your own OAuth clients: a **Desktop app** client in Google Cloud Console with the Gmail API enabled, and a **Mobile and desktop** app in Microsoft Entra with `http://localhost` as redirect URI. Step-by-step instructions are in docs/OAUTH-SETUP.md.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show File in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([model.oauthFileURL])
                    }
                    .disabled(!FileManager.default.fileExists(atPath: model.oauthFileURL.path))
                    Spacer()
                    if model.oauthSaved {
                        Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    Button("Save") { model.saveOAuth() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.oauth) { model.oauthSaved = false }
    }
}

private struct GeneralSettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Notifications") {
                Toggle("Notify me about new mail", isOn: $settings.notificationsEnabled)
                Toggle("Show sender and subject in notifications", isOn: $settings.showPreviews)
                    .disabled(!settings.notificationsEnabled)
            }
            Section("Reading") {
                Toggle("Load remote images by default", isOn: $settings.loadRemoteImages)
                Text("Remote images can tell senders when you open a message. Applies to messages downloaded after you change it and after a relaunch.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Sending") {
                Picker("Undo send", selection: $settings.undoSendDelay) {
                    ForEach(AppSettings.undoSendChoices, id: \.self) { seconds in
                        Text("\(Int(seconds)) seconds").tag(seconds)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
