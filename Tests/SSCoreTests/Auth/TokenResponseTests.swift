import XCTest
@testable import SSCore

final class TokenResponseTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testExpiresInBecomesExpiresAt() throws {
        let json = #"{"access_token":"at","refresh_token":"rt","expires_in":3599,"scope":"a b","token_type":"Bearer"}"#
        let response = try JSONDecoder().decode(TokenResponse.self, from: Data(json.utf8))
        let issuedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let tokens = response.tokens(issuedAt: issuedAt)
        XCTAssertEqual(tokens.accessToken, "at")
        XCTAssertEqual(tokens.refreshToken, "rt")
        XCTAssertEqual(tokens.scope, "a b")
        XCTAssertEqual(tokens.expiresAt, issuedAt.addingTimeInterval(3599))
    }

    func testExpiresInAsStringIsAccepted() throws {
        let json = #"{"access_token":"at","expires_in":"120"}"#
        let response = try JSONDecoder().decode(TokenResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.expiresIn, 120)
    }

    func testMissingExpiresInFallsBackToAnHour() throws {
        let json = #"{"access_token":"at"}"#
        let response = try JSONDecoder().decode(TokenResponse.self, from: Data(json.utf8))
        let issuedAt = Date()
        XCTAssertEqual(response.tokens(issuedAt: issuedAt).expiresAt, issuedAt.addingTimeInterval(3600))
    }

    func testOmittedRefreshTokenAndScopeComeFromPrevious() throws {
        let previous = OAuthTokens(accessToken: "old", refreshToken: "keep-me", expiresAt: .distantPast, scope: "old-scope")
        let response = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"new","expires_in":60}"#.utf8))
        let tokens = response.tokens(issuedAt: Date(), previous: previous)
        XCTAssertEqual(tokens.accessToken, "new")
        XCTAssertEqual(tokens.refreshToken, "keep-me")
        XCTAssertEqual(tokens.scope, "old-scope")
    }

    func testRotatedRefreshTokenReplacesPrevious() throws {
        let previous = OAuthTokens(accessToken: "old", refreshToken: "old-rt", expiresAt: .distantPast, scope: nil)
        let response = try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"access_token":"new","refresh_token":"new-rt"}"#.utf8))
        XCTAssertEqual(response.tokens(issuedAt: Date(), previous: previous).refreshToken, "new-rt")
    }

    func testMissingAccessTokenFailsToDecode() {
        XCTAssertThrowsError(try JSONDecoder().decode(TokenResponse.self, from: Data(#"{"refresh_token":"rt"}"#.utf8)))
    }

    func testFormEncodingUsesUnreservedSet() {
        let encoded = TokenEndpoint.formEncode([("scope", "https://a/b c"), ("code", "4/0A+x=")])
        XCTAssertEqual(encoded, "scope=https%3A%2F%2Fa%2Fb%20c&code=4%2F0A%2Bx%3D")
    }

    func testErrorBodyBecomesServerError() async {
        StubURLProtocol.install { _ in
            StubURLProtocol.Reply(status: 400, json: #"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#)
        }
        do {
            _ = try await TokenEndpoint.post(form: [("grant_type", "refresh_token")], to: OAuthEndpoints.googleTokenURL, session: StubURLProtocol.makeSession())
            XCTFail("expected a server error")
        } catch let error as TokenEndpointError {
            guard case let .server(code, description, status) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "invalid_grant")
            XCTAssertEqual(description, "Token has been expired or revoked.")
            XCTAssertEqual(status, 400)
            XCTAssertTrue(error.requiresReauthorization)
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(StubURLProtocol.requests.first?.method, "POST")
        XCTAssertEqual(StubURLProtocol.requests.first?.form["grant_type"], "refresh_token")
    }

    func testHTTPFailureWithoutBodyBecomesHTTPError() async {
        StubURLProtocol.install { _ in StubURLProtocol.Reply(status: 503, json: "service unavailable", headers: [:]) }
        do {
            _ = try await TokenEndpoint.post(form: [], to: OAuthEndpoints.googleTokenURL, session: StubURLProtocol.makeSession())
            XCTFail("expected an HTTP error")
        } catch let error as TokenEndpointError {
            guard case let .http(status) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(status, 503)
            XCTAssertFalse(error.requiresReauthorization)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
