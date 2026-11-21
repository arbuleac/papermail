import Foundation
import SSCore

/// One HTTP call against Graph before the bearer token is attached.
struct GraphRequest: Sendable {
    enum Method: String, Sendable {
        case get = "GET"
        case post = "POST"
        case patch = "PATCH"
        case put = "PUT"
        case delete = "DELETE"
    }

    var method: Method
    var url: URL
    /// Joined into one `Prefer` header next to the immutable-id preference the client always sends.
    var prefer: [String] = []
    var headers: [String: String] = [:]
    var body: Data? = nil
    var accept: String = "application/json"
    /// False for upload-session URLs: they carry their own credential, and Graph refuses a request to them
    /// that also has a bearer token.
    var authenticated = true
    /// What Graph counts against the mailbox's limit each time this is sent: one, or a `$batch` envelope's parts.
    var countedRequests = 1
    /// False for a lookup that needs an id in Graph's default (REST) form rather than the immutable form the client asks
    /// for everywhere else: the Archive folder's id as an inbox rule may name it (`GraphProvider+Rules`).
    var immutableIDs = true
}

/// What came back, with header names lowercased so lookups do not depend on Graph's casing.
struct GraphResponse: Sendable {
    var status: Int
    var headers: [String: String]
    var data: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

/// Builds `/v1.0` URLs in one place so every query string is percent-encoded the same way.
enum GraphURL {
    static let base = "https://graph.microsoft.com/v1.0"

    static func make(_ path: String, query: [(String, String)] = []) throws -> URL {
        guard var components = URLComponents(string: base) else {
            throw ProviderError.network("invalid Graph base URL")
        }
        components.path += path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            // URLComponents leaves '+' alone in query values, but Graph reads a bare '+' as a space, so a search for
            // "c++" or "me+tag@example.com" would change meaning in transit without this.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        guard let url = components.url else {
            throw ProviderError.network("invalid Graph URL for \(path)")
        }
        return url
    }

    /// Links Graph hands back (`@odata.nextLink`, `@odata.deltaLink`) are absolute; anything else is a corrupt cursor.
    static func absolute(_ string: String) throws -> URL {
        guard let url = URL(string: string), url.scheme != nil, url.host != nil else {
            throw ProviderError.decoding("stored link is not an absolute URL")
        }
        return url
    }

    /// For `$batch` inner URLs, which are plain strings and not run through `URLComponents`.
    static func pathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }
}
