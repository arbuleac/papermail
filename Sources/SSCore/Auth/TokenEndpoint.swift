import Foundation

/// A successful token endpoint reply (RFC 6749 §5.1). Shared by the code exchange and the refresh grant.
struct TokenResponse: Decodable, Sendable, Hashable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: TimeInterval?
    var scope: String?
    var tokenType: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
        case tokenType = "token_type"
    }

    init(accessToken: String, refreshToken: String? = nil, expiresIn: TimeInterval? = nil, scope: String? = nil, tokenType: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresIn = expiresIn
        self.scope = scope
        self.tokenType = tokenType
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        refreshToken = try container.decodeIfPresent(String.self, forKey: .refreshToken)
        scope = try container.decodeIfPresent(String.self, forKey: .scope)
        tokenType = try container.decodeIfPresent(String.self, forKey: .tokenType)
        // The spec says expires_in is a number, but some identity providers send it as a string.
        if let seconds = try? container.decodeIfPresent(Double.self, forKey: .expiresIn) {
            expiresIn = seconds
        } else if let text = try? container.decodeIfPresent(String.self, forKey: .expiresIn) {
            expiresIn = TimeInterval(text.trimmingCharacters(in: .whitespaces))
        } else {
            expiresIn = nil
        }
    }

    /// Google's access tokens last an hour; when a provider omits `expires_in` we assume the same rather than
    /// treating the token as already stale, which would refresh on every request.
    static let defaultLifetime: TimeInterval = 3600

    /// Builds the stored tokens. `previous` supplies the refresh token and scope when the reply omits them,
    /// which Microsoft does when it chooses not to rotate.
    func tokens(issuedAt: Date, previous: OAuthTokens? = nil) -> OAuthTokens {
        OAuthTokens(
            accessToken: accessToken,
            refreshToken: refreshToken ?? previous?.refreshToken,
            expiresAt: issuedAt.addingTimeInterval(expiresIn ?? TokenResponse.defaultLifetime),
            scope: scope ?? previous?.scope
        )
    }
}

/// Why a token endpoint call failed, before the caller maps it to `AuthError` or `ProviderError`.
enum TokenEndpointError: Error, Sendable {
    /// The provider answered with an RFC 6749 §5.2 error body.
    case server(code: String, description: String?, status: Int)
    /// HTTP failure without a parseable error body.
    case http(status: Int)
    case transport(String)
    case invalidResponse(String)

    var message: String {
        switch self {
        case let .server(code, description, status):
            if let description, !description.isEmpty { return "\(code): \(description) (HTTP \(status))" }
            return "\(code) (HTTP \(status))"
        case let .http(status):
            return "HTTP \(status)"
        case let .transport(text), let .invalidResponse(text):
            return text
        }
    }

    /// Codes that mean the stored grant is dead and only a new sign-in can help (RFC 6749 §5.2 and the Entra
    /// conditional-access variants). Everything else is transient or a configuration problem.
    var requiresReauthorization: Bool {
        guard case let .server(code, _, _) = self else { return false }
        switch code {
        case "invalid_grant", "interaction_required", "consent_required", "login_required":
            return true
        default:
            return false
        }
    }
}

/// POSTs form-encoded grants to a token endpoint and decodes the reply.
enum TokenEndpoint {
    private struct ErrorBody: Decodable {
        var error: String
        var errorDescription: String?

        private enum CodingKeys: String, CodingKey {
            case error
            case errorDescription = "error_description"
        }
    }

    static func request(url: URL, form: [(name: String, value: String)]) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(formEncode(form).utf8)
        return request
    }

    static func post(form: [(name: String, value: String)], to url: URL, session: URLSession) async throws -> TokenResponse {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request(url: url, form: form))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw TokenEndpointError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw TokenEndpointError.invalidResponse("Token endpoint returned a non-HTTP response")
        }
        let decoder = JSONDecoder()
        // Providers put the error body on 400/401, but a few return 200 with an error object; check the body first.
        if let failure = try? decoder.decode(ErrorBody.self, from: data) {
            throw TokenEndpointError.server(code: failure.error, description: failure.errorDescription, status: http.statusCode)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw TokenEndpointError.http(status: http.statusCode)
        }
        do {
            return try decoder.decode(TokenResponse.self, from: data)
        } catch {
            throw TokenEndpointError.invalidResponse("Token endpoint reply could not be decoded: \(error.localizedDescription)")
        }
    }

    /// application/x-www-form-urlencoded with the RFC 3986 unreserved set, so scopes with ":" and "/" and
    /// codes with "/" survive intact on both providers.
    static func formEncode(_ form: [(name: String, value: String)]) -> String {
        form.map { "\(formEscape($0.name))=\(formEscape($0.value))" }.joined(separator: "&")
    }

    private static let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))

    private static func formEscape(_ text: String) -> String {
        text.addingPercentEncoding(withAllowedCharacters: unreserved) ?? text
    }
}
