import Foundation
import SSCore

/// Reads and writes `oauth-clients.json` for the Settings → OAuth tab, in the shape `ClientConfigurationStore`
/// reads. Keys the tab does not know about are preserved.
struct OAuthClientFile: Equatable {
    var googleClientID = ""
    var googleClientSecret = ""
    var microsoftClientID = ""
    var microsoftTenant = ""

    /// The fields in the file, or empty ones when there is no file yet. Throws when the file exists but cannot
    /// be read or is not a JSON object, which Settings › OAuth reports in a danger banner (spec §5.33).
    static func read(from url: URL) throws -> OAuthClientFile {
        var file = OAuthClientFile()
        guard FileManager.default.fileExists(atPath: url.path) else { return file }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse("\(url.lastPathComponent) is not a JSON object")
        }
        let google = (root["google"] ?? root["gmail"]) as? [String: Any]
        file.googleClientID = google?["clientID"] as? String ?? ""
        file.googleClientSecret = google?["clientSecret"] as? String ?? ""
        let microsoft = root["microsoft"] as? [String: Any]
        file.microsoftClientID = microsoft?["clientID"] as? String ?? ""
        file.microsoftTenant = microsoft?["tenant"] as? String ?? ""
        return file
    }

    /// Writes the file readable only by the user (0600) inside a 0700 directory: it holds a client secret.
    func save(to url: URL) throws {
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: url),
           let existing = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            root = existing
        }
        root["gmail"] = nil
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if trim(googleClientID).isEmpty {
            root["google"] = nil
        } else {
            var google: [String: Any] = ["clientID": trim(googleClientID)]
            if !trim(googleClientSecret).isEmpty { google["clientSecret"] = trim(googleClientSecret) }
            root["google"] = google
        }
        if trim(microsoftClientID).isEmpty {
            root["microsoft"] = nil
        } else {
            let tenant = trim(microsoftTenant)
            root["microsoft"] = ["clientID": trim(microsoftClientID), "tenant": tenant.isEmpty ? "common" : tenant]
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        if !fileManager.fileExists(atPath: url.path) {
            _ = fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
