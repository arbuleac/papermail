import XCTest
@testable import SSCore

final class ClientConfigurationStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appending(path: "ss-auth-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func write(_ json: String) throws -> ClientConfigurationStore {
        let url = directory.appending(path: "oauth-clients.json")
        try Data(json.utf8).write(to: url)
        return ClientConfigurationStore(fileURL: url)
    }

    func testParsesDocumentedShape() throws {
        let store = try write("""
        {
          "google":    { "clientID": "123.apps.googleusercontent.com", "clientSecret": "GOCSPX-abc" },
          "microsoft": { "clientID": "00000000-0000-0000-0000-000000000000", "tenant": "common" }
        }
        """)
        let google = try store.configuration(for: .gmail)
        XCTAssertEqual(google, OAuthClientConfiguration(kind: .gmail, clientID: "123.apps.googleusercontent.com", clientSecret: "GOCSPX-abc", tenant: nil))
        let microsoft = try store.configuration(for: .microsoft)
        XCTAssertEqual(microsoft, OAuthClientConfiguration(kind: .microsoft, clientID: "00000000-0000-0000-0000-000000000000", clientSecret: nil, tenant: "common"))
    }

    func testMicrosoftTenantDefaultsToCommonAndGoogleSecretIsOptional() throws {
        let store = try write(#"{"google": {"clientID": "g"}, "microsoft": {"clientID": "m"}}"#)
        XCTAssertNil(try store.configuration(for: .gmail).clientSecret)
        XCTAssertEqual(try store.configuration(for: .microsoft).tenant, "common")
    }

    func testMissingFileThrowsMissingConfiguration() {
        let store = ClientConfigurationStore(fileURL: directory.appending(path: "nope.json"))
        XCTAssertThrowsError(try store.configuration(for: .gmail)) { error in
            guard case AuthError.missingClientConfiguration(let kind) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(kind, .gmail)
        }
    }

    func testMissingProviderEntryThrowsMissingConfiguration() throws {
        let store = try write(#"{"google": {"clientID": "g", "clientSecret": "s"}}"#)
        XCTAssertThrowsError(try store.configuration(for: .microsoft)) { error in
            guard case AuthError.missingClientConfiguration(let kind) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(kind, .microsoft)
        }
    }

    func testBlankClientIDCountsAsMissing() throws {
        let store = try write(#"{"microsoft": {"clientID": "   "}}"#)
        XCTAssertThrowsError(try store.configuration(for: .microsoft)) { error in
            guard case AuthError.missingClientConfiguration = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testMalformedJSONIsReportedAsInvalid() throws {
        let store = try write("{ not json")
        XCTAssertThrowsError(try store.configuration(for: .gmail)) { error in
            guard case AuthError.invalidResponse(let message) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertTrue(message.contains("oauth-clients.json"))
        }
    }

    func testDefaultFileURL() {
        let url = ClientConfigurationStore.defaultFileURL()
        XCTAssertTrue(url.path.hasSuffix("/Library/Application Support/SuperSparrow/oauth-clients.json"), url.path)
    }
}
