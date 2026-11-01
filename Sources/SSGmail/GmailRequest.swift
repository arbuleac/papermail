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
    /// Media uploads (large sends) live under a separate prefix on the same host.
    static let uploadPathPrefix = "/upload/gmail/v1/users/me"
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
        GmailRequest(
            method: .post,
            url: try apiURL(resource, query: []),
            headers: ["Content-Type": "application/json; charset=UTF-8"],
            body: try encode(body)
        )
    }

    /// A multipart upload (`uploadType=multipart`): the resource's JSON metadata followed by the media bytes
    /// as they are, for payloads the JSON endpoint would reject as too large.
    static func upload<Metadata: Encodable>(_ resource: String, metadata: Metadata, media: Data, mediaType: String) throws -> GmailRequest {
        let boundary = "ss_upload_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".utf8))
        body.append(try encode(metadata))
        body.append(Data("\r\n--\(boundary)\r\nContent-Type: \(mediaType)\r\n\r\n".utf8))
        body.append(media)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let endpoint = try url(host: apiHost, path: uploadPathPrefix + "/" + resource, query: [URLQueryItem(name: "uploadType", value: "multipart")])
        return GmailRequest(
            method: .post,
            url: endpoint,
            headers: ["Content-Type": "multipart/related; boundary=\(boundary)"],
            body: body
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

    private static func encode<Body: Encodable>(_ body: Body) throws -> Data {
        do {
            return try JSONEncoder().encode(body)
        } catch {
            throw ProviderError.decoding("Could not encode request body: \(error)")
        }
    }

    private static func apiURL(_ resource: String, query: [URLQueryItem]) throws -> URL {
        try url(host: apiHost, path: apiPathPrefix + "/" + resource, query: query)
    }

    static func batchURL() throws -> URL {
        try url(host: batchHost, path: batchPath, query: [])
    }

    private static func url(host: String, path: String, query: [URLQueryItem]) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        // URLComponents leaves '+' alone in query values, but Google reads a bare '+' as a space, so a search
        // for "c++" or "me+tag@example.com" would change meaning in transit without this.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else {
            throw ProviderError.network("Could not build Gmail URL for \(path)")
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
