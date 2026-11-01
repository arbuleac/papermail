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
        var retriedAuth = false
        while true {
            let token = try await tokens.accessToken(for: accountID)
            let urlRequest = makeURLRequest(request, token: token)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: urlRequest)
            } catch let error as URLError where error.code == .cancelled {
                throw ProviderError.cancelled
            } catch is CancellationError {
                throw ProviderError.cancelled
            } catch {
                throw ProviderError.network(error.localizedDescription)
            }
            guard let http = response as? HTTPURLResponse else {
                throw ProviderError.network("non-HTTP response")
            }
            let headers = Self.lowercasedHeaders(http)
            log.debug("\(request.method.rawValue, privacy: .public) \(request.url.path, privacy: .public) -> \(http.statusCode, privacy: .public)")
            if http.statusCode == 401 {
                // The token looked valid when the token provider handed it out; let it refresh and try once more.
                await tokens.invalidateAccessToken(for: accountID)
                if !retriedAuth {
                    retriedAuth = true
                    continue
                }
                throw ProviderError.unauthorized
            }
            guard (200..<300).contains(http.statusCode) else {
                throw GraphErrorMapper.error(status: http.statusCode, headers: headers, data: data)
            }
            return GraphResponse(status: http.statusCode, headers: headers, data: data)
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
        let response = try await send(GraphRequest(method: .post, url: try GraphURL.make("/$batch"), body: body))
        return try GraphJSON.decode(GraphBatchResponseEnvelope.self, from: response.data).responses
    }

    private func makeURLRequest(_ request: GraphRequest, token: String) -> URLRequest {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method.rawValue
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(request.accept, forHTTPHeaderField: "Accept")
        urlRequest.setValue(([Self.immutableIDPreference] + request.prefer).joined(separator: ", "), forHTTPHeaderField: "Prefer")
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
