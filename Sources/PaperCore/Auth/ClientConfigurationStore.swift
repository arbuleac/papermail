import Foundation

/// Reads the user's OAuth client registrations from `oauth-clients.json` (see docs/OAUTH-SETUP.md).
///
/// The file is read on every call rather than cached so a user who edits it does not have to relaunch the app
/// before adding an account; it is tiny and consulted only at sign-in and refresh time.
public struct ClientConfigurationStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/app.paperinbox.mac/oauth-clients.json`.
    public static func defaultFileURL() -> URL {
        AppIdentity.applicationSupportDirectory.appending(path: "oauth-clients.json", directoryHint: .notDirectory)
    }

    public func configuration(for kind: ProviderKind) throws -> OAuthClientConfiguration {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AuthError.missingClientConfiguration(kind)
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw AuthError.missingClientConfiguration(kind)
        }
        let file: ClientConfigurationFile
        do {
            file = try JSONDecoder().decode(ClientConfigurationFile.self, from: data)
        } catch {
            // A malformed file is a setup mistake the user needs to see, not a missing registration.
            throw AuthError.invalidResponse("\(fileURL.lastPathComponent) is not valid JSON: \(error.localizedDescription)")
        }
        guard let entry = file.entry(for: kind) else {
            throw AuthError.missingClientConfiguration(kind)
        }
        let clientID = entry.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            throw AuthError.missingClientConfiguration(kind)
        }
        switch kind {
        case .gmail:
            let secret = entry.clientSecret?.trimmingCharacters(in: .whitespacesAndNewlines)
            return OAuthClientConfiguration(
                kind: .gmail,
                clientID: clientID,
                clientSecret: (secret?.isEmpty ?? true) ? nil : secret,
                tenant: nil
            )
        case .microsoft:
            let tenant = entry.tenant?.trimmingCharacters(in: .whitespacesAndNewlines)
            return OAuthClientConfiguration(
                kind: .microsoft,
                clientID: clientID,
                clientSecret: nil,
                tenant: (tenant?.isEmpty ?? true) ? OAuthEndpoints.defaultMicrosoftTenant : tenant
            )
        }
    }
}

/// The on-disk shape. The documented key for Gmail is "google"; "gmail" is accepted too because it matches
/// `ProviderKind.gmail` and is an easy mistake to make by hand.
private struct ClientConfigurationFile: Decodable {
    struct Entry: Decodable {
        var clientID: String
        var clientSecret: String?
        var tenant: String?
    }

    var google: Entry?
    var gmail: Entry?
    var microsoft: Entry?

    func entry(for kind: ProviderKind) -> Entry? {
        switch kind {
        case .gmail: return google ?? gmail
        case .microsoft: return microsoft
        }
    }
}
