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
         resolve: @escaping AIWriter.Resolve) {
        self.keys = keys
        self.isDemo = isDemo
        self.demoScript = demoScript
        self.routesCLIsToThisMac = routesCLIsToThisMac
        self.resolve = resolve
    }

    /// The app's: the providers Settings › AI offers, with API keys in the Keychain.
    static func real() -> HelpMeWrite {
        let keys = AIKeyStore()
        let factory = AIProviderFactory(keys: keys)
        return HelpMeWrite(keys: keys, isDemo: false, demoScript: nil) { factory.provider(for: $0) }
    }

    /// The demo's and the app tests': every provider writes canned replies on this Mac. With `liveCLIs` (a debug
    /// launch option for checking the CLIs against made-up mail), Claude Code and Codex run for real.
    static func demo(isDemo: Bool, liveCLIs: Bool = false) -> HelpMeWrite {
        let script = DemoAIScript()
        let keys = InMemoryAIKeyStore()
        let factory = liveCLIs ? AIProviderFactory(keys: keys) : nil
        return HelpMeWrite(keys: keys, isDemo: isDemo, demoScript: script, routesCLIsToThisMac: liveCLIs) { configuration in
            if let factory, configuration.kind == .claudeCode || configuration.kind == .codex {
                return factory.provider(for: configuration)
            }
            return DemoAIProvider(script: script)
        }
    }

    // MARK: Choice and consent

    /// What Settings › AI chose, or nil while Help Me Write is off.
    var configuration: AIProviderConfiguration? {
        forcesOff ? nil : configurationOverride ?? settings?.aiConfiguration
    }

    /// Whether a conversation may go to `kind`: the user allowed it (in the demo, in the demo). The demo writer itself
    /// needs nothing, since nothing leaves the Mac.
    func hasConsent(for kind: AIProviderKind) -> Bool {
        if kind == .demo || consentOverride.contains(kind) { return true }
        return settings?.hasAIConsent(for: kind, demo: isDemo) ?? false
    }

    /// The consent sheet's Allow.
    func recordConsent(for kind: AIProviderKind) {
        settings?.setAIConsent(true, for: kind, demo: isDemo)
    }

    /// The consent sheet for `kind`: the demo's says nothing leaves the Mac, unless its CLIs run for real.
    func consentAlert(for kind: AIProviderKind) -> AppAlert {
        let sendsNothing = isDemo && !(routesCLIsToThisMac && (kind == .claudeCode || kind == .codex))
        return AppAlert.helpMeWriteConsent(kind, demo: sendsNothing)
    }
}
