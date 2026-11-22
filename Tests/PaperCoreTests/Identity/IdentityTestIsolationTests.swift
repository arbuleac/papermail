import Foundation
import XCTest
@testable import PaperCore

/// No test reaches the user's Library, defaults or Keychain through the first launch's move or the Keychain stores: the
/// move always gets the test's own folders and a dictionary for the defaults, and the stores a dictionary for the
/// Keychain. A scan of every test's code, so a new test that forgets cannot slip in; and the test process itself is
/// never the bundled app, so even the stores' defaults read no old item (`IdentityMigrationTests`).
final class IdentityTestIsolationTests: XCTestCase {
    private var testsRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// What reaches the real system, as code would spell it, and a word each such spelling holds, for a fast first look.
    private let forbidden: [(anchor: String, pattern: String, why: String)] = [
        ("ocations", #"\bLocations\s*\.\s*user\b|locations:\s*\.user\b"#, "the user's own Library folders"),
        ("IdentityMigrationLaunch", #"\bIdentityMigrationLaunch\b"#, "the app's launch, over the user's folders and defaults"),
        ("IdentityMigration", #"\bIdentityMigration\s*\([^)]*defaults:\s*(UserDefaults|\.standard)"#, "the user's defaults"),
        ("KeychainTokenStore", #"\bKeychainTokenStore\s*\((?![^)]*access:)"#, "the login Keychain"),
        ("AIKeyStore", #"\bAIKeyStore\s*\((?![^)]*access:)"#, "the login Keychain"),
        ("KeychainAccess", #"\bKeychainAccess\s*\.\s*system\b"#, "the login Keychain"),
        ("access:", #"\baccess:\s*\.system\b"#, "the login Keychain"),
        ("SecItem", #"\bSecItem(Add|CopyMatching|Update|Delete)\b"#, "the login Keychain"),
    ]

    func testNoTestReachesTheUsersLibraryDefaultsOrKeychain() throws {
        let files = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "IdentityTestIsolationTests.swift" } ?? []
        XCTAssertGreaterThan(files.count, 100, "the scan sees every test")
        var found: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let hits = forbidden.filter { text.contains($0.anchor) && text.range(of: $0.pattern, options: .regularExpression) != nil }
            guard !hits.isEmpty else { continue }
            let code = Self.code(text)
            for rule in hits where code.range(of: rule.pattern, options: .regularExpression) != nil {
                found.append("\(file.lastPathComponent): \(rule.why)")
            }
        }
        XCTAssertEqual(found, [])
    }

    func testTheScanCatchesWhatItLooksFor() {
        let samples = [
            "IdentityMigration(bundleIdentifier: id, locations: .user, defaults: d) { false }",
            "IdentityMigration(bundleIdentifier: id, locations: l, defaults: UserDefaults.standard) { false }",
            "let s = KeychainTokenStore()",
            "let s = KeychainTokenStore(service: \"x\")",
            "let k = AIKeyStore()",
            "_ = IdentityMigrationLaunch.run()",
            "SecItemDelete(query as CFDictionary)",
        ]
        for sample in samples {
            XCTAssertTrue(forbidden.contains { sample.contains($0.anchor) && sample.range(of: $0.pattern, options: .regularExpression) != nil }, sample)
        }
        let allowed = [
            "KeychainTokenStore(service: s, legacyService: o, access: keychain.access)",
            "AIKeyStore(service: AIKeyStore.defaultService, access: keychain.access)",
            "InMemoryAIKeyStore([.claudeAPI: \"k\"])",
            "IdentityMigration(bundleIdentifier: b, locations: locations, defaults: defaults) { true }",
        ]
        for sample in allowed {
            XCTAssertFalse(forbidden.contains { sample.range(of: $0.pattern, options: .regularExpression) != nil }, sample)
        }
    }

    /// `text` without its comments, so a doc comment that names an API is not a call to it.
    private static func code(_ text: String) -> String {
        text.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                guard let range = line.range(of: "//") else { return String(line) }
                // A `//` inside a string (a URL) is not a comment.
                let before = line[..<range.lowerBound]
                return before.filter { $0 == "\"" }.count % 2 == 0 ? String(before) : String(line)
            }
            .joined(separator: "\n")
    }
}
