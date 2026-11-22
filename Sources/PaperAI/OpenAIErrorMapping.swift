import Foundation
import PaperCore

/// OpenAI's errors in `AIError`'s words, from an HTTP reply, a `response.failed` event or an `error` event. The `code`
/// decides first, then the `type`, then the status (openai.md §3). A 429 is two different things: a rate limit, worth
/// one retry, or money (no credit, a spend or usage limit), which no retry fixes.
enum OpenAIErrorMapping {
    /// Out of credit: only the billing page fixes it.
    static let noCreditCodes: Set<String> = ["insufficient_quota", "credit_balance_exhausted", "billing_hard_limit_reached",
                                             "billing_not_active"]
    /// A limit the organisation or project set itself.
    static let usageLimitCodes: Set<String> = ["organization_spend_limit_exceeded", "project_spend_limit_exceeded",
                                               "organization_usage_limit_exceeded", "project_usage_limit_exceeded"]
    static let rateLimitCodes: Set<String> = ["rate_limit_exceeded", "slow_down"]
    /// A response that failed on the usage policies: the model declined, in effect.
    static let policyCodes: Set<String> = ["invalid_prompt", "bio_policy", "misalignment_policy_violation"]

    static func map(_ reply: HTTPErrorReply) -> (error: AIError, retryable: Bool) {
        if let mapped = map(code: reply.code, type: reply.type, retryAfter: reply.retryAfter) { return mapped }
        switch reply.status {
        case 401, 403: return (.keyRefused, false)
        case 404: return (.modelUnavailable, false)
        case 429: return (.rateLimited(retryAfter: reply.retryAfter), true)
        case 503: return (.overloaded, true)
        case 500...599: return (.badResponse(code: reply.status), true)
        default: return (.badResponse(code: reply.status), false)
        }
    }

    /// A failure inside the stream: `response.failed`'s `response.error` or an `error` event, neither with a status.
    static func mapStreamError(code: String?, type: String?) -> (error: AIError, retryable: Bool) {
        if let mapped = map(code: code, type: type, retryAfter: nil) { return mapped }
        switch code {
        case "server_error": return (.badResponse(code: 500), true)
        default: return (.badResponse(code: 0), false)
        }
    }

    private static func map(code: String?, type: String?, retryAfter: TimeInterval?) -> (error: AIError, retryable: Bool)? {
        if let code {
            if usageLimitCodes.contains(code) { return (.planLimit, false) }
            if noCreditCodes.contains(code) { return (.noCredit, false) }
            if rateLimitCodes.contains(code) { return (.rateLimited(retryAfter: retryAfter), true) }
            if policyCodes.contains(code) { return (.refused, false) }
            switch code {
            case "invalid_api_key": return (.keyRefused, false)
            case "model_not_found": return (.modelUnavailable, false)
            case "server_is_overloaded": return (.overloaded, true)
            default: break
            }
        }
        switch type {
        case "insufficient_quota": return (.noCredit, false)
        case "service_unavailable_error": return (.overloaded, true)
        default: return nil
        }
    }
}
