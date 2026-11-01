import Foundation
import SSCore

/// One HTTP call to Google, described before a token is attached so the client can retry it with a fresh one.
struct GmailRequest: Sendable {
    enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
    }

    var method: Method
    var url: URL
    var headers: [String: String]
    var body: Data?

    static let apiHost = "gmail.googleapis.com"
    static let apiPathPrefix = "/gmail/v1/users/me"
    static let batchHost = "www.googleapis.com"
    static let batchPath = "/batch/gmail/v1"

    /// The header set every metadata fetch asks for; kept in one place so batch and single gets agree.
    static let metadataHeaderNames = [
        "From", "To", "Cc", "Bcc", "Reply-To", "Subject", "Date", "Message-ID", "In-Reply-To", "References",
    ]

    static func get(_ resource: String, query: [URLQueryItem] = []) throws -> GmailRequest {
        GmailRequest(method: .get, url: try apiURL(resource, query: query), headers: [:], body: nil)
    }

    static func post<Body: Encodable>(_ resource: String, json body: Body) throws -> GmailRequest {
        let data: Data
        do {
            data = try JSONEncoder().encode(body)
        } catch {
            throw ProviderError.decoding("Could not encode request body: \(error)")
        }
        return GmailRequest(
            method: .post,
            url: try apiURL(resource, query: []),
            headers: ["Content-Type": "application/json; charset=UTF-8"],
            body: data
        )
    }

    /// Query string for `messages.get` that returns headers only; `metadataHeaders` repeats per header name.
    static func metadataQuery() -> [URLQueryItem] {
        [URLQueryItem(name: "format", value: "metadata")]
            + metadataHeaderNames.map { URLQueryItem(name: "metadataHeaders", value: $0) }
    }

    /// Path-and-query form of a metadata get, as embedded in a batch request line.
    static func metadataPath(for messageID: String) -> String {
        var components = URLComponents()
        components.path = apiPathPrefix + "/messages/" + messageID
        components.queryItems = metadataQuery()
        return components.string ?? components.path
    }

    private static func apiURL(_ resource: String, query: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = apiHost
        components.path = apiPathPrefix + "/" + resource
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else {
            throw ProviderError.network("Could not build Gmail URL for \(resource)")
        }
        return url
    }

    static func batchURL() throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = batchHost
        components.path = batchPath
        guard let url = components.url else {
            throw ProviderError.network("Could not build Gmail batch URL")
        }
        return url
    }

    func urlRequest(token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}
