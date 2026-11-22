import XCTest
@testable import PaperCore

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
        XCTAssertEqual(query["prompt"], "consent select_account", "the account chooser lets a second Google account be added")
        XCTAssertNil(query["login_hint"])
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
        // Entra ignores a loopback URI's port but compares its path: the docs register plain http://localhost.
        XCTAssertEqual(query["redirect_uri"], "http://localhost:54321")
        XCTAssertEqual(query["response_type"], "code")
        XCTAssertEqual(query["scope"], "https://graph.microsoft.com/Mail.ReadWrite https://graph.microsoft.com/Mail.Send https://graph.microsoft.com/User.Read offline_access")
        XCTAssertEqual(query["state"], "state-2")
        XCTAssertEqual(query["code_challenge"], "challenge-2")
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["response_mode"], "query")
        XCTAssertNil(query["access_type"])
        // Without it Entra silently reuses the browser's session, and adding a second account returns the first.
        XCTAssertEqual(query["prompt"], "select_account")
    }

    func testLoginHintSteersAReconnect() {
        for kind in [ProviderKind.gmail, .microsoft] {
            let configuration = OAuthClientConfiguration(kind: kind, clientID: "id")
            let url = OAuthEndpoints.authorizationRequestURL(
                configuration: configuration, redirectURI: OAuthEndpoints.redirectURI(for: kind, port: 1),
                state: "s", codeChallenge: "c", loginHint: "a@example.com"
            )
            XCTAssertEqual(queryItems(of: url)["login_hint"], "a@example.com", "\(kind)")
        }
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

    // MARK: Permissions beyond mail (invitations)

    func testThePermissionsAddTheirScopesAfterMails() {
        XCTAssertEqual(OAuthEndpoints.scope(for: .gmail, permissions: []), OAuthEndpoints.googleScope)
        XCTAssertEqual(OAuthEndpoints.scope(for: .gmail, permissions: [.calendar]),
                       "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar.events")
        XCTAssertEqual(OAuthEndpoints.scope(for: .microsoft, permissions: [.calendar]),
                       OAuthEndpoints.microsoftScope + " https://graph.microsoft.com/Calendars.ReadWrite")
        let url = OAuthEndpoints.authorizationRequestURL(
            configuration: OAuthClientConfiguration(kind: .microsoft, clientID: "id"), redirectURI: "http://localhost:1",
            state: "s", codeChallenge: "c", permissions: [.calendar])
        XCTAssertTrue(queryItems(of: url)["scope"]?.hasSuffix("Calendars.ReadWrite") ?? false)
        XCTAssertNil(queryItems(of: url)["include_granted_scopes"], "Entra keeps what was consented without it")
    }

    /// Google keeps the scopes an account granted before when asked to: a reconnect for mail never drops the calendar.
    func testGoogleSignInsKeepWhatWasGrantedBefore() {
        let url = OAuthEndpoints.authorizationRequestURL(
            configuration: OAuthClientConfiguration(kind: .gmail, clientID: "abc.apps.googleusercontent.com"),
            redirectURI: OAuthEndpoints.redirectURI(for: .gmail, port: 1), state: "s", codeChallenge: "c")
        XCTAssertEqual(queryItems(of: url)["include_granted_scopes"], "true")
    }

    func testWhatATokensScopesGrant() {
        let google = OAuthEndpoints.googleScope + " " + OAuthEndpoints.googleCalendarScope
        XCTAssertTrue(OAuthEndpoints.grants(google, .calendar, kind: .gmail))
        XCTAssertFalse(OAuthEndpoints.grants(OAuthEndpoints.googleScope, .calendar, kind: .gmail))
        XCTAssertFalse(OAuthEndpoints.grants("https://www.googleapis.com/auth/calendar.events.readonly", .calendar, kind: .gmail))
        XCTAssertFalse(OAuthEndpoints.grants(nil, .calendar, kind: .gmail), "unknown grants nothing")
        XCTAssertTrue(OAuthEndpoints.grants("Mail.ReadWrite calendars.readwrite", .calendar, kind: .microsoft), "Microsoft's short, any case")
        XCTAssertTrue(OAuthEndpoints.grants("https://graph.microsoft.com/Calendars.ReadWrite", .calendar, kind: .microsoft))
        XCTAssertFalse(OAuthEndpoints.grants("Calendars.Read", .calendar, kind: .microsoft))
        XCTAssertEqual(OAuthEndpoints.permissions(grantedBy: google, kind: .gmail), [.calendar])
        XCTAssertEqual(OAuthEndpoints.permissions(grantedBy: OAuthEndpoints.googleScope, kind: .gmail), [])
    }

    // MARK: Server rules

    /// Sender rules live on the server: Gmail's filters behind the basic settings scope, Outlook's inbox rules behind
    /// the mailbox settings, each asked for after mail's and the calendar's, in a fixed order.
    func testTheRulesPermissionAsksForTheSettingsScopes() {
        XCTAssertEqual(OAuthEndpoints.scope(for: .rules, kind: .gmail), "https://www.googleapis.com/auth/gmail.settings.basic")
        XCTAssertEqual(OAuthEndpoints.scope(for: .rules, kind: .microsoft), "https://graph.microsoft.com/MailboxSettings.ReadWrite")
        XCTAssertEqual(AccountPermission.allCases, [.calendar, .rules], "the order scopes are asked for in")
        XCTAssertEqual(OAuthEndpoints.scope(for: .gmail, permissions: [.rules]),
                       "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/gmail.settings.basic")
        XCTAssertEqual(OAuthEndpoints.scope(for: .gmail, permissions: [.rules, .calendar]),
                       "https://www.googleapis.com/auth/gmail.modify https://www.googleapis.com/auth/calendar.events "
                       + "https://www.googleapis.com/auth/gmail.settings.basic")
        XCTAssertEqual(OAuthEndpoints.scope(for: .microsoft, permissions: [.rules]),
                       OAuthEndpoints.microsoftScope + " https://graph.microsoft.com/MailboxSettings.ReadWrite")
        let url = OAuthEndpoints.authorizationRequestURL(
            configuration: OAuthClientConfiguration(kind: .gmail, clientID: "abc.apps.googleusercontent.com"),
            redirectURI: OAuthEndpoints.redirectURI(for: .gmail, port: 1), state: "s", codeChallenge: "c", permissions: [.rules])
        XCTAssertTrue(queryItems(of: url)["scope"]?.hasSuffix("gmail.settings.basic") ?? false)
        XCTAssertEqual(queryItems(of: url)["include_granted_scopes"], "true", "incremental: the grant keeps what came before")
    }

    func testWhatATokensScopesGrantForRules() {
        let google = [OAuthEndpoints.googleScope, OAuthEndpoints.googleCalendarScope, OAuthEndpoints.googleRulesScope].joined(separator: " ")
        XCTAssertTrue(OAuthEndpoints.grants(google, .rules, kind: .gmail))
        XCTAssertFalse(OAuthEndpoints.grants(OAuthEndpoints.googleScope, .rules, kind: .gmail), "gmail.modify does not cover settings")
        XCTAssertFalse(OAuthEndpoints.grants("https://www.googleapis.com/auth/gmail.settings.sharing", .rules, kind: .gmail))
        XCTAssertEqual(OAuthEndpoints.permissions(grantedBy: google, kind: .gmail), [.calendar, .rules])
        XCTAssertTrue(OAuthEndpoints.grants("Mail.ReadWrite mailboxsettings.readwrite", .rules, kind: .microsoft))
        XCTAssertTrue(OAuthEndpoints.grants("https://graph.microsoft.com/MailboxSettings.ReadWrite", .rules, kind: .microsoft))
        XCTAssertFalse(OAuthEndpoints.grants("MailboxSettings.Read", .rules, kind: .microsoft), "reading is not saving")
        XCTAssertEqual(OAuthEndpoints.permissions(grantedBy: "Mail.ReadWrite MailboxSettings.ReadWrite", kind: .microsoft), [.rules])
    }
}
