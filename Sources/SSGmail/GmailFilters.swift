import Foundation
import SSCore
import os

/// Sender rules as Gmail filters (`users.settings.filters`, docs/ARCHITECTURE.md "Rules"): Gmail runs them as mail
/// arrives, whether or not this Mac is on. Only filters of exactly the shape this app makes are read as sender rules (one
/// address in `from` and nothing else; archive: the Inbox label removed, nothing added; block: the Trash label added,
/// perhaps the Inbox removed, nothing else); every other filter is counted and left alone. Every call needs
/// `gmail.settings.basic` and spends Gmail's quota, which the engine charges.
extension GmailProvider: RuleProvider {
    static let filtersResource = "settings/filters"
    static let inboxLabel = "INBOX"
    static let trashLabel = "TRASH"

    private static let filterLog = Logger(subsystem: "io.supersparrow.mac", category: "gmail")

    /// Read from the scopes the token was granted, which come with it: no request.
    public func hasRulesPermission() async -> Bool {
        OAuthEndpoints.grants(await http.tokens.grantedScopes(for: accountID), .rules, kind: .gmail)
    }

    /// One request: `filters.list` returns every filter at once (Gmail allows a thousand), with no pages to follow.
    public func serverRules() async throws -> ServerRuleListing {
        let filters = try await listFilters()
        var rules: [ServerSenderRule] = []
        var others = 0
        for filter in filters {
            if let rule = Self.senderRule(from: filter) {
                rules.append(rule)
            } else {
                others += 1
            }
        }
        Self.filterLog.debug("filters read: \(rules.count, privacy: .public) sender rules, \(others, privacy: .public) others")
        return ServerRuleListing(senderRules: rules, otherCount: others, requestCount: 1)
    }

    /// Creates the filter in the exact shape `senderRule(from:)` recognizes. Gmail refuses a filter identical to one it
    /// has ("Filter already exists"), which a create sent again after a lost reply meets: that filter is the rule, and
    /// its id is read back rather than a refusal reported.
    public func createSenderRule(address: String, action: SenderRule.Action) async throws -> String {
        let body = Self.filterBody(address: address, action: action)
        do {
            let request = try GmailRequest.post(Self.filtersResource, json: body, kind: .settings)
            let response = try await http.send(request, refusal: Self.filterRefusal)
            let created = try GmailHTTPClient.decode(GmailFilterCreated.self, from: response.data)
            guard let id = created.id, !id.isEmpty else { throw ProviderError.decoding("Gmail filter: the created filter has no id") }
            return id
        } catch is GmailFilterAlreadyExists {
            let wanted = ServerSenderRule.singleAddress(address)
            let existing = try await listFilters().compactMap(Self.senderRule(from:))
                .first { $0.address == wanted && $0.action == action }
            guard let existing else { throw RuleProviderError.refused }
            return existing.serverID
        }
    }

    /// A filter Gmail no longer has (404) counts as deleted.
    public func deleteRule(serverID: String) async throws {
        guard !serverID.isEmpty else { return }
        do {
            let request = try GmailRequest.delete(Self.filtersResource + "/" + Self.pathComponent(serverID), kind: .settings)
            _ = try await http.send(request, refusal: Self.filterRefusal)
        } catch ProviderError.notFound {
            Self.filterLog.debug("filter delete: already gone")
        }
    }

    // MARK: Recognition

