import AppKit
import Combine
import SSAI
import SSCore

/// Help Me Write's half in the app (spec §5.56): one per `AppEnvironment`, holding the `AIWriter` the UI writes through,
/// the API-key store Settings › AI writes, and where the provider choice and the permission given in Settings › AI are
/// read. The reply's sessions (`WriteSession`) and Settings › AI reach it; nothing else does. Nothing here reaches beyond
/// this Mac until the user presses Write or Check (spec §3b): the Write control's state comes from local facts only.
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
    /// Demo mode: a Turn On here stands only for the demo, and the privacy sheet says nothing leaves the Mac.
    let isDemo: Bool
    /// What the demo writer writes, how fast, and what it was asked (demo and scratch environments only).
    let demoScript: DemoAIScript?
    /// Whether the demo routes Claude Code and Codex to the real CLIs (`--live-ai-clis`, a debug aid for checking them
    /// against made-up mail). The privacy sheet then says where the conversation goes, as in the app.
    let routesCLIsToThisMac: Bool
    private let resolve: AIWriter.Resolve
    /// Ends the CLIs this environment started, at once (`CLIProcessRunner.endAll`): the app is quitting or the
    /// environment is going away, and a CLI must not outlive it with a conversation in hand.
    private let endProcesses: @Sendable () async -> Void

    /// The settings the provider choice and the permission are read from and written to: the window's.
    weak var settings: AppSettings? {
        didSet { observeSettings() }
    }
    /// Snapshots: a provider and an Allow held in memory, never saved, so a render neither needs nor changes the user's.
    var configurationOverride: AIProviderConfiguration?
    var consentOverride: Set<AIProviderKind> = []
    /// Snapshots: Help Me Write shows as off whatever Settings › AI chose.
    var forcesOff = false
    /// Settings… on a Write line: Settings › AI. The app delegate sets it.
    var openSettings: () -> Void = {}
    /// Shows Settings › AI's privacy sheet; the app's tests replace it to answer it.
    var presentAlert: (AppAlert, NSWindow?, @escaping AppAlert.Completion) -> Void = { alert, window, done in
        alert.present(on: window, completion: done)
    }

    /// The service the reply writes through. Its permission check reads this object, so no path sends without a Turn On.
    private(set) lazy var writer = AIWriter(
        resolve: resolve,
        hasConsent: { [weak self] kind in self?.hasConsent(for: kind) ?? false },
        milestones: { [weak self] milestone, kind in
            // Names from the code only: what happened, and with which kind of provider.
            CrashReporting.breadcrumb(.ai, milestone.breadcrumbName)
            CrashReporting.breadcrumb(.ai, kind.breadcrumbName)
            if let signal = self?.analyticsSignal(milestone, kind) { Analytics.send(signal) }
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

    // MARK: What the Write control shows

    /// Posted (object: this) when what the Write control shows may have changed: the provider, its permission, a key, a
    /// CLI chosen. Hosts read `availability()` again.
    static let availabilityDidChange = Notification.Name("HelpMeWrite.availabilityDidChange")

    private var settingsObservation: AnyCancellable?

    private func observeSettings() {
        settingsObservation = settings?.objectWillChange.sink { [weak self] _ in
            // `objectWillChange` fires before the change lands: read it on the next turn.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.availabilityChanged() } }
        }
    }

    /// Tells the hosts to read `availability()` again.
    func availabilityChanged() {
        NotificationCenter.default.post(name: Self.availabilityDidChange, object: self)
    }

    /// The reason a provider chosen but never turned on cannot write (§5.56).
    static let turnOnWords = "Turn it on in Settings \u{203a} AI"
    /// What ⌘J says while Help me write is off.
    static let offWords = "Help Me Write is off"

    /// Whether the reply can be written in now, from this Mac's facts alone (spec §3b): a provider chosen and turned on,
    /// a key stored or a CLI found at a version this build runs. No network, no process.
    func availability() -> WriteToolControl.Availability {
        guard let configuration else { return .off }
        let kind = configuration.kind
        guard hasConsent(for: kind) else { return .unavailable(reason: Self.turnOnWords) }
        let health = writer.localHealth(of: configuration)
        guard health.isReady else { return .unavailable(reason: health.words) }
        return .ready(writer: writerName(for: kind), source: sourceLine(for: configuration))
    }

    /// What the last Check found, for this run: Settings › AI shows it again as it reopens rather than asking the provider
    /// again, which only the Check button does.
    private(set) var checkedHealth: [AIProviderConfiguration: AIHealth] = [:]

    func rememberCheck(_ health: AIHealth, for configuration: AIProviderConfiguration) {
        checkedHealth[configuration] = health
    }

    /// A key or a CLI changed: what was checked no longer holds.
    func forgetCheck(for kind: AIProviderKind) {
        checkedHealth = checkedHealth.filter { $0.key.kind != kind }
        availabilityChanged()
    }

    /// Who writes, in the Write line's words: “Writing with Claude…”, “Written by Claude”. The demo's writer is the demo,
    /// never a model (§5.56).
    func writerName(for kind: AIProviderKind) -> String {
        if makesUpReplies(for: kind) { return "the demo" }
        switch kind {
        case .claudeAPI, .claudeCode: return "Claude"
        case .openAIAPI, .codex: return "GPT"
        case .demo: return "the demo"
        }
    }

    // MARK: Choice and permission

    /// What Settings › AI chose, or nil while Help Me Write is off.
    var configuration: AIProviderConfiguration? {
        forcesOff ? nil : configurationOverride ?? settings?.aiConfiguration(demo: isDemo)
    }

    /// Whether a conversation may go to `kind`: the user turned it on in Settings › AI, past its privacy sheet (in the
    /// demo, in the demo, and for a CLI the demo runs for real, on that CLI's own sheet). The demo writer itself needs
    /// nothing, since nothing leaves the Mac.
    func hasConsent(for kind: AIProviderKind) -> Bool {
        if kind == .demo || consentOverride.contains(kind) { return true }
        return settings?.hasAIConsent(for: kind, demo: isDemo, live: sendsFromTheDemo(kind)) ?? false
    }

    /// The privacy sheet's Turn On, kept where it was given: a Turn On on the demo's “Nothing is sent” sheet never stands
    /// for a send.
    func recordConsent(for kind: AIProviderKind) {
        settings?.setAIConsent(true, for: kind, demo: isDemo, live: sendsFromTheDemo(kind))
    }

    /// Turn Off, or another provider turned on in its place: `kind`'s permission goes.
    func withdrawConsent(for kind: AIProviderKind) {
        settings?.setAIConsent(false, for: kind, demo: isDemo, live: sendsFromTheDemo(kind))
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

    /// What Analytics hears of a write (docs/ANALYTICS-AND-REPORTS.md): one signal as it ends, from the same two closed
    /// sets as the breadcrumbs, the provider's kind and how it ended. A reply the demo makes up on this Mac is none: the
    /// demo's sheet and Settings › AI say nothing is sent, and its kind would only be the one picked in the demo.
    func analyticsSignal(_ milestone: AIWriteMilestone, _ kind: AIProviderKind) -> AnalyticsSignal? {
        guard !makesUpReplies(for: kind), let writer = AnalyticsSignal.Writer(kind),
              let ending = AnalyticsSignal.WriteEnding(milestone) else { return nil }
        return .helpMeWriteUsed(writer, ending)
    }

    /// The source line in the demo, where no model writes: what is shown is attributed truthfully (§5.56).
    static let demoSourceLine = "Demo \u{00b7} made up on this Mac"

    /// The source line for `configuration` (the Write control's tooltips): the model and its company, or the demo's when
    /// the demo writes.
    func sourceLine(for configuration: AIProviderConfiguration) -> String {
        makesUpReplies(for: configuration.kind) ? Self.demoSourceLine : configuration.sourceLine
    }

    /// Settings › AI's privacy sheet for `kind`: the demo's says nothing leaves the Mac, unless its CLIs run for real.
    func turnOnAlert(for kind: AIProviderKind) -> AppAlert {
        AppAlert.helpMeWriteTurnOn(kind, demo: makesUpReplies(for: kind))
    }
}
