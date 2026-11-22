import Foundation

/// What the app was called before it was Paper, and where that app kept things: what the first launch's move reads
/// from (docs/ARCHITECTURE.md, "Identity"). Nothing else may name the old app; every live identifier is
/// `AppIdentity`'s.
public enum LegacyIdentity {
    /// The old product name, which was also the bare binary's name.
    public static let name = "SuperSparrow"

    /// The old bundle identifier: the bundled app's defaults domain, its caches folder, its per-bundle system state,
    /// and how to tell whether the old app is running.
    public static let bundleIdentifier = "io.supersparrow.mac"

    /// The old bundled app's defaults domain (`~/Library/Preferences/io.supersparrow.mac.plist`).
    public static let defaultsDomain = bundleIdentifier

    /// The old bare binary's defaults domain (`swift run`, renders): its executable's name.
    public static let bareBinaryDefaultsDomain = name

    // MARK: Application Support

    /// The old folder in Application Support: the mailbox (`mail.sqlite` with its `-wal` and `-shm`, `demo.sqlite`),
    /// `oauth-clients.json` and `Drafts`.
    public static let applicationSupportFolderName = "SuperSparrow"

    /// The old folder in `applicationSupport`.
    public static func applicationSupportDirectory(in applicationSupport: URL) -> URL {
        applicationSupport.appending(path: applicationSupportFolderName, directoryHint: .isDirectory)
    }

    // MARK: Caches

    /// The old bundle's caches folder, which held the crash reporter's queue (`Sentry`).
    public static let cachesFolderName = bundleIdentifier

    /// The old bundle's caches folder in `caches`.
    public static func cachesDirectory(in caches: URL) -> URL {
        caches.appending(path: cachesFolderName, directoryHint: .isDirectory)
    }

    /// The old crash reporter's queue in `caches`: reports not sent yet, which the move carries over.
    public static func sentryCacheDirectory(in caches: URL) -> URL {
        cachesDirectory(in: caches).appending(path: "Sentry", directoryHint: .isDirectory)
    }

    /// The old attachment caches' folder (`attachments`, `demo-attachments`), named for the product, not the bundle:
    /// files the app downloads again when asked, no user data.
    public static let attachmentCachesFolderName = "SuperSparrow"

    /// The old attachment caches' folder in `caches`.
    public static func attachmentCachesDirectory(in caches: URL) -> URL {
        caches.appending(path: attachmentCachesFolderName, directoryHint: .isDirectory)
    }

    // MARK: Keychain

    /// The old account tokens' service.
    public static let tokensKeychainService = "SuperSparrow"
    /// The old API keys' service.
    public static let aiKeysKeychainService = "SuperSparrow AI"

    // MARK: Per-bundle state

    /// The old app's derived per-bundle state in `library` (`~/Library`), no user data: its web content's storage,
    /// its URL session storage and cookies, and its saved window state. Exactly these, nothing broader.
    public static func leftovers(inLibrary library: URL) -> [URL] {
        [
            library.appending(path: "WebKit/\(bundleIdentifier)", directoryHint: .isDirectory),
            library.appending(path: "HTTPStorages/\(bundleIdentifier)", directoryHint: .isDirectory),
            library.appending(path: "HTTPStorages/\(bundleIdentifier).binarycookies", directoryHint: .notDirectory),
            library.appending(path: "Saved Application State/\(bundleIdentifier).savedState", directoryHint: .isDirectory),
        ]
    }

    // MARK: On the server

    /// The private extended property the old app wrote a set-aside block's client key in, on Google Calendar events
    /// it made. Still read, after the current one, so a block made before the rename keeps its key.
    public static let googleCalendarClientKeyProperty = "supersparrowKey"
}
