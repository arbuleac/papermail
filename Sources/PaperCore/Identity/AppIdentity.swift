import Foundation

/// Who the app is: its name, its bundle identifier, its website, and the places on this Mac it keeps things under its
/// own name (docs/ARCHITECTURE.md, "Identity"). The one source for each; nothing spells them out again, so a log's
/// subsystem, the mailbox's folder and the Keychain items always agree. What the app was called before is
/// `LegacyIdentity`'s, for moving the user's data on the first launch alone.
public enum AppIdentity {
    /// The product's name, as windows, menus, alerts and Settings say it.
    public static let name = "Paper"

    /// The bundle identifier (Info.plist's `CFBundleIdentifier`), and the subsystem of every log and signpost.
    public static let bundleIdentifier = "app.paperinbox.mac"

    /// The website.
    public static let website = URL(string: "https://paperinbox.app")!

    /// The website's other address, which redirects to `website`.
    public static let websiteAlias = URL(string: "https://paperinboxapp.com")!

    // MARK: Application Support

    /// The folder in Application Support that holds the mailbox (`mail.sqlite`, the demo's `demo.sqlite`), the OAuth
    /// clients (`oauth-clients.json`) and the drafts (`Drafts`). Named for the bundle identifier: "Paper" alone could
    /// be another app's folder.
    public static let applicationSupportFolderName = bundleIdentifier

    /// The app's folder in `applicationSupport` (the user's Application Support, or a test's temporary folder).
    public static func applicationSupportDirectory(in applicationSupport: URL) -> URL {
        applicationSupport.appending(path: applicationSupportFolderName, directoryHint: .isDirectory)
    }

    /// `~/Library/Application Support/app.paperinbox.mac`.
    public static var applicationSupportDirectory: URL {
        applicationSupportDirectory(in: userDirectory(.applicationSupportDirectory, fallback: "Library/Application Support"))
    }

    // MARK: Caches

    /// The folder in Caches that holds what the app can always rebuild: the attachment caches (`attachments`,
    /// `demo-attachments`) and the crash reporter's queue (`Sentry`).
    public static let cachesFolderName = bundleIdentifier

    /// The folder of the crash reporter's queue in the app's caches folder, which turning reports off deletes.
    public static let sentryCacheFolderName = "Sentry"

    /// The app's folder in `caches` (the user's Caches, or a test's temporary folder).
    public static func cachesDirectory(in caches: URL) -> URL {
        caches.appending(path: cachesFolderName, directoryHint: .isDirectory)
    }

    /// `~/Library/Caches/app.paperinbox.mac`.
    public static var cachesDirectory: URL {
        cachesDirectory(in: userDirectory(.cachesDirectory, fallback: "Library/Caches"))
    }

    /// The crash reporter's queue in `caches`.
    public static func sentryCacheDirectory(in caches: URL) -> URL {
        cachesDirectory(in: caches).appending(path: sentryCacheFolderName, directoryHint: .isDirectory)
    }

    // MARK: Keychain

    /// The account tokens' service: one generic-password item per account (`KeychainTokenStore`).
    public static let tokensKeychainService = bundleIdentifier
    /// What Keychain Access shows for an account's tokens.
    public static let tokensKeychainLabel = "\(name) account"
    /// Help Me Write's API keys' service, apart from the tokens: one item per provider (`AIKeyStore`).
    public static let aiKeysKeychainService = bundleIdentifier + ".ai"
    /// What Keychain Access shows for an API key.
    public static let aiKeysKeychainLabel = "\(name) AI key"

    // MARK: Identifiers in mail

    /// The domain of the identifiers the app makes when the sender's address gives none (a Message-ID's fallback,
    /// a pasted picture's Content-ID): under `.local`, which no one can own, so it never claims a real host.
    public static let localDomain = "paperinbox.local"

    // MARK: Support

    private static func userDirectory(_ directory: FileManager.SearchPathDirectory, fallback: String) -> URL {
        FileManager.default.urls(for: directory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: fallback, directoryHint: .isDirectory)
    }
}
