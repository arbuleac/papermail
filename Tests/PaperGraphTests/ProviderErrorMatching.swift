import Foundation
import PaperCore

/// `ProviderError` is not Equatable; these predicates keep assertions readable.
extension ProviderError {
    var isResetRequired: Bool {
        if case .resetRequired = self { return true }
        return false
    }

    var isUnauthorized: Bool {
        if case .unauthorized = self { return true }
        return false
    }

    var isNotFound: Bool {
        if case .notFound = self { return true }
        return false
    }

    var isNetwork: Bool {
        if case .network = self { return true }
        return false
    }

    var isDecoding: Bool {
        if case .decoding = self { return true }
        return false
    }

    var isThrottled: Bool {
        if case .throttled = self { return true }
        return false
    }

    var retryAfter: TimeInterval? {
        if case .throttled(let value) = self { return value }
        return nil
    }

    var serverStatus: Int? {
        if case .server(let status, _) = self { return status }
        return nil
    }

    var serverMessage: String? {
        if case .server(_, let message) = self { return message }
        return nil
    }
}
