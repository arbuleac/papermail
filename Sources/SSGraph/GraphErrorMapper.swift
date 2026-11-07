import Foundation
import os
import SSCore

/// Translates Graph's HTTP status codes and error bodies into the engine's `ProviderError` vocabulary.
enum GraphErrorMapper {
    /// Throttles are logged here, where the response is still in hand: the engine only sees `throttled`, and
    /// Graph's error code tells a per-app limit from a per-mailbox one or a service-wide brownout.
    private static let log = Logger(subsystem: "io.supersparrow.mac", category: "graph")

    /// Codes Graph uses when a delta token can no longer be honored; the only fix is a fresh enumeration.
    static let resetCodes: Set<String> = ["SyncStateNotFound", "SyncStateInvalid", "ErrorInvalidSyncStateData"]

    static func error(status: Int, headers: [String: String], data: Data) -> ProviderError {
        let envelope = try? JSONDecoder().decode(GraphErrorEnvelope.self, from: data)
        return error(status: status, retryAfter: headers["retry-after"], code: envelope?.error?.code, message: envelope?.error?.message)
    }

    static func error(status: Int, headers: [String: String], body: GraphJSONValue?) -> ProviderError {
        let inner = body?.objectValue?["error"]?.objectValue
        let retryAfter = headers.first { $0.key.lowercased() == "retry-after" }?.value
        return error(status: status, retryAfter: retryAfter, code: inner?["code"]?.stringValue, message: inner?["message"]?.stringValue)
    }

    static func error(status: Int, retryAfter: String?, code: String?, message: String?) -> ProviderError {
        if let code, resetCodes.contains(code) { return .resetRequired }
        switch status {
        case 401:
            return .unauthorized
        case 404:
            return .notFound
        case 410:
            return .resetRequired
        case 429:
            return throttled(status: status, retryAfter: retryAfter, code: code)
        case 503 where retryAfter != nil:
            // Graph also throttles with a 503 when the service itself is under load; the Retry-After marks it as
            // a throttle to wait out rather than a failure to retry on the network backoff.
            return throttled(status: status, retryAfter: retryAfter, code: code)
        case 503, 504:
            return .network("HTTP \(status)\(code.map { " \($0)" } ?? "")")
        default:
            return .server(status: status, message: describe(code: code, message: message))
        }
    }

    /// One notice line per throttled response. Status, code and Retry-After describe the limit, never the mail.
    private static func throttled(status: Int, retryAfter: String?, code: String?) -> ProviderError {
        log.notice("throttled: HTTP \(status, privacy: .public) \(code ?? "no code", privacy: .public), Retry-After \(retryAfter ?? "none", privacy: .public)")
        return .throttled(retryAfter: retryAfter.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
    }

    private static func describe(code: String?, message: String?) -> String {
        [code, message].compactMap { $0 }.joined(separator: ": ")
    }
}
