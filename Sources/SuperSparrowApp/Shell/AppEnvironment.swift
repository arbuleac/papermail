import AppKit
import Combine
import SSCore
import SSGmail
import SSGraph
import os

/// The object graph behind one window: store, engine and the sign-in plumbing. Real mode talks to Google and
/// Microsoft; demo mode swaps in a generated mailbox and fake tokens over its own database, and everything
/// above the engine is identical.
@MainActor
final class AppEnvironment {
    enum Mode: Equatable {
        case real
        case demo
    }

    let mode: Mode
    let store: MailStoring
    let engine: MailEngine
    let clientConfigurations: ClientConfigurationStore
    /// The files Settings › General counts as the mailbox's size on disk.
    let databasePath: String
    let attachmentDirectory: URL
    /// What `shutdown` runs `PRAGMA optimize` through before it closes the store; the store itself, except in the
    /// test that checks quitting does it while the store is still open.
    var storeMaintenance: MailStoreMaintenance
    /// Help Me Write's service (§5.56): the writer the card writes through and the API keys Settings › AI keeps. Real mode
    /// reaches the providers Settings › AI offers; the demo and the scratch graphs write canned replies on this Mac.
    let helpMeWrite: HelpMeWrite
    private let sqliteStore: SQLiteMailStore
    private var keepMailObservation: AnyCancellable?

    private static let log = Logger(subsystem: "io.supersparrow.mac", category: "shell")

    var isDemo: Bool { mode == .demo }

    private init(mode: Mode, store: SQLiteMailStore, engine: MailEngine, clientConfigurations: ClientConfigurationStore,
                 databasePath: String, attachmentDirectory: URL, helpMeWrite: HelpMeWrite) {
        self.mode = mode
        self.helpMeWrite = helpMeWrite
        self.sqliteStore = store
        self.store = store
        self.storeMaintenance = store
        self.engine = engine
        self.clientConfigurations = clientConfigurations
        self.databasePath = databasePath
        self.attachmentDirectory = attachmentDirectory
    }

    // MARK: Paths

    static var supportDirectory: URL {
        URL(fileURLWithPath: SQLiteMailStore.defaultPath).deletingLastPathComponent()
    }

    static var demoDatabasePath: String {
        supportDirectory.appendingPathComponent("demo.sqlite").path
    }

