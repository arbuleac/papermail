import AppKit
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
    private let sqliteStore: SQLiteMailStore

    private static let log = Logger(subsystem: "io.supersparrow.mac", category: "shell")

    var isDemo: Bool { mode == .demo }

    private init(mode: Mode, store: SQLiteMailStore, engine: MailEngine, clientConfigurations: ClientConfigurationStore) {
        self.mode = mode
        self.sqliteStore = store
        self.store = store
        self.engine = engine
        self.clientConfigurations = clientConfigurations
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

    static func make(mode: Mode, settings: AppSettings) throws -> AppEnvironment {
        ComposeDraftStore.shared.useDemoDirectory(mode == .demo)
        switch mode {
        case .real: return try makeReal(settings: settings)
        case .demo: return try makeDemo(settings: settings)
        }
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
                case .gmail: return GmailProvider(accountID: account.id, tokens: tokenManager)
                case .microsoft: return GraphProvider(accountID: account.id, tokens: tokenManager)
                }
            },
            attachmentCacheDirectory: attachmentCacheDirectory
        )
        return AppEnvironment(mode: .real, store: store, engine: engine, clientConfigurations: configurations)
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
        return AppEnvironment(mode: .demo, store: store, engine: engine, clientConfigurations: configurations)
    }

    /// A real-mode graph over an empty, throwaway store in `directory`, for the welcome-screen snapshot
    /// (`--snapshot-welcome`). Tokens stay in memory and sign-in is the demo's, so nothing here reaches the
    /// Keychain, the network or the user's mail database. The caller deletes the directory when done.
    static func makeScratch(in directory: URL) throws -> AppEnvironment {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("scratch.sqlite").path)
        let service = DemoMailService()
        let engine = MailEngine(
            store: store,
            tokenStore: InMemoryTokenStore(),
            tokenProvider: DemoTokenProvider(),
            authenticator: DemoAuthenticator(),
            sanitizer: PreferenceSanitizer(),
            providerFactory: { service.provider(for: $0) },
            attachmentCacheDirectory: directory.appendingPathComponent("attachments", isDirectory: true)
        )
        let configurations = ClientConfigurationStore(fileURL: directory.appendingPathComponent("oauth-clients.json"))
        return AppEnvironment(mode: .real, store: store, engine: engine, clientConfigurations: configurations)
    }

    // MARK: Lifecycle

    func start() {
        engine.start()
        guard isDemo else { return }
        let engine = self.engine
        Task {
            do {
                try await DemoSeeder.seedIfNeeded(engine)
            } catch {
                Self.log.error("demo seeding failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Stops sync and waits for in-flight work so another environment can take over cleanly.
    func shutdown() async {
        await engine.stopAndWait()
        try? sqliteStore.close()
    }
}
