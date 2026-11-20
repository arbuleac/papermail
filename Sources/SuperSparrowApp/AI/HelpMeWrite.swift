import AppKit
import SSAI
import SSCore

/// Help Me Write's half in the app (spec §5.55): one per `AppEnvironment`, holding the `AIWriter` the UI writes through,
/// the API-key store Settings › AI writes, and where the provider choice and the user's consent are read. The card
/// (`WriteSession`) and Settings › AI reach it; nothing else does, and nothing here runs until the user presses Write.
///
/// The real environment resolves providers through `AIProviderFactory` with the Keychain; the demo and the app's tests
/// resolve every provider to the demo writer, which writes canned replies on this Mac (`DemoAIProvider`).
@MainActor
final class HelpMeWrite {
    /// The environment on screen's: the reader and composers reach it here. The main window sets it as it is built, so a
    /// demo built beside the user's mailbox during a sign-in never takes it before it shows.
    static weak var current: HelpMeWrite?

    /// API keys: the Keychain in the app, memory in the demo and tests (`InMemoryAIKeyStore`).
    let keys: any AIKeyStoring
    /// Demo mode: an Allow here stands only for the demo, and the consent sheet says nothing leaves the Mac.
    let isDemo: Bool
    /// What the demo writer writes, how fast, and what it was asked (demo and scratch environments only).
    let demoScript: DemoAIScript?
    /// Whether the demo routes Claude Code and Codex to the real CLIs (`--live-ai-clis`, a debug aid for checking them
    /// against made-up mail). The consent sheet then says where the conversation goes, as in the app.
    let routesCLIsToThisMac: Bool
    private let resolve: AIWriter.Resolve
    /// Ends the CLIs this environment started, at once (`CLIProcessRunner.endAll`): the app is quitting or the
    /// environment is going away, and a CLI must not outlive it with a conversation in hand.
    private let endProcesses: @Sendable () async -> Void

    /// The settings the provider choice and the consent are read from and written to: the window's.
    weak var settings: AppSettings?
    /// Snapshots: a provider and an Allow held in memory, never saved, so a render neither needs nor changes the user's.
    var configurationOverride: AIProviderConfiguration?
    var consentOverride: Set<AIProviderKind> = []
    /// Snapshots: Help Me Write shows as off whatever Settings › AI chose.
    var forcesOff = false
    /// Open Settings… on the card: Settings › AI. The app delegate sets it.
    var openSettings: () -> Void = {}
    /// Shows the consent sheet; the app's tests replace it to answer it.
    var presentAlert: (AppAlert, NSWindow?, @escaping AppAlert.Completion) -> Void = { alert, window, done in
        alert.present(on: window, completion: done)
    }

    /// The service the card writes through. Its consent check reads this object, so no path can send without an Allow.
    private(set) lazy var writer = AIWriter(
        resolve: resolve,
        hasConsent: { [weak self] kind in self?.hasConsent(for: kind) ?? false },
        milestones: { milestone, kind in
            // Names from the code only: what happened, and with which kind of provider.
            CrashReporting.breadcrumb(.ai, milestone.breadcrumbName)
            CrashReporting.breadcrumb(.ai, kind.breadcrumbName)
        }
    )

    init(keys: any AIKeyStoring, isDemo: Bool, demoScript: DemoAIScript?, routesCLIsToThisMac: Bool = false,
         endProcesses: @escaping @Sendable () async -> Void = {}, resolve: @escaping AIWriter.Resolve) {
        self.keys = keys
        self.isDemo = isDemo
        self.demoScript = demoScript
        self.routesCLIsToThisMac = routesCLIsToThisMac
        self.endProcesses = endProcesses
        self.resolve = resolve
    }

    /// The app's: the providers Settings › AI offers, with API keys in the Keychain.
    static func real() -> HelpMeWrite {
        let keys = AIKeyStore()
        let factory = AIProviderFactory(keys: keys)
        let runner = factory.runner
        return HelpMeWrite(keys: keys, isDemo: false, demoScript: nil, endProcesses: { await runner.endAll() }) {
            factory.provider(for: $0)
        }
    }

    /// The demo's and the app tests': every provider writes canned replies on this Mac. With `liveCLIs` (a debug
    /// launch option for checking the CLIs against made-up mail), Claude Code and Codex run for real.
    static func demo(isDemo: Bool, liveCLIs: Bool = false) -> HelpMeWrite {
        let script = DemoAIScript()
        let keys = InMemoryAIKeyStore()
        let factory = liveCLIs ? AIProviderFactory(keys: keys) : nil
        let runner = factory?.runner
        return HelpMeWrite(keys: keys, isDemo: isDemo, demoScript: script, routesCLIsToThisMac: liveCLIs,
                           endProcesses: { await runner?.endAll() }) { configuration in
            if let factory, configuration.kind == .claudeCode || configuration.kind == .codex {
                return factory.provider(for: configuration)
            }
            return DemoAIProvider(script: script)
        }
    }

    /// The environment is going away: every write stops, none starts after this (a card still building what it sends
    /// ends as stopped), and every CLI it started has ended before this returns; the runner starts no other.
    func shutdown() async {
        writer.shutDown()
        await endProcesses()
    }

    // MARK: Choice and consent

    /// What Settings › AI chose, or nil while Help Me Write is off.
    var configuration: AIProviderConfiguration? {
        forcesOff ? nil : configurationOverride ?? settings?.aiConfiguration(demo: isDemo)
    }

    /// Whether a conversation may go to `kind`: the user allowed it (in the demo, in the demo, and for a CLI the demo runs
    /// for real, on that CLI's own sheet). The demo writer itself needs nothing, since nothing leaves the Mac.
    func hasConsent(for kind: AIProviderKind) -> Bool {
        if kind == .demo || consentOverride.contains(kind) { return true }
        return settings?.hasAIConsent(for: kind, demo: isDemo, live: sendsFromTheDemo(kind)) ?? false
    }

    /// The consent sheet's Allow, kept where it was given: an Allow on the demo's “Nothing is sent” sheet never stands for
    /// a send.
    func recordConsent(for kind: AIProviderKind) {
        settings?.setAIConsent(true, for: kind, demo: isDemo, live: sendsFromTheDemo(kind))
    }

    /// The demo sends the conversation with `kind`: one of its CLIs run for real (`--live-ai-clis`). Its Allows are kept
    /// apart from the made-up demo's (`AppSettings.liveDemoAIConsent`).
    func sendsFromTheDemo(_ kind: AIProviderKind) -> Bool {
        isDemo && !makesUpReplies(for: kind)
    }

    /// Whether a write with `kind` is made up on this Mac by the demo's writer: in the demo, unless its CLIs run for
    /// real (`--live-ai-clis`).
    func makesUpReplies(for kind: AIProviderKind) -> Bool {
        isDemo && !(routesCLIsToThisMac && (kind == .claudeCode || kind == .codex))
    }

    /// The card's source line in the demo, where no model writes: what is shown is attributed truthfully (§5.55).
    static let demoSourceLine = "Demo \u{00b7} made up on this Mac"

    /// The card's source line for `configuration`: the model and its company, or the demo's when the demo writes.
    func sourceLine(for configuration: AIProviderConfiguration) -> String {
        makesUpReplies(for: configuration.kind) ? Self.demoSourceLine : configuration.sourceLine
    }

    /// The consent sheet for `kind`: the demo's says nothing leaves the Mac, unless its CLIs run for real.
    func consentAlert(for kind: AIProviderKind) -> AppAlert {
        AppAlert.helpMeWriteConsent(kind, demo: makesUpReplies(for: kind))
    }
}
