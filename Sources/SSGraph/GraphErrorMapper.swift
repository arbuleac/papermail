import Foundation
import SSCore

/// Translates Graph's HTTP status codes and error bodies into the engine's `ProviderError` vocabulary.
enum GraphErrorMapper {
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
            return .throttled(retryAfter: retryAfter.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) })
        case 503, 504:
            return .network("HTTP \(status)\(code.map { " \($0)" } ?? "")")
        default:
            return .server(status: status, message: describe(code: code, message: message))
        }
    }

    private static func describe(code: String?, message: String?) -> String {
        [code, message].compactMap { $0 }.joined(separator: ": ")
    }
}
