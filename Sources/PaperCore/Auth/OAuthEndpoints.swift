import Foundation

/// The OAuth 2.0 endpoints, scopes and redirect shapes for both providers, in one place so the sign-in flow,
/// the token manager, the provider adapters and the tests all agree on them.
public enum OAuthEndpoints {
    public static let googleScope = "https://www.googleapis.com/auth/gmail.modify"
    public static let microsoftScope = "https://graph.microsoft.com/Mail.ReadWrite https://graph.microsoft.com/Mail.Send https://graph.microsoft.com/User.Read offline_access"
    /// Answering invitations (`AccountPermission.calendar`): Google marks the user's own Calendar copy through
    /// `events.patch`; Graph accepts, tentatively accepts or declines the event.
    public static let googleCalendarScope = "https://www.googleapis.com/auth/calendar.events"
    public static let microsoftCalendarScope = "https://graph.microsoft.com/Calendars.ReadWrite"
    /// Sender rules kept on the server (`AccountPermission.rules`): Gmail's filters need the basic settings scope, which
    /// `gmail.modify` does not include; Outlook's inbox rules are mailbox settings.
    public static let googleRulesScope = "https://www.googleapis.com/auth/gmail.settings.basic"
    public static let microsoftRulesScope = "https://graph.microsoft.com/MailboxSettings.ReadWrite"

    /// Entra's multi-tenant endpoint; accepts personal and work accounts.
    public static let defaultMicrosoftTenant = "common"

    public static let googleAuthorizationURL = url("https://accounts.google.com/o/oauth2/v2/auth")
    public static let googleTokenURL = url("https://oauth2.googleapis.com/token")

    public static func microsoftAuthorizationURL(tenant: String?) -> URL {
        url("https://login.microsoftonline.com/\(tenantPathComponent(tenant))/oauth2/v2.0/authorize")
    }

    public static func microsoftTokenURL(tenant: String?) -> URL {
        url("https://login.microsoftonline.com/\(tenantPathComponent(tenant))/oauth2/v2.0/token")
    }

    public static func scope(for kind: ProviderKind) -> String {
        switch kind {
        case .gmail: return googleScope
        case .microsoft: return microsoftScope
        }
    }

    /// The scope a permission adds on `kind`.
    public static func scope(for permission: AccountPermission, kind: ProviderKind) -> String {
        switch (permission, kind) {
        case (.calendar, .gmail): return googleCalendarScope
        case (.calendar, .microsoft): return microsoftCalendarScope
        case (.rules, .gmail): return googleRulesScope
        case (.rules, .microsoft): return microsoftRulesScope
        }
    }

    /// Mail's scope with each permission's added, in a fixed order.
    public static func scope(for kind: ProviderKind, permissions: Set<AccountPermission>) -> String {
        ([scope(for: kind)] + AccountPermission.allCases.filter(permissions.contains).map { scope(for: $0, kind: kind) })
            .joined(separator: " ")
    }

    /// Whether the scopes a token endpoint listed (space-separated) include the permission's. Microsoft lists Graph's
    /// scopes with or without the resource (`Calendars.ReadWrite` or `https://graph.microsoft.com/Calendars.ReadWrite`),
    /// so a scope matches by its last path component, ignoring case. Nil (unknown) grants nothing.
    public static func grants(_ granted: String?, _ permission: AccountPermission, kind: ProviderKind) -> Bool {
        guard let granted else { return false }
        let wanted = scope(for: permission, kind: kind)
        let wantedName = wanted.split(separator: "/").last.map { $0.lowercased() } ?? wanted.lowercased()
        return granted.split(whereSeparator: \.isWhitespace).contains { listed in
            listed.caseInsensitiveCompare(wanted) == .orderedSame
                || (kind == .microsoft && (listed.split(separator: "/").last.map { $0.lowercased() } ?? "") == wantedName)
        }
    }

    /// The permissions beyond mail the scopes a token endpoint listed grant.
    public static func permissions(grantedBy granted: String?, kind: ProviderKind) -> Set<AccountPermission> {
        Set(AccountPermission.allCases.filter { grants(granted, $0, kind: kind) })
    }

    public static func authorizationURL(for kind: ProviderKind, tenant: String? = nil) -> URL {
        switch kind {
        case .gmail: return googleAuthorizationURL
        case .microsoft: return microsoftAuthorizationURL(tenant: tenant)
        }
    }

    public static func tokenURL(for kind: ProviderKind, tenant: String? = nil) -> URL {
        switch kind {
        case .gmail: return googleTokenURL
        case .microsoft: return microsoftTokenURL(tenant: tenant)
        }
    }

    /// Google documents the loopback redirect as `http://127.0.0.1:{port}`. Entra only accepts the literal
    /// `http://localhost` form for public clients and compares the registered URI without the port but with
    /// the path, so the redirect carries no path to match the plain `http://localhost` docs/OAUTH-SETUP.md
    /// tells users to register (MSAL's loopback clients do the same).
    public static func redirectURI(for kind: ProviderKind, port: UInt16) -> String {
        switch kind {
        case .gmail: return "http://127.0.0.1:\(port)/callback"
        case .microsoft: return "http://localhost:\(port)"
        }
    }

    /// The request path the browser uses for `redirectURI(for:port:)`.
    public static func redirectPath(for kind: ProviderKind) -> String {
        switch kind {
        case .gmail: return "/callback"
        case .microsoft: return "/"
        }
    }

    /// The full authorization request for `configuration`, with PKCE and state attached.
    public static func authorizationRequestURL(
        configuration: OAuthClientConfiguration,
        redirectURI: String,
        state: String,
        codeChallenge: String,
        loginHint: String? = nil,
        permissions: Set<AccountPermission> = []
    ) -> URL {
        let base = authorizationURL(for: configuration.kind, tenant: configuration.tenant)
        var items = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scope(for: configuration.kind, permissions: permissions)),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: PKCE.method),
        ]
        switch configuration.kind {
        case .gmail:
            // Google only issues a refresh token for offline access, and only on the first consent unless
            // prompt=consent forces it; without both, re-adding an account would yield no refresh token.
            // select_account shows the chooser even with one signed-in session, so a second account can be added.
            items.append(URLQueryItem(name: "access_type", value: "offline"))
            items.append(URLQueryItem(name: "prompt", value: "consent select_account"))
            // Incremental authorization: the new grant keeps what the account granted before, so a reconnect for mail
            // alone does not take away the calendar permission an invitation answer asked for.
            items.append(URLQueryItem(name: "include_granted_scopes", value: "true"))
        case .microsoft:
            items.append(URLQueryItem(name: "response_mode", value: "query"))
            // Without a prompt Entra completes the request from the browser's single session, and adding a
            // second account silently signs in to the first one again.
            items.append(URLQueryItem(name: "prompt", value: "select_account"))
        }
        if let loginHint, !loginHint.isEmpty {
            items.append(URLQueryItem(name: "login_hint", value: loginHint))
        }
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            preconditionFailure("Authorization endpoint is not a valid URL: \(base)")
        }
        components.queryItems = items
        // URLComponents leaves "+" unescaped in query values; Google would decode it as a space inside a scope.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let result = components.url else {
            preconditionFailure("Authorization request could not be assembled for \(configuration.kind)")
        }
        return result
    }

    private static func tenantPathComponent(_ tenant: String?) -> String {
        let trimmed = tenant?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultMicrosoftTenant : trimmed
    }

    /// These literals are fixed at compile time, so a failure here is a programming error rather than input.
    private static func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            preconditionFailure("Invalid endpoint literal: \(string)")
        }
        return url
    }
}
