import Foundation
import os
import PaperCore

/// Health and Check for the API-key providers. Health reads only whether a key is stored (no Keychain prompt, no
/// network); Check sends the key, and nothing else, to the provider's cheapest authenticated call, `GET /v1/models`.
enum HTTPKeyCheck {
    static let addKey = "Add your API key"
    static let keychainUnreadable = "The Keychain couldn't be read"

    private static var logger: Logger { Logger(subsystem: AppIdentity.bundleIdentifier, category: "ai") }

    /// “Ready · Claude Opus 5.5”: the status line's words for a usable key and model.
    static func readyWords(kind: AIProviderKind, model: String) -> String {
        "Ready · \(title(kind: kind, model: model))"
    }

    /// The model's popup title, or its id when this build has no title for it.
    static func title(kind: AIProviderKind, model: String) -> String {
        kind.modelChoices.first { $0.model == model }?.title ?? model
    }

    static func health(kind: AIProviderKind, model: String, keys: any AIKeyStoring) -> AIHealth {
        do {
            return try keys.hasKey(for: kind) ? .ready(detail: readyWords(kind: kind, model: model)) : .needsSetup(reason: addKey)
        } catch {
            return .unavailable(reason: keychainUnreadable)
        }
    }

    /// Sends `request(key)` and reads the answer: ready when the key works and the model is listed (or the list is not
    /// known to be complete), needs setup when the key is refused or the model is not offered to it.
    static func check(kind: AIProviderKind, model: String, keys: any AIKeyStoring, session: URLSession, action: AIUserAction,
                      request: (String) -> URLRequest,
                      mapReply: (HTTPErrorReply) -> (error: AIError, retryable: Bool)) async -> AIHealth {
        let key: String?
        do {
            key = try keys.key(for: kind)
        } catch {
            return .unavailable(reason: keychainUnreadable)
        }
        guard let key, !key.isEmpty else { return .needsSetup(reason: addKey) }
        do {
            let urlRequest = request(key)
            let (data, response) = try await ProviderHTTP.data(for: urlRequest, on: session, by: action)
            guard let http = response as? HTTPURLResponse else {
                return .unavailable(reason: AIError.badResponse(code: 0).message(for: kind))
            }
            logger.debug("\(kind.rawValue, privacy: .public) key check: HTTP \(http.statusCode, privacy: .public)")
            guard (200...299).contains(http.statusCode) else {
                let error = mapReply(HTTPErrorReply(response: http, body: data)).error
                let words = error.message(for: kind)
                return error.needsSettings ? .needsSetup(reason: words) : .unavailable(reason: words)
            }
            if let listed = listedModels(in: data), !listed.contains(model) {
                return .needsSetup(reason: "\(title(kind: kind, model: model)) isn't available with this key. Choose another model.")
            }
            return .ready(detail: readyWords(kind: kind, model: model))
        } catch {
            return .unavailable(reason: AIError.from(error).message(for: kind))
        }
    }

    /// The model ids a `/v1/models` page lists, when it is the whole list (`has_more` absent or false); nil when the
    /// body is not such a list or more pages follow, so a model on a later page is never called unavailable.
    static func listedModels(in data: Data) -> Set<String>? {
        guard let object = HTTPJSON.object(data), let entries = object["data"] as? [[String: Any]] else { return nil }
        if (object["has_more"] as? Bool) == true { return nil }
        return Set(entries.compactMap { $0["id"] as? String })
    }
}