    static var attachmentCacheDirectory: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("SuperSparrow/attachments", isDirectory: true)
    }

    static var demoAttachmentCacheDirectory: URL {
        attachmentCacheDirectory.deletingLastPathComponent().appendingPathComponent("demo-attachments", isDirectory: true)
    }

    /// Deletes the demo database (with its WAL and shared-memory files), the demo attachment cache and the
    /// demo's drafts.
    static func wipeDemoData() {
        let fileManager = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fileManager.removeItem(atPath: demoDatabasePath + suffix)
        }
        try? fileManager.removeItem(at: demoAttachmentCacheDirectory)
        try? fileManager.removeItem(at: ComposeDraftStore.demoDirectory)
        log.info("demo data wiped")
    }

    // MARK: Building

    /// Building an environment does not make it the app's: the demo is seeded beside the real store, and a real
    /// one is built beside the demo while its first sign-in runs. `AppDelegate.install` points the drafts at the
    /// environment that is actually shown.
    static func make(mode: Mode, settings: AppSettings) throws -> AppEnvironment {
        let environment: AppEnvironment
        switch mode {
        case .real: environment = try makeReal(settings: settings)
        case .demo: environment = try makeDemo(settings: settings)
        }
        // Before the engine starts, so its launch sweep keeps to the saved window.
        environment.follow(settings)
        environment.helpMeWrite.settings = settings
        return environment
    }

    /// Keeps the engine's Keep mail window on the setting for as long as this environment lives, starting with the
    /// value it has now. An environment built beside the shown one (the demo's sign-in) follows it too.
    func follow(_ settings: AppSettings) {
        keepMailObservation = settings.$keepMail.removeDuplicates().sink { [engine] retention in
            engine.setMailRetention(retention)
        }
    }

    /// The mailbox's size on disk: measured off the main thread by the caller (Settings › General).
    nonisolated static func footprint(databasePath: String, attachmentDirectory: URL) -> Int64 {
        MailboxFootprint.bytes(databasePath: databasePath, attachmentDirectory: attachmentDirectory)
    }

    private static func makeReal(settings: AppSettings) throws -> AppEnvironment {
        let store = try SQLiteMailStore(path: SQLiteMailStore.defaultPath)
        let configurations = ClientConfigurationStore(fileURL: ClientConfigurationStore.defaultFileURL())
        let tokenStore = KeychainTokenStore()
        // TokenManager needs each account's kind to pick the token endpoint; the store is the source of truth.
        let tokenManager = TokenManager(
            tokenStore: tokenStore,
            configurations: configurations,
            kinds: { id in (try? store.accounts())?.first { $0.id == id }?.kind }
        )
        let authenticator = OAuthFlow(configurations: configurations, opener: { url in
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        })
        let engine = MailEngine(
            store: store,
            tokenStore: tokenStore,
            tokenProvider: tokenManager,
            authenticator: authenticator,
            sanitizer: PreferenceSanitizer(),
            providerFactory: { account in
                switch account.kind {
                case .gmail: return GmailProvider(accountID: account.id, accountEmail: account.email, tokens: tokenManager)
                case .microsoft: return GraphProvider(accountID: account.id, tokens: tokenManager)
                }
            },
            attachmentCacheDirectory: attachmentCacheDirectory
        )
        return AppEnvironment(mode: .real, store: store, engine: engine, clientConfigurations: configurations,
                              databasePath: SQLiteMailStore.defaultPath, attachmentDirectory: attachmentCacheDirectory,
                              helpMeWrite: .real())
    }

    private static func makeDemo(settings: AppSettings) throws -> AppEnvironment {
        let store = try SQLiteMailStore(path: demoDatabasePath)
        // The generated mailbox is rebuilt every launch; the store remembers what the user did to it.
        let service = DemoMailService(restore: { id in try? store.message(id) })
        let engine = MailEngine(
            store: store,
            tokenStore: InMemoryTokenStore(),
            tokenProvider: DemoTokenProvider(),
            authenticator: DemoAuthenticator(),
            sanitizer: PreferenceSanitizer(),
            providerFactory: { service.provider(for: $0) },
            // Short enough that a message arriving every ~45 s shows up promptly.
            pollInterval: 15,
            attachmentCacheDirectory: demoAttachmentCacheDirectory
        )
        // Demo mode never reads it, but Settings → OAuth still shows the real file.
        let configurations = ClientConfigurationStore(fileURL: ClientConfigurationStore.defaultFileURL())
        // The demo's writer is made up on this Mac; `--live-ai-clis` (debug) sends to the real Claude Code and Codex instead,
        // to check them against the demo's made-up mail.
        return AppEnvironment(mode: .demo, store: store, engine: engine, clientConfigurations: configurations,
                              databasePath: demoDatabasePath, attachmentDirectory: demoAttachmentCacheDirectory,
                              helpMeWrite: .demo(isDemo: true, liveCLIs: LaunchOptions().liveAICLIs))
    }

    /// A real-mode graph over an empty, throwaway store in `directory`, for the welcome-screen snapshot
    /// (`--snapshot-welcome`). Tokens stay in memory and sign-in is the demo's, so nothing here reaches the
    /// Keychain, the network or the user's mail database. The caller deletes the directory when done. The app's
    /// tests pass `.demo` for a window that behaves as the demo's over the same throwaway store, and their own
    /// `helpMeWrite` to watch what Help Me Write would reach (the demo writer otherwise).
    static func makeScratch(in directory: URL, mode: Mode = .real, helpMeWrite: HelpMeWrite? = nil) throws -> AppEnvironment {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let databasePath = directory.appendingPathComponent("scratch.sqlite").path
        let attachments = directory.appendingPathComponent("attachments", isDirectory: true)
        let store = try SQLiteMailStore(path: databasePath)
        let service = DemoMailService()
        let engine = MailEngine(
            store: store,
            tokenStore: InMemoryTokenStore(),
            tokenProvider: DemoTokenProvider(),
            authenticator: DemoAuthenticator(),
            sanitizer: PreferenceSanitizer(),
            providerFactory: { service.provider(for: $0) },
            attachmentCacheDirectory: attachments
        )
        let configurations = ClientConfigurationStore(fileURL: directory.appendingPathComponent("oauth-clients.json"))
        return AppEnvironment(mode: mode, store: store, engine: engine, clientConfigurations: configurations,
                              databasePath: databasePath, attachmentDirectory: attachments,
                              helpMeWrite: helpMeWrite ?? .demo(isDemo: mode == .demo))
    }

    // MARK: Lifecycle

    func start() {
        engine.start()
        guard isDemo else { return }
        let engine = self.engine
        Task {
            do {
                try await Self.seedDemo(engine)
            } catch {
                Self.log.error("demo seeding failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// The demo's mailboxes and, the first time they are added, its Send Later and Later samples (§5.43), so Drafts, the
    /// Outbox, the Later tile and the calendar's marks show from the start.
    private static func seedDemo(_ engine: MailEngine) async throws {
        let added = try await DemoSeeder.seedIfNeeded(engine)
        guard !added.isEmpty else { return }
        try DemoSeeder.seedSendLater(engine, accounts: added)
        // A snooze needs mail put away, which the accounts' first sync brings a moment after they are added. A store that
        // fails (the demo left meanwhile) ends the wait.
        Task.detached(priority: .utility) {
            for _ in 0..<120 {
                do {
                    if try DemoSeeder.seedLater(engine, accounts: added) != nil { return }
                } catch {
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// “Try the demo” (spec §5.39): starts the demo engine and returns once both made-up mailboxes exist, so
    /// the welcome screen can show Preparing the demo until then and Demo failed when seeding throws.
    func startAndSeedDemo() async throws {
        assert(isDemo, "only the demo environment seeds")
        engine.start()
        try await Self.seedDemo(engine)
    }

    /// Stops sync and waits for in-flight work so another environment can take over cleanly. Quitting comes through
    /// here (`AppDelegate.prepareToQuit`), so this is where the store gets SQLite's advice for a connection about to
    /// close, `PRAGMA optimize`: after the engine's last write and before the close.
    func shutdown() async {
        await helpMeWrite.shutdown()
        await engine.stopAndWait()
        // On a background task: it may analyze a table or two, and the main thread never waits on the disk.
        let maintenance = storeMaintenance
        do {
            try await Task.detached(priority: .userInitiated) { try maintenance.optimize() }.value
        } catch {
            Self.log.error("PRAGMA optimize failed: \(String(describing: error), privacy: .public)")
        }
        try? sqliteStore.close()
    }
}
