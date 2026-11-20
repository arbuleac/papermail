import Foundation

/// What an API's error reply said, minus its words: the status, the API's error `type` and `code`, and its retry hints.
/// The `message` is never kept: providers quote the request in it now and then (“Incorrect API key provided: sk-…”),
/// and an error's words must not carry anything the user or the model wrote.
struct HTTPErrorReply: Sendable, Equatable {
    var status: Int
    /// `error.type`: Anthropic's “rate_limit_error”, OpenAI's “insufficient_quota”.
    var type: String?
    /// `error.code`: OpenAI's “invalid_api_key”, “rate_limit_exceeded”; Anthropic sends none.
    var code: String?
    /// Seconds the server asked us to wait (`retry-after-ms`, `retry-after`).
    var retryAfter: TimeInterval?
    /// `x-should-retry`, which both APIs send to override a client's own retry rules; nil when absent.
    var shouldRetry: Bool?

    init(status: Int, type: String? = nil, code: String? = nil, retryAfter: TimeInterval? = nil, shouldRetry: Bool? = nil) {
        self.status = status
        self.type = type
        self.code = code
        self.retryAfter = retryAfter
        self.shouldRetry = shouldRetry
    }

    /// Reads a reply. Both APIs put `{type, code, message}` under `error` (Anthropic also wraps it in
    /// `{"type":"error"}`); a body that is not JSON (a proxy's HTML page) leaves type and code nil, and the status decides.
    init(response: HTTPURLResponse, body: Data, now: Date = Date()) {
        let error = HTTPJSON.dictionary(HTTPJSON.object(body)?["error"])
        self.init(status: response.statusCode,
                  type: HTTPJSON.string(error?["type"]),
                  code: HTTPJSON.string(error?["code"]),
                  retryAfter: HTTPRetryPolicy.retryAfter(in: response, now: now),
                  shouldRetry: Self.shouldRetry(in: response))
    }

    private static func shouldRetry(in response: HTTPURLResponse) -> Bool? {
        switch response.value(forHTTPHeaderField: "x-should-retry")?.trimmingCharacters(in: .whitespaces).lowercased() {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}
