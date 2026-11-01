import Foundation
import SSCore

/// Sends authenticated requests to Google and turns HTTP outcomes into `ProviderError`, so the provider
/// methods above it only ever see decoded JSON or a policy-ready error.
struct GmailHTTPClient: Sendable {
    struct Response {
        var status: Int
        var data: Data
        var http: HTTPURLResponse
    }

    let accountID: AccountID
    let tokens: AccessTokenProvider
    let session: URLSession

    /// Runs `attempt` with a fresh token; a 401 invalidates the token and earns exactly one retry, after
    /// which the account is reported as needing re-authentication.
    func withAuthRetry<T>(_ attempt: (String) async throws -> T) async throws -> T {
        var retried = false
        while true {
            let token = try await tokens.accessToken(for: accountID)
            do {
                return try await attempt(token)
            } catch ProviderError.unauthorized {
                await tokens.invalidateAccessToken(for: accountID)
                if retried { throw ProviderError.unauthorized }
                retried = true
            }
        }
    }

    func send(_ request: GmailRequest) async throws -> Response {
        try await withAuthRetry { token in
            try await sendOnce(request, token: token)
        }
    }

    func json<T: Decodable>(_ type: T.Type, for request: GmailRequest) async throws -> T {
        let response = try await send(request)
        return try Self.decode(type, from: response.data)
    }

    /// One attempt with a given token. Non-2xx statuses become errors here; the auth retry lives above.
    func sendOnce(_ request: GmailRequest, token: String) async throws -> Response {
        let urlRequest = request.urlRequest(token: token)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch let error as URLError where error.code == .cancelled {
            throw ProviderError.cancelled
        } catch let error as URLError {
            throw ProviderError.network(error.localizedDescription)
        } catch is CancellationError {
            throw ProviderError.cancelled
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.network(String(describing: error))
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network("Response was not HTTP")
        }
        if let error = Self.error(status: http.statusCode, body: data, retryAfter: http.value(forHTTPHeaderField: "Retry-After")) {
            throw error
        }
        return Response(status: http.statusCode, data: data, http: http)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ProviderError.decoding("\(T.self): \(error)")
        }
    }

    // MARK: Status mapping

    /// Shared by top-level responses and the embedded responses of a batch, which carry the same shapes.
    static func error(status: Int, body: Data, retryAfter: String?) -> ProviderError? {
        switch status {
        case 200..<300:
            return nil
        case 401:
            return .unauthorized
        case 403:
            if isRateLimit(body) { return .throttled(retryAfter: parseRetryAfter(retryAfter)) }
            return .server(status: status, message: errorMessage(body))
        case 404:
            return .notFound
        case 429:
            return .throttled(retryAfter: parseRetryAfter(retryAfter))
        default:
            return .server(status: status, message: errorMessage(body))
        }
    }

    /// Google reports quota exhaustion as 403 with a reason code rather than 429.
    private static func isRateLimit(_ body: Data) -> Bool {
        guard let envelope = try? JSONDecoder().decode(GmailErrorEnvelope.self, from: body) else { return false }
        let reasons = (envelope.error.errors ?? []).compactMap(\.reason)
        if reasons.contains(where: { $0 == "rateLimitExceeded" || $0 == "userRateLimitExceeded" }) { return true }
        return envelope.error.status == "RESOURCE_EXHAUSTED"
    }

    private static func errorMessage(_ body: Data) -> String {
        if let envelope = try? JSONDecoder().decode(GmailErrorEnvelope.self, from: body),
           let message = envelope.error.message {
            return message
        }
        let text = String(decoding: body.prefix(200), as: UTF8.self)
        return text.isEmpty ? "HTTP error" : text
    }

    /// `Retry-After` is either delay-seconds or an HTTP-date; both are honored.
    static func parseRetryAfter(_ value: String?) -> TimeInterval? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }
}
