import AppKit
import Combine
import SSAI
import SSCore

/// Settings › AI (spec §5.40, §5.55): which provider Help Me Write uses, whether it can write now, its API key or CLI,
/// its model, and the permission the consent sheet recorded. The provider's health is asked when the tab opens and when
/// the provider changes, never at launch; the API key's data is read only by Check (reading it can show the Keychain
/// prompt), its presence by its attributes alone.
@MainActor
final class AISettingsModel: ObservableObject {
    /// The status line under Provider.
    enum Status: Equatable {
        case none
        case checking
        case ready(String)
        case needsSetup(String)
        case unavailable(String)

        init(_ health: AIHealth) {
            switch health {
            case .ready(let detail): self = .ready(detail)
            case .needsSetup(let reason): self = .needsSetup(reason)
            case .unavailable(let reason): self = .unavailable(reason)
            }
        }

        var words: String? {
            switch self {
            case .none: return nil
            case .checking: return "Checking\u{2026}"
            case .ready(let words), .needsSetup(let words), .unavailable(let words): return words
            }
        }

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }
    }

    static let keyPrompt = "Paste your API key"
    static let keySavedPrompt = "Saved in your Keychain"
    static let permissionWords = "Permission given"

    @Published private(set) var provider: AIProviderKind?
    @Published private(set) var status: Status = .none
    /// Whether the chosen API provider has a key in the Keychain (read without its data).
    @Published private(set) var hasKey = false
    /// What is typed in the key field: never the stored key, which is not read back into Settings.
    @Published var keyText = ""
    @Published private(set) var keyFailure: String?
    @Published private(set) var hasConsent = false
    /// The CLI shown in the CLI row: the one chosen with Choose… while it is there, else the one found in the standard
    /// folders; nil when there is none.
    @Published private(set) var cliPath: String?

    private let settings: AppSettings
    private let center: HelpMeWrite
    private var healthTask: Task<Void, Never>?
    /// Bumped by every check, so a slow answer for an earlier provider is dropped.
    private var generation = 0
    private var isSnapshot = false

    /// Shows the panel for Choose…; the app's tests answer it themselves.
    var chooseExecutable: (AIProviderKind, @escaping @MainActor (URL?) -> Void) -> Void = AISettingsModel.openPanel
    /// The CLI a provider would run for the path chosen in Settings (or none): the CLI providers' own finder, so the row
    /// shows exactly what Help Me Write runs. Tests point it elsewhere.
    var locateExecutable: (AIProviderKind, String?) -> String? = AISettingsModel.locateLikeTheProviders

    init(settings: AppSettings, center: HelpMeWrite) {
        self.settings = settings
        self.center = center
        provider = settings.aiProvider(demo: center.isDemo)
    }

    // MARK: Reading

    /// The model popup's choices and current choice for the provider.
    var modelChoices: [AIModelChoice] { provider?.modelChoices ?? [] }

    var model: String? {
        guard let provider else { return nil }
        return AIProviderConfiguration(kind: provider, model: settings.aiModel(for: provider, demo: center.isDemo)).resolvedModel
    }

    private var configuration: AIProviderConfiguration? {
        provider.map { kind in
            AIProviderConfiguration(kind: kind, model: settings.aiModel(for: kind, demo: center.isDemo),
                                    cliPath: settings.aiCLIPath(for: kind, demo: center.isDemo))
        }
    }

    /// The caption under the rows: where a conversation goes, and when. Nil while Help Me Write is off. In the demo,
    /// whose writer makes replies up on the Mac, it says nothing goes anywhere.
    var caption: String? {
        guard let provider else { return nil }
        if center.makesUpReplies(for: provider) { return Self.demoCaption }
        return "When you use Help Me Write, the conversation you\u{2019}re replying to goes to "
            + "\(provider.destination.displayName). Nothing is sent otherwise."
    }

    static let demoCaption = "In the demo, Help Me Write makes replies up on this Mac. Nothing is sent."

    /// The key field's placeholder: where a stored key is, without reading it.
    var keyPrompt: String { hasKey ? Self.keySavedPrompt : Self.keyPrompt }

    /// The tab opened, or came back: the key's presence, the permission, the CLI and the provider's health, again.
    func refresh() {
        guard !isSnapshot else { return }
        provider = settings.aiProvider(demo: center.isDemo)
        readState()
        checkHealth(deep: false)
    }

    private func readState() {
        keyFailure = nil
        if let provider, provider.usesAPIKey {
            hasKey = (try? center.keys.hasKey(for: provider)) ?? false
        } else {
            hasKey = false
        }
        hasConsent = provider.map { center.hasConsent(for: $0) && $0 != .demo } ?? false
        if let provider, provider.executableName != nil {
            cliPath = locateExecutable(provider, settings.aiCLIPath(for: provider, demo: center.isDemo))
        } else {
            cliPath = nil
        }
    }

    /// The provider's health (`deep`: the Check button's authenticated call, which sends the key and nothing else).
    private func checkHealth(deep: Bool) {
        healthTask?.cancel()
        generation += 1
        let mine = generation
        guard let configuration else {
            status = .none
            return
        }
        status = .checking
        let writer = center.writer
        healthTask = Task { [weak self] in
            let health = deep ? await writer.check(configuration) : await writer.health(of: configuration)
            guard let self, self.generation == mine, !Task.isCancelled else { return }
            self.status = Status(health)
        }
    }

    // MARK: Changing

    func setProvider(_ kind: AIProviderKind?) {
        guard kind != provider, kind != .demo else { return }
        provider = kind
        keyText = ""
        if !isSnapshot { settings.setAIProvider(kind, demo: center.isDemo) }
        readState()
        checkHealth(deep: false)
    }

    func setModel(_ model: String?) {
        guard let provider, !isSnapshot else { return }
        settings.setAIModel(model == provider.defaultModel ? nil : model, for: provider, demo: center.isDemo)
        objectWillChange.send()
        checkHealth(deep: false)
    }

    /// Return in the key field, or leaving it: what was typed is saved to the Keychain and checked. An empty field
    /// changes nothing (the stored key is never shown, so an empty field is not a cleared one; Remove clears it).
    func commitKey() {
        guard let provider, provider.usesAPIKey, !isSnapshot else { return }
        let typed = keyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        do {
            try center.keys.setKey(typed, for: provider)
            keyText = ""
            keyFailure = nil
            hasKey = true
            checkHealth(deep: true)
        } catch {
            keyFailure = "Couldn\u{2019}t save the key in your Keychain."
        }
    }

    /// Remove: the key leaves the Keychain.
    func removeKey() {
        guard let provider, provider.usesAPIKey, !isSnapshot else { return }
        do {
            try center.keys.setKey(nil, for: provider)
            keyText = ""
            keyFailure = nil
            hasKey = false
            checkHealth(deep: false)
        } catch {
            keyFailure = "Couldn\u{2019}t remove the key from your Keychain."
        }
    }

    /// Check: the provider's cheapest authenticated call.
    func check() {
        guard !isSnapshot else { return }
        checkHealth(deep: true)
    }

    /// Forget: the consent sheet asks again the next time Help Me Write is used with this provider.
    func forgetConsent() {
        guard let provider, !isSnapshot else { return }
        settings.setAIConsent(false, for: provider, demo: center.isDemo, live: center.sendsFromTheDemo(provider))
        hasConsent = false
    }

    /// Choose…: another CLI, which Help Me Write runs from then on.
    func chooseCLI() {
        guard let provider, provider.executableName != nil, !isSnapshot else { return }
        chooseExecutable(provider) { [weak self] url in
            guard let self, let url, self.provider == provider else { return }
            self.settings.setAICLIPath(url.path, for: provider, demo: self.center.isDemo)
            self.readState()
            self.checkHealth(deep: false)
        }
    }

    // MARK: Snapshots

    /// Shows a state for a snapshot, writing nothing: the provider, its status line, a stored key and the permission.
    func showForSnapshot(provider: AIProviderKind?, status: Status, hasKey: Bool = false, hasConsent: Bool = false, cliPath: String? = nil) {
        isSnapshot = true
        healthTask?.cancel()
        self.provider = provider
        self.status = provider == nil ? .none : status
        self.hasKey = hasKey
        self.hasConsent = hasConsent
        self.cliPath = cliPath
        keyText = ""
        keyFailure = nil
    }

    // MARK: The Mac

    /// The CLI's path as shown: the home folder as `~`.
    static func displayPath(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Finds CLIs only (it runs nothing): the chosen path when it is an executable file, else the first in
    /// ~/.local/bin, /opt/homebrew/bin and /usr/local/bin, read without a login shell, as the CLI providers do.
    private static let finder = CLIProcessRunner()

    static func locateLikeTheProviders(_ kind: AIProviderKind, chosen: String?) -> String? {
        locateLikeTheProviders(kind, chosen: chosen, finder: finder)
    }

    /// As above, searching `searchFolders` in place of the standard ones (the app's tests use folders of their own).
    static func locateLikeTheProviders(_ kind: AIProviderKind, chosen: String?, searchFolders: [URL]) -> String? {
        locateLikeTheProviders(kind, chosen: chosen, finder: CLIProcessRunner(searchFolders: searchFolders))
    }

    private static func locateLikeTheProviders(_ kind: AIProviderKind, chosen: String?, finder: CLIProcessRunner) -> String? {
        finder.locate(kind, chosen: chosen)?.path
    }

    private static func openPanel(_ kind: AIProviderKind, _ done: @escaping @MainActor (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the \(kind.displayName) command-line tool."
        panel.prompt = "Choose"
        panel.begin { response in
            MainActor.assumeIsolated { done(response == .OK ? panel.url : nil) }
        }
    }
}