    /// The sender rule a filter is, or nil when it is anything more or less (docs/ARCHITECTURE.md, "Rules"): criteria of
    /// `from` alone (Chat's exclusion allowed), holding one address; an action that removes the Inbox label and adds
    /// nothing (archive), or adds the Trash label and nothing else, removing at most the Inbox (block); never a forward.
    static func senderRule(from filter: GmailFilterResource) -> ServerSenderRule? {
        guard let id = filter.id, !id.isEmpty, let criteria = filter.criteria, let action = filter.action else { return nil }
        let setCriteria = Set(criteria.filter { $0.value.isSet }.keys).subtracting(["excludeChats"])
        guard setCriteria == ["from"], let from = criteria["from"]?.stringValue,
              let address = ServerSenderRule.singleAddress(from) else { return nil }
        let setActions = Set(action.filter { $0.value.isSet }.keys)
        guard setActions.isSubset(of: ["addLabelIds", "removeLabelIds"]) else { return nil }
        guard let added = Self.labels(action["addLabelIds"]), let removed = Self.labels(action["removeLabelIds"]) else { return nil }
        if added.isEmpty, removed == [inboxLabel] {
            return ServerSenderRule(serverID: id, address: address, action: .archive)
        }
        if added == [trashLabel], removed.isSubset(of: [inboxLabel]) {
            return ServerSenderRule(serverID: id, address: address, action: .trash)
        }
        return nil
    }

    /// The label ids of an action's list; empty when absent, nil when it is not a list of strings.
    private static func labels(_ value: GmailJSONValue?) -> Set<String>? {
        guard let value, value.isSet else { return [] }
        return value.strings.map(Set.init)
    }

    /// Exactly what `senderRule(from:)` reads back as `action`.
    static func filterBody(address: String, action: SenderRule.Action) -> GmailFilterInsert {
        switch action {
        case .archive:
            return GmailFilterInsert(criteria: .init(from: address), action: .init(removeLabelIds: [inboxLabel]))
        case .trash:
            return GmailFilterInsert(criteria: .init(from: address), action: .init(addLabelIds: [trashLabel]))
        }
    }

    // MARK: Requests

    private func listFilters() async throws -> [GmailFilterResource] {
        let request = try GmailRequest.get(Self.filtersResource, query: [URLQueryItem(name: "prettyPrint", value: "false")],
                                           kind: .settings)
        let response = try await http.send(request, refusal: Self.filterRefusal)
        return try GmailHTTPClient.decode(GmailFilterList.self, from: response.data).filter ?? []
    }

    /// Gmail's refusals of a filter call that the user can act on, read before the shared mapping folds them into
    /// `.server`: a token without the settings scope (a reconnect asks for it), the cap on filters, a filter Gmail already
    /// has, and any other permanent 4xx. A throttle (a 403 for a rate limit, a 429) and the statuses the shared mapping
    /// gives meaning to (401, 404, 408) are left to it; Google's daily and project quotas are throttles too, waited out.
    static func filterRefusal(status: Int, body: Data) -> Error? {
        guard (400..<500).contains(status), ![401, 404, 408, 429].contains(status), !GmailHTTPClient.isRateLimit(body) else {
            return nil
        }
        let reasons = Set(GoogleErrorReasons.reasons(in: body))
        if !reasons.isDisjoint(with: ["dailyLimitExceeded", "quotaExceeded", "RATE_LIMIT_EXCEEDED"]) {
            return ProviderError.throttled(retryAfter: GmailHTTPClient.retryDelay(inBody: body))
        }
        if status == 403, !reasons.isDisjoint(with: ["insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT"]) {
            return RuleProviderError.permissionMissing
        }
        let message = errorMessage(body).lowercased()
        if message.contains("already exists") { return GmailFilterAlreadyExists() }
        if message.contains("too many") || message.contains("limit") || message.contains("maximum") {
            return RuleProviderError.limitReached
        }
        filterLog.notice("Gmail refused a filter call: HTTP \(status, privacy: .public), reasons \(reasons.sorted().joined(separator: ","), privacy: .public)")
        return RuleProviderError.refused
    }

    private static func errorMessage(_ body: Data) -> String {
        struct Envelope: Decodable {
            struct Inner: Decodable { var message: String? }
            var error: Inner
        }
        return (try? JSONDecoder().decode(Envelope.self, from: body))?.error.message ?? ""
    }
}

/// Gmail's refusal of a filter identical to one it has: the create sent again after a lost reply, whose filter is there.
struct GmailFilterAlreadyExists: Error {}
