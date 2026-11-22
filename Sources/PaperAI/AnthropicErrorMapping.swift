import Foundation
import PaperCore

/// Anthropic's errors in `AIError`'s words, from an HTTP reply or a mid-stream `event: error`. The error `type` decides
/// when the body has one (it is what the API documents per status), the status otherwise. Retryable: rate limits,
/// overload and server errors; never a refused key, a missing model or a bad request, which would fail the same way.
enum AnthropicErrorMapping {
    static func map(_ reply: HTTPErrorReply) -> (error: AIError, retryable: Bool) {
        if let mapped = map(type: reply.type, retryAfter: reply.retryAfter, status: reply.status) { return mapped }
        switch reply.status {
        case 401, 403: return (.keyRefused, false)
        case 402: return (.noCredit, false)
        case 404: return (.modelUnavailable, false)
        case 429: return (.rateLimited(retryAfter: reply.retryAfter), true)
        case 529: return (.overloaded, true)
        case 500...599: return (.badResponse(code: reply.status), true)
        default: return (.badResponse(code: reply.status), false)
        }
    }

    /// A mid-stream `event: error` (`{"type":"error","error":{"type":"overloaded_error",…}}`): no status, no retry-after.
    static func mapStreamError(type: String?) -> (error: AIError, retryable: Bool) {
        map(type: type, retryAfter: nil, status: nil) ?? (.badResponse(code: 0), false)
    }

    private static func map(type: String?, retryAfter: TimeInterval?, status: Int?) -> (error: AIError, retryable: Bool)? {
        switch type {
        case "authentication_error", "permission_error": return (.keyRefused, false)
        case "billing_error": return (.noCredit, false)
        case "not_found_error": return (.modelUnavailable, false)
        case "rate_limit_error": return (.rateLimited(retryAfter: retryAfter), true)
        case "overloaded_error": return (.overloaded, true)
        case "api_error", "timeout_error": return (.badResponse(code: status ?? 500), true)
        case "invalid_request_error": return (.badResponse(code: status ?? 400), false)
        case "request_too_large": return (.badResponse(code: status ?? 413), false)
        default: return nil
        }
    }
}
