import Foundation
import SSCore

/// Sender rules as Outlook inbox rules (`/me/mailFolders/inbox/messageRules`, docs/ARCHITECTURE.md "Rules"): Exchange
/// runs them as mail arrives, whether or not this Mac is on. Only enabled rules of exactly the shape this app makes are
/// read as sender rules (one address in `fromAddresses` and no other condition or exception; archive: a move to the
/// Archive folder; block: a delete, never a permanent one; either with at most "stop processing more rules"); every other
/// rule is counted and left alone. Every call needs `MailboxSettings.ReadWrite` and counts against the mailbox's request
/// limit as mail does.
extension GraphProvider: RuleProvider {
    static let rulesPath = "/me/mailFolders/inbox/messageRules"
    /// A listing that never ends (a nextLink that keeps coming back) fails rather than spend the mailbox's requests for
    /// ever: Exchange keeps inbox rules within a 256 KB quota, a few hundred rules at most.
    static let maxRulePages = 10

    /// From the scopes the token came with: no request.
    public func hasRulesPermission() async -> Bool {
        OAuthEndpoints.grants(await client.tokens.grantedScopes(for: accountID), .rules, kind: .microsoft)
    }

    public func serverRules() async throws -> ServerRuleListing {
        do {
            let ((rules, archive), sent) = try await GraphRequestTally.counting { () -> ([GraphMessageRule], String?) in
                let rules = try await listRules()
                return (rules, try await archiveFolderID(needed: rules.contains(where: \.movesToFolder)))
            }
            var senderRules: [ServerSenderRule] = []
            var others = 0
            for rule in rules {
                if let senderRule = Self.senderRule(from: rule, archiveFolderID: archive) {
                    senderRules.append(senderRule)
                } else {
                    others += 1
                }
            }
            return ServerRuleListing(senderRules: senderRules, otherCount: others, requestCount: sent)
        } catch {
            throw await rulesError(error)
        }
    }

    /// Creates the rule last in the order (`sequence` after the highest), enabled, stopping the rules after it, under a
    /// name the user can read in Outlook's settings. Reads the rules first for that order, and returns the id of an
    /// identical rule already there rather than make a second (a create sent again after a lost reply). An archive needs
    /// the Archive folder's id, which is never guessed: a mailbox without one refuses the rule.
    public func createSenderRule(address: String, action: SenderRule.Action) async throws -> String {
        do {
            let rules = try await listRules()
            let archive = try await archiveFolderID(needed: action == .archive || rules.contains(where: \.movesToFolder))
            let wanted = ServerSenderRule.singleAddress(address)
            if let existing = rules.lazy.compactMap({ Self.senderRule(from: $0, archiveFolderID: archive) })
                .first(where: { $0.address == wanted && $0.action == action }) {
                return existing.serverID
            }
            let sequence = (rules.compactMap(\.sequence).max() ?? 0) + 1
            guard let payload = Self.rulePayload(address: address, action: action, archiveFolderID: archive, sequence: sequence) else {
                Self.folderLog.notice("rules: an archive rule needs the Archive folder, which this mailbox does not have")
                throw RuleProviderError.refused
            }
            var request = GraphRequest(method: .post, url: try GraphURL.make(Self.rulesPath))
            request.body = try GraphJSON.encode(payload)
            let created = try await client.json(GraphMessageRule.self, for: request)
            guard let id = created.id, !id.isEmpty else { throw ProviderError.decoding("messageRule: the created rule has no id") }
            return id
        } catch {
            throw await rulesError(error)
        }
    }

    public func deleteRule(serverID: String) async throws {
        // An empty id would name the rules collection itself.
        guard !serverID.isEmpty else { return }
        do {
            _ = try await client.send(GraphRequest(method: .delete, url: try Self.ruleURL(serverID)))
        } catch ProviderError.notFound {
            // Deleted already: in Outlook, on another device, or by this call's first try whose reply was lost.
            return
        } catch {
            throw await rulesError(error)
        }
    }

    // MARK: Recognition

    /// The sender rule an inbox rule is, or nil when it is anything more or less: enabled; conditions of `fromAddresses`
    /// alone, holding one address; no exception; actions of a move to the Archive folder (archive) or a delete that is not
    /// permanent (block), each with at most `stopProcessingRules`. A move anywhere else, or anywhere at all while the
    /// Archive folder's id is unknown, is some other rule.
    static func senderRule(from rule: GraphMessageRule, archiveFolderID: String?) -> ServerSenderRule? {
        guard rule.isEnabled == true, let id = rule.id, !id.isEmpty else { return nil }
        guard let conditions = rule.conditions?.objectValue, setKeys(of: conditions) == ["fromAddresses"],
              case .array(let senders)? = conditions["fromAddresses"], senders.count == 1,
              let raw = senders.first?.objectValue?["emailAddress"]?.objectValue?["address"]?.stringValue,
              let address = ServerSenderRule.singleAddress(raw) else { return nil }
        switch rule.exceptions {
        case nil, .null?: break
        case .object(let fields)?: guard setKeys(of: fields).isEmpty else { return nil }
        default: return nil
        }
        guard let actions = rule.actions?.objectValue else { return nil }
        let set = setKeys(of: actions).subtracting(["stopProcessingRules"])
        if set == ["moveToFolder"], let folder = actions["moveToFolder"]?.stringValue, let archiveFolderID, folder == archiveFolderID {
            return ServerSenderRule(serverID: id, address: address, action: .archive)
        }
        if set == ["delete"], actions["delete"] == .bool(true) {
            return ServerSenderRule(serverID: id, address: address, action: .trash)
        }
        return nil
    }

