import Foundation
import SSCore
import os

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

    private static let log = Logger(subsystem: "io.supersparrow.mac", category: "gmail")

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
        } catch {
            throw Self.transportError(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.network("Response was not HTTP")
        }
        try Self.check(http, body: data, kind: request.kind)
        return Response(status: http.statusCode, data: data, http: http)
    }

    /// Downloads `request`'s reply into `file` as it arrives instead of buffering it, with `send`'s token retry and
    /// status mapping. `onBytes` hears the bytes written so far, with the response, after every chunk of a 2xx
    /// body. A file error (the disk is full) is thrown as it is: it is this Mac's failure, not the provider's.
    func download(_ request: GmailRequest, to file: URL,
                  onBytes: @escaping @Sendable (Int64, HTTPURLResponse) -> Void) async throws {
        try await withAuthRetry { token in
            let outcome: HTTPDownload.Outcome
            do {
                outcome = try await HTTPDownload.run(request.urlRequest(token: token), session: session, to: file, onBytes: onBytes)
            } catch let error as CocoaError {
                throw error
            } catch {
                throw Self.transportError(error)
            }
            if let body = outcome.errorBody {
                try Self.check(outcome.response, body: body, kind: request.kind)
                // `check` throws for every status outside 2xx; this only keeps a reply that is not the file from ever
                // passing as one.
                throw ProviderError.server(status: outcome.response.statusCode, message: Self.errorMessage(body))
            }
        }
    }

    /// What a failed transfer means to the engine: a cancellation, or a network failure worth retrying.
    static func transportError(_ error: Error) -> ProviderError {
        switch error {
        case let error as URLError where error.code == .cancelled: return .cancelled
        case let error as URLError: return .network(error.localizedDescription)
        case is CancellationError: return .cancelled
        case let error as ProviderError: return error
        default: return .network(String(describing: error))
        }
    }

    /// Throws the mapped error for a reply outside 2xx, logging a throttle once.
    private static func check(_ http: HTTPURLResponse, body: Data, kind: GmailRequest.Kind) throws {
        guard let error = error(status: http.statusCode, body: body, retryAfter: http.value(forHTTPHeaderField: "Retry-After")) else {
            return
        }
        if case .throttled(let retryAfter) = error {
            logThrottle(ThrottleDetails(status: http.statusCode, body: body), kind: kind, retryAfter: retryAfter)
        }
        throw error
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
            if isRateLimit(body) { return .throttled(retryAfter: parseRetryAfter(retryAfter) ?? retryDelay(inBody: body)) }
            return .server(status: status, message: errorMessage(body))
        case 404:
            return .notFound
        case 429:
            return .throttled(retryAfter: parseRetryAfter(retryAfter) ?? retryDelay(inBody: body))
        case 502, 503, 504:
            // A gateway or the service failing for now: the network backoff, never an operation's attempt, "slow to
            // respond" on the sync line. A 500 stays a server error, so a message that keeps failing is set aside.
            return .network("HTTP \(status)")
        default:
            return .server(status: status, message: errorMessage(body))
        }
    }

    /// Google reports quota exhaustion as 403 with a reason code rather than 429.
    static func isRateLimit(_ body: Data) -> Bool {
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

    /// Google's per-user quota refusals carry no Retry-After header; the refill time is only in the message
    /// text (“User-rate limit exceeded.  Retry after 2026-11-07T10:30:00.000Z”). Checked in the top-level
    /// message first, then in each error detail's.
    static func retryDelay(inBody body: Data, now: Date = Date()) -> TimeInterval? {
        guard let envelope = try? JSONDecoder().decode(GmailErrorEnvelope.self, from: body) else { return nil }
        let messages = [envelope.error.message] + (envelope.error.errors ?? []).map(\.message)
        for case let message? in messages {
            if let delay = retryDelay(inMessage: message, now: now) { return delay }
        }
        return nil
    }

    /// Seconds from `now` until the RFC 3339 time after “Retry after” in `message`, or nil when that time
    /// has passed. A passed time (clock skew, a stale message) says nothing about when the quota refills;
    /// reporting it as zero would make the engine retry at its base delay instead of backing off.
    static func retryDelay(inMessage message: String, now: Date = Date()) -> TimeInterval? {
        guard let marker = message.range(of: "Retry after", options: .caseInsensitive) else { return nil }
        let token = message[marker.upperBound...].drop(while: \.isWhitespace).prefix { !$0.isWhitespace }
        // The time can end a sentence, so a trailing full stop or bracket is punctuation, not part of it.
        let stamp = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:)]\"'"))
        guard !stamp.isEmpty, let date = rfc3339Date(stamp), date > now else { return nil }
        return date.timeIntervalSince(now)
    }

    private static func rfc3339Date(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    // MARK: Throttle log

    /// What Google said when it throttled a request: its reason codes and status say which limit tripped
    /// (per-user quota, concurrency, project quota), which the mapped `ProviderError` no longer tells apart.
    struct ThrottleDetails: Hashable, Sendable {
        var status: Int
        var reasons: [String]
        var googleStatus: String?
        var message: String?

        init(status: Int, body: Data) {
            self.status = status
            let envelope = try? JSONDecoder().decode(GmailErrorEnvelope.self, from: body)
            reasons = (envelope?.error.errors ?? []).compactMap(\.reason)
            googleStatus = envelope?.error.status
            message = envelope?.error.message
        }
    }

    /// One notice per throttled response, or per group of alike throttled parts of one batch reply. Kinds,
    /// reasons and statuses are Google's fixed vocabulary and public; the message text stays private because
    /// nothing guarantees it never names the account.
    static func logThrottle(_ details: ThrottleDetails, kind: GmailRequest.Kind, retryAfter: TimeInterval?,
                            parts: (throttled: Int, total: Int)? = nil) {
        let scope = parts.map { ", \($0.throttled) of \($0.total) parts" } ?? ""
        let reasons = details.reasons.isEmpty ? "none" : details.reasons.joined(separator: ",")
        let googleStatus = details.googleStatus ?? "none"
        let retry = retryAfter.map { String(format: "%.0f s", $0) } ?? "none"
        let message = details.message ?? ""
        log.notice("""
            Gmail throttled \(kind.rawValue, privacy: .public)\(scope, privacy: .public): HTTP \(details.status, privacy: .public), \
            reasons \(reasons, privacy: .public), status \(googleStatus, privacy: .public), \
            retry after \(retry, privacy: .public), message “\(message, privacy: .private)”
            """)
    }
}
