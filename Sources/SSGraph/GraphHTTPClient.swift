import Foundation
import os
import SSCore

/// Authenticated transport: attaches the bearer token, retries one 401 after invalidating the token, and maps
/// HTTP failures to `ProviderError` so the provider code only ever handles success payloads.
final class GraphHTTPClient: Sendable {
    /// Immutable ids keep a message's id stable across folder moves. Without this preference every archive would
    /// make the local store drop the message and re-learn it under a new id, losing its cached body.
    static let immutableIDPreference = "IdType=\"ImmutableId\""

    let accountID: AccountID
    let tokens: AccessTokenProvider
    let session: URLSession
    private let log = Logger(subsystem: "io.supersparrow.mac", category: "graph.http")

    init(accountID: AccountID, tokens: AccessTokenProvider, session: URLSession) {
        self.accountID = accountID
        self.tokens = tokens
        self.session = session
    }

    func send(_ request: GraphRequest) async throws -> GraphResponse {
        let (http, data) = try await exchange(request) { urlRequest in
            let probe = SentBytesProbe()
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: urlRequest, delegate: probe)
            } catch let error as URLError {
                // Whether the request left decides whether a send may go again.
                throw ProviderError.transport(error, bytesSent: probe.bytesSent)
            }
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.network("non-HTTP response")
            }
            let succeeded = (200..<300).contains(http.statusCode)
            return (http, succeeded ? nil : data, data)
        }
        return GraphResponse(status: http.statusCode, headers: Self.lowercasedHeaders(http), data: data)
    }

    /// Downloads `request`'s reply into `file` as it arrives instead of buffering it, with `send`'s token retry,
    /// request tally and status mapping. `onBytes` hears the bytes written so far, with the response, after every
    /// chunk of a 2xx body. A file error (the disk is full) is thrown as it is: it is this Mac's failure, not Graph's.
    func download(_ request: GraphRequest, to file: URL,
                  onBytes: @escaping @Sendable (Int64, HTTPURLResponse) -> Void) async throws {
        _ = try await exchange(request) { urlRequest in
            let outcome = try await HTTPDownload.run(urlRequest, session: session, to: file, onBytes: onBytes)
            return (outcome.response, outcome.errorBody, ())
        }
    }

    /// One request with a fresh token: a 401 invalidates the token and earns one retry, and a status outside 2xx
    /// becomes a `ProviderError`. `attempt` sends one try and returns the response, the body when the status failed
    /// (nil when it succeeded) and its result.
    private func exchange<T>(
        _ request: GraphRequest,
        _ attempt: (URLRequest) async throws -> (response: HTTPURLResponse, errorBody: Data?, result: T)
    ) async throws -> (HTTPURLResponse, T) {
        var retriedAuth = false
        while true {
            let token = request.authenticated ? try await tokens.accessToken(for: accountID) : nil
            let urlRequest = makeURLRequest(request, token: token)
            // Every attempt counts, the one a 401 sends again included: Graph may count the refused one too, and
            // over-counting a rare retry only paces the engine a little sooner.
            GraphRequestTally.current?.add(request.countedRequests)
            let reply: (response: HTTPURLResponse, errorBody: Data?, result: T)
            do {
                reply = try await attempt(urlRequest)
            } catch let error as URLError {
                throw ProviderError.transport(error)
            } catch is CancellationError {
                throw ProviderError.cancelled
            } catch let error as ProviderError {
                throw error
            } catch let error as CocoaError {
                throw error
            } catch {
                throw ProviderError.network(error.localizedDescription)
            }
            let http = reply.response
            log.debug("\(request.method.rawValue, privacy: .public) \(request.url.path, privacy: .public) -> \(http.statusCode, privacy: .public)")
            if http.statusCode == 401, request.authenticated {
                // The token looked valid when the token provider handed it out; let it refresh and try once more.
                await tokens.invalidateAccessToken(for: accountID)
                if !retriedAuth {
                    retriedAuth = true
                    continue
                }
                throw ProviderError.unauthorized
            }
            if let body = reply.errorBody {
                throw GraphErrorMapper.error(status: http.statusCode, headers: Self.lowercasedHeaders(http), data: body)
            }
            return (http, reply.result)
        }
    }

    func json<T: Decodable>(_ type: T.Type, for request: GraphRequest) async throws -> T {
        let response = try await send(request)
        return try GraphJSON.decode(T.self, from: response.data)
    }

    /// Runs up to `GraphBatch.maxRequests` calls in one `$batch` round trip. Per-item failures are left to the
    /// caller, which knows which statuses are benign for its operation.
    func batch(_ requests: [GraphBatchRequest]) async throws -> [GraphBatchResponse] {
        let prepared = requests.map { request -> GraphBatchRequest in
            var item = request
            var headers = item.headers ?? [:]
            // The outer Prefer header does not reach inner requests, so each one repeats it.
            headers["Prefer"] = Self.immutableIDPreference
            if item.body != nil, headers["Content-Type"] == nil {
                headers["Content-Type"] = "application/json"
            }
            item.headers = headers
            return item
        }
        let body = try GraphJSON.encode(GraphBatchEnvelope(requests: prepared))
        let response = try await send(GraphRequest(method: .post, url: try GraphURL.make("/$batch"), body: body,
                                                   countedRequests: requests.count))
        return try GraphJSON.decode(GraphBatchResponseEnvelope.self, from: response.data).responses
    }

    private func makeURLRequest(_ request: GraphRequest, token: String?) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        if let token {
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let prefer = (request.immutableIDs ? [Self.immutableIDPreference] : []) + request.prefer
            if !prefer.isEmpty {
                urlRequest.setValue(prefer.joined(separator: ", "), forHTTPHeaderField: "Prefer")
            }
        }
        urlRequest.setValue(request.accept, forHTTPHeaderField: "Accept")
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }
        if let body = request.body {
            urlRequest.httpBody = body
            if request.headers["Content-Type"] == nil {
                urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        return urlRequest
    }

    private static func lowercasedHeaders(_ response: HTTPURLResponse) -> [String: String] {
        var headers: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            headers[name.lowercased()] = value
        }
        return headers
    }
}