    /// The fields that say anything: Graph may spell a predicate or an action it does not apply as null, false or empty.
    /// OData's annotations are not fields of the rule.
    static func setKeys(of fields: [String: GraphJSONValue]) -> Set<String> {
        Set(fields.filter { !$0.key.hasPrefix("@") && isSet($0.value) }.keys)
    }

    private static func isSet(_ value: GraphJSONValue) -> Bool {
        switch value {
        case .null: return false
        case .bool(let flag): return flag
        case .number: return true
        case .string(let text): return !text.isEmpty
        case .array(let values): return !values.isEmpty
        case .object(let fields): return fields.contains { !$0.key.hasPrefix("@") && isSet($0.value) }
        }
    }

    /// Exactly what `senderRule(from:archiveFolderID:)` reads back as `action`; nil for an archive without the Archive
    /// folder's id.
    static func rulePayload(address: String, action: SenderRule.Action, archiveFolderID: String?,
                            sequence: Int) -> GraphMessageRulePayload? {
        let sender = GraphMessageRulePayload.Recipient(emailAddress: .init(address: address))
        switch action {
        case .archive:
            guard let archiveFolderID, !archiveFolderID.isEmpty else { return nil }
            return GraphMessageRulePayload(displayName: "Archive mail from \(address)", sequence: sequence,
                                           conditions: .init(fromAddresses: [sender]),
                                           actions: .init(moveToFolder: archiveFolderID, delete: nil, stopProcessingRules: true))
        case .trash:
            return GraphMessageRulePayload(displayName: "Block \(address)", sequence: sequence,
                                           conditions: .init(fromAddresses: [sender]),
                                           actions: .init(moveToFolder: nil, delete: true, stopProcessingRules: true))
        }
    }

    // MARK: Requests

    private func listRules() async throws -> [GraphMessageRule] {
        var next: URL? = try GraphURL.make(Self.rulesPath)
        var all: [GraphMessageRule] = []
        var pages = 0
        while let url = next {
            guard pages < Self.maxRulePages else {
                throw ProviderError.decoding("messageRules: no end after \(Self.maxRulePages) pages")
            }
            pages += 1
            let page = try await client.json(GraphListResponse<GraphMessageRule>.self, for: GraphRequest(method: .get, url: url))
            all += page.value
            next = try page.nextLink.map(GraphURL.absolute)
        }
        return all
    }

    /// The Archive folder's id from the well-known folder cache, looked up (once) when the cache is empty or has none
    /// (Outlook creates Archive lazily, and the user may have made it since). Nil when the mailbox has none, or when
    /// nothing needs it.
    private func archiveFolderID(needed: Bool) async throws -> String? {
        guard needed else { return nil }
        if let cached = await folderCache.current()?.id("archive") { return cached }
        return try await resolveWellKnownFolders().id("archive")
    }

    /// A rule's own URL. Its id is Exchange's base64, whose `/` and `+` must not split or change the path.
    static func ruleURL(_ id: String) throws -> URL {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~=")
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: try GraphURL.make(rulesPath).absoluteString + "/" + escaped) else {
            throw ProviderError.network("invalid Graph URL for a rule")
        }
        return url
    }

    /// Exchange's refusals the user can act on. A 403 is the missing scope when the token lacks it (a reconnect asks for
    /// it); one the token holds the scope for is a refusal of the organization's, and calling it a missing permission
    /// would ask the user to reconnect again and again to no effect. The rules' quota (a mailbox's rules fit in 256 KB)
    /// is the limit; any other 4xx a refusal. Throttles, the token, the network, the service and a 404 pass as they are.
    private func rulesError(_ error: Error) async -> Error {
        guard case .server(let status, let message)? = error as? ProviderError, (400..<500).contains(status), status != 408 else {
            return error
        }
        if status == 403 {
            guard await hasRulesPermission() else { return RuleProviderError.permissionMissing }
            Self.folderLog.notice("rules: refused (HTTP 403) although the token holds the rules scope")
            return RuleProviderError.refused
        }
        if Self.isRulesQuota(message) { return RuleProviderError.limitReached }
        Self.folderLog.notice("rules: refused (HTTP \(status, privacy: .public) \(Self.code(of: message), privacy: .public))")
        return RuleProviderError.refused
    }

    /// Exchange's quota on a mailbox's rules (`ErrorRulesOverQuota`, `ErrorRulesSizeQuotaExceeded`, or any quota error
    /// that names the rules, in its code or its words). A quota that names no rule (the mailbox full) is some other refusal.
    static func isRulesQuota(_ message: String) -> Bool {
        let text = message.lowercased()
        return text.contains("quota") && text.contains("rule")
    }

    /// Graph's error code, which `GraphErrorMapper` puts before the message.
    private static func code(of message: String) -> String {
        message.split(separator: ":", maxSplits: 1).first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
    }
}
