import AppKit
import Combine
import SSAI
import SSCore

/// Settings › AI (spec §5.40, §5.56): which provider Help Me Write uses, whether it can write now, its API key or CLI,
/// and its model. Choosing a provider shows its privacy sheet at that moment: Turn On keeps the choice and gives it
/// permission, Cancel puts the popup back, Off withdraws it. A provider chosen before 1.12 and never turned on says so,
/// with Turn On….
///
/// Nothing here reaches a provider unless the user presses Check or saves a key (spec §3b): the status as the tab opens
/// or the provider changes comes from this Mac (a key's presence by its attributes alone, the CLI's file and the version
/// its path names), and the API key's data is read only by Check (reading it can show the Keychain prompt).
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
    /// The status line of a provider chosen but never turned on (one chosen before 1.12).
    static let notTurnedOnWords = "Not turned on yet"

    @Published private(set) var provider: AIProviderKind?
    @Published private(set) var status: Status = .none
    /// Whether the chosen API provider has a key in the Keychain (read without its data).
    @Published private(set) var hasKey = false
    /// What is typed in the key field: never the stored key, which is not read back into Settings.
    @Published var keyText = ""
    @Published private(set) var keyFailure: String?
    /// The chosen provider has its permission (its privacy sheet's Turn On).
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

    /// The window the privacy sheet goes on: Settings'. The Settings window sets it.
    var window: () -> NSWindow? = { nil }

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

    /// The caption under the rows: what is sent, when, and how to stop it. Nil while Help Me Write is off. In the demo,
    /// whose writer makes replies up on the Mac, it says nothing goes anywhere.
    var caption: String? {
        guard let provider else { return nil }
        if center.makesUpReplies(for: provider) { return Self.demoCaption }
        return "Only when you press Write, the conversation you\u{2019}re replying to and your notes go to "
            + "\(provider.destination.displayName). Choose Off to stop."
    }

    /// The chosen provider was never turned on (chosen before 1.12): it writes nothing until its sheet's Turn On.
    var needsTurnOn: Bool { provider != nil && !hasConsent }

    static let demoCaption = "In the demo, Help Me Write makes replies up on this Mac. Nothing is sent."

    /// The key field's placeholder: where a stored key is, without reading it.
    var keyPrompt: String { hasKey ? Self.keySavedPrompt : Self.keyPrompt }

    /// The tab opened, or came back: the key's presence, the permission, the CLI and the provider's state, from this Mac.
    func refresh() {
        guard !isSnapshot else { return }
        provider = settings.aiProvider(demo: center.isDemo)
        readState()
        showLocalHealth()
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

    /// The provider's state from this Mac alone (no network, no process), or what this run's last Check found for it.
    private func showLocalHealth() {
        healthTask?.cancel()
        generation += 1
        guard let configuration else {
            status = .none
            return
        }
        if needsTurnOn {
            status = .needsSetup(Self.notTurnedOnWords)
            return
        }
        status = Status(center.checkedHealth[configuration] ?? center.writer.localHealth(of: configuration))
    }

    /// Check, or a key just saved: the provider's own check (the models list, which sends the key and nothing else; the
    /// CLI's version and sign-in), for the user's `action`, the one place Settings reaches beyond this Mac.
    private func runCheck(_ action: AIUserAction) {
        healthTask?.cancel()
        generation += 1
        let mine = generation
        guard let configuration else {
            status = .none
            return
        }
        status = .checking
        let center = center
        healthTask = Task { [weak self] in
            let health = await center.writer.check(configuration, action: action)
            guard let self, self.generation == mine, !Task.isCancelled else { return }
            center.rememberCheck(health, for: configuration)
            self.status = self.needsTurnOn ? .needsSetup(Self.notTurnedOnWords) : Status(health)
        }
    }

    // MARK: Changing

    /// The Provider popup. A provider shows its privacy sheet first (§5.40): Turn On keeps it and gives it permission,
    /// withdrawing the one it replaces; Cancel puts the popup back as it was. Off withdraws the permission at once.
    func setProvider(_ kind: AIProviderKind?) {
        guard kind != provider, kind != .demo, !isAsking else {
            objectWillChange.send()
            return
        }
        guard !isSnapshot else {
            choose(kind)
            return
        }
        guard let kind else {
            if let previous = provider { center.withdrawConsent(for: previous) }
            choose(nil)
            return
        }
        // Cancel must find the popup as it was: it shows the old choice until Turn On.
        objectWillChange.send()
        askToTurnOn(kind) { [weak self] turnedOn in
            guard let self, turnedOn else { return }
            if let previous = self.provider, previous != kind { self.center.withdrawConsent(for: previous) }
            self.choose(kind)
        }
    }

    /// Turn On… beside a provider chosen but never turned on: its sheet, as if it were chosen now.
    func turnOnChosenProvider() {
        guard let provider, needsTurnOn, !isSnapshot else { return }
        askToTurnOn(provider) { [weak self] _ in
            self?.readState()
            self?.showLocalHealth()
        }
    }

    /// The privacy sheet is up: the popup and Turn On… wait for its answer.
    @Published private(set) var isAsking = false

    private func askToTurnOn(_ kind: AIProviderKind, then done: @escaping @MainActor (Bool) -> Void) {
        isAsking = true
        center.presentAlert(center.turnOnAlert(for: kind), window()) { [weak self] choice in
            guard let self else { return }
            self.isAsking = false
            let turnedOn = choice == 1
            if turnedOn { self.center.recordConsent(for: kind) }
            self.objectWillChange.send()
            done(turnedOn)
        }
    }

    private func choose(_ kind: AIProviderKind?) {
        provider = kind
        keyText = ""
        if !isSnapshot { settings.setAIProvider(kind, demo: center.isDemo) }
        readState()
        showLocalHealth()
        center.availabilityChanged()
    }

    func setModel(_ model: String?) {
        guard let provider, !isSnapshot else { return }
        settings.setAIModel(model == provider.defaultModel ? nil : model, for: provider, demo: center.isDemo)
        objectWillChange.send()
        showLocalHealth()
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
            center.forgetCheck(for: provider)
            // Saving a key is the user's own act of setting it up: the key, and nothing else, is checked with the provider.
            runCheck(AIUserAction(userPressed: .check))
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
            center.forgetCheck(for: provider)
            showLocalHealth()
        } catch {
            keyFailure = "Couldn\u{2019}t remove the key from your Keychain."
        }
    }

    /// Check: the provider's cheapest authenticated call, or the CLI's version and sign-in.
    func check() {
        guard !isSnapshot else { return }
        runCheck(AIUserAction(userPressed: .check))
    }

    /// Choose…: another CLI, which Help Me Write runs from then on.
    func chooseCLI() {
        guard let provider, provider.executableName != nil, !isSnapshot else { return }
        chooseExecutable(provider) { [weak self] url in
            guard let self, let url, self.provider == provider else { return }
            self.settings.setAICLIPath(url.path, for: provider, demo: self.center.isDemo)
            self.center.forgetCheck(for: provider)
            self.readState()
            self.showLocalHealth()
        }
    }

    // MARK: Snapshots

    /// Shows a state for a snapshot, writing nothing: the provider, its status line, a stored key and the permission.
    func showForSnapshot(provider: AIProviderKind?, status: Status, hasKey: Bool = false, hasConsent: Bool = true, cliPath: String? = nil) {
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
