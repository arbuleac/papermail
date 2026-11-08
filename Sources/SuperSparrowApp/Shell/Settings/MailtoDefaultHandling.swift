import AppKit

/// Which app opens `mailto:` links. Settings › General asks and changes it only through this, so the app's tests,
/// which pass a fake, never read or change the Mac's real default mail app.
@MainActor
protocol MailtoDefaultHandling {
    /// Whether this app opens mail links now.
    func isDefault() async -> Bool
    /// Asks macOS to make this app open mail links. macOS asks the user to confirm first.
    func makeDefault() async throws
}

/// LaunchServices, through `NSWorkspace`, for this app's bundle.
struct LaunchServicesMailtoHandler: MailtoDefaultHandling {
    private let bundleURL: URL
    private let bundleIdentifier: String?

    init(bundle: Bundle = .main) {
        bundleURL = bundle.bundleURL
        bundleIdentifier = bundle.bundleIdentifier
    }

    /// Off the main thread: the answer comes from LaunchServices' database.
    func isDefault() async -> Bool {
        let bundleURL = bundleURL
        let bundleIdentifier = bundleIdentifier
        return await Task.detached(priority: .userInitiated) {
            guard let probe = URL(string: "mailto:"), let handler = NSWorkspace.shared.urlForApplication(toOpen: probe) else { return false }
            // By bundle id first: another copy of this app (a build elsewhere on disk) is SuperSparrow all the same.
            if let bundleIdentifier, Bundle(url: handler)?.bundleIdentifier == bundleIdentifier { return true }
            return handler.standardizedFileURL == bundleURL.standardizedFileURL
        }.value
    }

    func makeDefault() async throws {
        let bundleURL = bundleURL
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpenURLsWithScheme: "mailto") { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

/// The snapshots' answer: not the default, and nothing is ever asked of or changed in LaunchServices, so a render
/// depends on nothing but the build.
struct SnapshotMailtoHandler: MailtoDefaultHandling {
    func isDefault() async -> Bool { false }
    func makeDefault() async throws { throw CocoaError(.featureUnsupported) }
}
