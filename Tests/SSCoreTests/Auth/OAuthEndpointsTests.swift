import XCTest
@testable import SSCore

final class OAuthEndpointsTests: XCTestCase {
    private func queryItems(of url: URL) -> [String: String] {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        return Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    func testGoogleAuthorizationURL() {
        let configuration = OAuthClientConfiguration(kind: .gmail, clientID: "abc.apps.googleusercontent.com", clientSecret: "shh")
        let url = OAuthEndpoints.authorizationRequestURL(
            configuration: configuration,
            redirectURI: OAuthEndpoints.redirectURI(for: .gmail, port: 54321),
            state: "state-1",
            codeChallenge: "challenge-1"
        )
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "accounts.google.com")
        XCTAssertEqual(url.path, "/o/oauth2/v2/auth")
        let query = queryItems(of: url)
        XCTAssertEqual(query["client_id"], "abc.apps.googleusercontent.com")
        XCTAssertEqual(query["redirect_uri"], "http://127.0.0.1:54321/callback")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["scope"], "https://www.googleapis.com/auth/gmail.modify")
        XCTAssertEqual(query["state"], "state-1")
        XCTAssertEqual(query["code_challenge"], "challenge-1")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["access_type"], "offline")
        XCTAssertEqual(query["prompt"], "consent")
        XCTAssertNil(query["client_secret"], "the secret must never appear in the browser URL")
        XCTAssertNil(query["response_mode"])
    }

    func testMicrosoftAuthorizationURL() {
        let configuration = OAuthClientConfiguration(kind: .microsoft, clientID: "00000000-0000-0000-0000-000000000000", tenant: "contoso.onmicrosoft.com")
        let url = OAuthEndpoints.authorizationRequestURL(
            configuration: configuration,
            redirectURI: OAuthEndpoints.redirectURI(for: .microsoft, port: 54321),
            state: "state-2",
            codeChallenge: "challenge-2"
        )
        XCTAssertEqual(url.host, "login.microsoftonline.com")
        XCTAssertEqual(url.path, "/contoso.onmicrosoft.com/oauth2/v2.0/authorize")
        let query = queryItems(of: url)
        XCTAssertEqual(query["client_id"], "00000000-0000-0000-0000-000000000000")
        XCTAssertEqual(query["redirect_uri"], "http://localhost:54321/callback")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["scope"], "https://graph.microsoft.com/Mail.ReadWrite https://graph.microsoft.com/Mail.Send https://graph.microsoft.com/User.Read offline_access")
        XCTAssertEqual(query["state"], "state-2")
        XCTAssertEqual(query["code_challenge"], "challenge-2")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["response_mode"], "query")
        XCTAssertNil(query["access_type"])
        XCTAssertNil(query["prompt"])
    }

    func testMicrosoftTenantDefaultsToCommon() {
        XCTAssertEqual(OAuthEndpoints.microsoftAuthorizationURL(tenant: nil).path, "/common/oauth2/v2.0/authorize")
        XCTAssertEqual(OAuthEndpoints.microsoftTokenURL(tenant: " ").path, "/common/oauth2/v2.0/token")
        XCTAssertEqual(OAuthEndpoints.tokenURL(for: .microsoft, tenant: "organizations").absoluteString, "https://login.microsoftonline.com/organizations/oauth2/v2.0/token")
        XCTAssertEqual(OAuthEndpoints.tokenURL(for: .gmail).absoluteString, "https://oauth2.googleapis.com/token")
    }

    func testScopeQueryIsPercentEncodedWithoutPlus() {
        let configuration = OAuthClientConfiguration(kind: .microsoft, clientID: "id")
        let url = OAuthEndpoints.authorizationRequestURL(configuration: configuration, redirectURI: "http://localhost:1/callback", state: "s", codeChallenge: "c")
        XCTAssertFalse(url.absoluteString.contains("+"))
        XCTAssertTrue(url.absoluteString.contains("Mail.ReadWrite%20"), url.absoluteString)
    }
}
