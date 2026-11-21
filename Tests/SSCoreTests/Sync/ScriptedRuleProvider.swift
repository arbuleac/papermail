import Foundation
@testable import SSCore

/// A `ScriptedProvider` with server rules (`RuleProvider`), so the engine gives its account a rules lane. It keeps rules of
/// its own, as a server would: a create adds one (a second identical rule is a second rule, as Exchange allows, so a test
/// sees whether the lane adopts or duplicates), a delete takes one away (one it does not have counts as deleted), and a
/// read lists them with a count of other rules. Scripts fail a call before it does anything, or a create after its rule is
/// made (the reply lost); holds keep a call waiting. A scripted `RuleProviderError.permissionMissing` takes the grant away
/// too, as a token that lacks the scope would also say it lacks it. Every call is recorded, in one log too, in order.
final class ScriptedRuleProvider: ScriptedProvider, RuleProvider, @unchecked Sendable {
    enum CreateScript {
        /// Makes the rule and returns its id.
        case make
        /// Throws before anything is made.
        case fail(Error)
        /// Makes the rule, then throws: the server has it, the engine never heard.
        case loseReply(Error)
    }

    // MARK: Scripts

    var grantsRules: Bool {
        get { locked { scriptedGrant } }
        set { locked { scriptedGrant = newValue } }
    }
    /// One per read, in order; nil lets that read through. Once empty every read goes through.
    var readResults: [Error?] {
        get { locked { scriptedReads } }
        set { locked { scriptedReads = newValue } }
    }
    /// One per create, in order; once empty every create makes its rule.
    var createScripts: [CreateScript] {
        get { locked { scriptedCreates } }
        set { locked { scriptedCreates = newValue } }
    }
    /// One per delete, in order; nil lets that delete through. Once empty every delete goes through.
    var deleteResults: [Error?] {
        get { locked { scriptedDeletes } }
        set { locked { scriptedDeletes = newValue } }
    }
    /// The other rules every read reports.
    var otherRules: Int {
        get { locked { scriptedOthers } }
        set { locked { scriptedOthers = newValue } }
    }
    /// The requests each read reports.
    var requestsPerRead: Int {
        get { locked { scriptedRequests } }
        set { locked { scriptedRequests = newValue } }
    }
    /// While set, a read records the call and then waits until it is cleared (or the task is cancelled).
    var holdReads: Bool {
        get { locked { scriptedHoldReads } }
        set { locked { scriptedHoldReads = newValue } }
    }
    /// While set, a create records the call and then waits until it is cleared (or the task is cancelled), before it
    /// makes anything.
    var holdCreates: Bool {
        get { locked { scriptedHoldCreates } }
        set { locked { scriptedHoldCreates = newValue } }
    }

    private var scriptedGrant = true
    private var scriptedReads: [Error?] = []
    private var scriptedCreates: [CreateScript] = []
    private var scriptedDeletes: [Error?] = []
    private var scriptedOthers = 0
    private var scriptedRequests = 1
    private var scriptedHoldReads = false
    private var scriptedHoldCreates = false

    // MARK: The server's rules

    /// What the server holds, in its order.
    var rulesOnServer: [ServerSenderRule] { locked { held } }
    private var held: [ServerSenderRule] = []
    private var made = 0

    /// Puts a rule made elsewhere (on the web, another device) on the server. Returns its id.
    @discardableResult
    func seedRule(_ address: String, _ action: SenderRule.Action) -> String {
        locked {
            made += 1
            let id = "seed-\(made)"
            held.append(ServerSenderRule(serverID: id, address: address, action: action))
            return id
        }
    }

    /// Takes a rule off the server, as a user deleting it on the web does.
    func removeRule(_ id: String) {
        locked { held.removeAll { $0.serverID == id } }
    }

    // MARK: Recordings

    var rulesPermissionChecks: Int { locked { recordedChecks } }
    var reads: Int { locked { recordedReads } }
    var createCalls: [String] { locked { recordedCreates } }
    var deleteCalls: [String] { locked { recordedDeletes } }
    /// Every write in order: "create <address> <action>", "delete <id>".
    var writeLog: [String] { locked { recordedWrites } }

    private var recordedChecks = 0
    private var recordedReads = 0
    private var recordedCreates: [String] = []
    private var recordedDeletes: [String] = []
    private var recordedWrites: [String] = []

    // MARK: RuleProvider

    func hasRulesPermission() async -> Bool {
        locked {
            recordedChecks += 1
            return scriptedGrant
        }
    }

    func serverRules() async throws -> ServerRuleListing {
        locked { recordedReads += 1 }
        while locked({ scriptedHoldReads }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let (failure, listing): (Error?, ServerRuleListing) = locked {
            let failure = scriptedReads.isEmpty ? nil : scriptedReads.removeFirst()
            return (failure, ServerRuleListing(senderRules: held, otherCount: scriptedOthers, requestCount: scriptedRequests))
        }
        if let failure { throw revoking(failure) }
        return listing
    }

    func createSenderRule(address: String, action: SenderRule.Action) async throws -> String {
        let call = "create \(address) \(action.rawValue)"
        locked {
            recordedCreates.append(call)
            recordedWrites.append(call)
        }
        while locked({ scriptedHoldCreates }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let script: CreateScript = locked { scriptedCreates.isEmpty ? .make : scriptedCreates.removeFirst() }
        if case .fail(let error) = script { throw revoking(error) }
        let id: String = locked {
            made += 1
            let id = "rule-\(made)"
            held.append(ServerSenderRule(serverID: id, address: address, action: action))
            return id
        }
        if case .loseReply(let error) = script { throw error }
        return id
    }

    func deleteRule(serverID: String) async throws {
        let failure: Error? = locked {
            recordedDeletes.append(serverID)
            recordedWrites.append("delete \(serverID)")
            return scriptedDeletes.isEmpty ? nil : scriptedDeletes.removeFirst()
        }
        if let failure { throw revoking(failure) }
        locked { held.removeAll { $0.serverID == serverID } }
    }

    private func revoking(_ error: Error) -> Error {
        if case .permissionMissing? = error as? RuleProviderError { grantsRules = false }
        return error
    }

    func releaseReads() {
        holdReads = false
    }
}
