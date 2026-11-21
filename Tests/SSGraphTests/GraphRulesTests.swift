import Foundation
import SSCore
import XCTest
@testable import SSGraph

/// Sender rules as Outlook inbox rules through Graph (docs/ARCHITECTURE.md, "Rules"): the permission read from the token,
/// every page of `/me/mailFolders/inbox/messageRules` and which rules are sender rules (exactly the shapes the app makes,
/// the archive judged against the Archive folder's id from the well-known folders, never guessed), the exact bodies of a
/// create placed last in the order, a delete that finds the rule gone, and Exchange's refusals mapped to what the engine
/// can act on. Every request goes to the stub protocol.
final class GraphRulesTests: GraphTestCase {
    private static let rulesScopes = "Mail.ReadWrite Mail.Send User.Read MailboxSettings.ReadWrite profile openid"
    private let rulesPath = "/v1.0/me/mailFolders/inbox/messageRules"
    private let nextLink = "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messageRules?%24skiptoken=page2"

    override func setUp() {
        super.setUp()
        tokens.scopes = Self.rulesScopes
    }

    // MARK: Fixtures

    /// One inbox rule as Graph lists it (recorded, anonymized): `conditions`, `actions` and `exceptions` given as JSON.
    static func rule(id: String, sequence: Int, enabled: Bool = true, displayName: String = "Rule",
                     conditions: String, actions: String, exceptions: String? = nil) -> String {
        let exceptionsField = exceptions.map { #", "exceptions": \#($0)"# } ?? ""
        return """
        {"id": "\(id)", "displayName": "\(displayName)", "sequence": \(sequence), "isEnabled": \(enabled), "hasError": false,
         "isReadOnly": false, "conditions": \(conditions), "actions": \(actions)\(exceptionsField)}
        """
    }

    static func from(_ addresses: String...) -> String {
        let senders = addresses.map { #"{"emailAddress": {"name": "\#($0)", "address": "\#($0)"}}"# }
        return #"{"fromAddresses": [\#(senders.joined(separator: ", "))]}"#
    }

    private func page(_ rules: [String], nextLink: String? = nil) -> String {
        let context = #""@odata.context": "https://graph.microsoft.com/v1.0/$metadata#users('x')/mailFolders('inbox')/messageRules""#
        let next = nextLink.map { #", "@odata.nextLink": "\#($0)""# } ?? ""
        return "{\(context), \"value\": [\(rules.joined(separator: ",\n"))]\(next)}"
    }

    /// Four sender rules, then every kind of rule that is not one.
    private var firstPage: [String] {
        [
            Self.rule(id: "AQAAAJ5dZqA=", sequence: 1, displayName: "Archive mail from news@letter.example",
                      conditions: Self.from("news@letter.example"), actions: #"{"moveToFolder": "F-ARCHIVE", "stopProcessingRules": true}"#),
            Self.rule(id: "AQAAAJ5dZqB=", sequence: 2, displayName: "Block deals@shop.example",
                      conditions: Self.from("deals@shop.example"), actions: #"{"delete": true, "stopProcessingRules": true}"#),
            Self.rule(id: "AQAAAJ5d/qC+", sequence: 3, conditions: Self.from("Spam@Junk.Example"), actions: #"{"delete": true}"#),
            Self.rule(id: "AQAAAJ5dZqD=", sequence: 4,
                      conditions: #"{"fromAddresses": [{"emailAddress": {"address": "digest@news.example"}}], "bodyContains": [], "isAutomaticReply": false, "importance": null}"#,
                      actions: #"{"moveToFolder": "F-ARCHIVE", "markAsRead": false, "permanentDelete": false, "forwardTo": []}"#,
                      exceptions: #"{"subjectContains": []}"#),
            Self.rule(id: "AQAAAJ5dZqE=", sequence: 5, enabled: false, conditions: Self.from("off@x.example"),
                      actions: #"{"moveToFolder": "F-ARCHIVE", "stopProcessingRules": true}"#),
            Self.rule(id: "AQAAAJ5dZqF=", sequence: 6, conditions: Self.from("pm@work.example"), actions: #"{"moveToFolder": "F-PROJECTS"}"#),
        ]
    }

    private var lastPage: [String] {
        [
            Self.rule(id: "AQAAAJ5dZqG=", sequence: 7, conditions: Self.from("gone@x.example"), actions: #"{"permanentDelete": true}"#),
            Self.rule(id: "AQAAAJ5dZqH=", sequence: 8, conditions: Self.from("read@x.example"), actions: #"{"delete": true, "markAsRead": true}"#),
            Self.rule(id: "AQAAAJ5dZqI=", sequence: 9, conditions: Self.from("a@x.example", "b@x.example"), actions: #"{"delete": true}"#),
            Self.rule(id: "AQAAAJ5dZqJ=", sequence: 10, conditions: #"{"fromAddresses": [{"emailAddress": {"address": "ci@build.example"}}], "subjectContains": ["failed"]}"#,
                      actions: #"{"moveToFolder": "F-ARCHIVE"}"#),
            Self.rule(id: "AQAAAJ5dZqK=", sequence: 11, conditions: Self.from("team@work.example"), actions: #"{"delete": true}"#,
                      exceptions: #"{"bodyContains": ["urgent"]}"#),
            Self.rule(id: "AQAAAJ5dZqL=", sequence: 12, conditions: Self.from("boss@work.example"),
                      actions: #"{"forwardTo": [{"emailAddress": {"address": "me@other.example"}}]}"#),
            Self.rule(id: "AQAAAJ5dZqM=", sequence: 13, conditions: #"{"sentToMe": true}"#, actions: #"{"delete": true}"#),
            Self.rule(id: "AQAAAJ5dZqN=", sequence: 14, conditions: "null", actions: #"{"delete": true}"#),
            Self.rule(id: "AQAAAJ5dZqO=", sequence: 15, conditions: Self.from("tag@x.example"), actions: #"{"assignCategories": ["Blue"]}"#),
            Self.rule(id: "AQAAAJ5dZqP=", sequence: 16, conditions: Self.from("copy@x.example"),
                      actions: #"{"moveToFolder": "F-ARCHIVE", "copyToFolder": "F-PROJECTS"}"#),
            Self.rule(id: "AQAAAJ5dZqQ=", sequence: 17, conditions: #"{"senderContains": ["deals"]}"#, actions: #"{"delete": true}"#),
            Self.rule(id: "AQAAAJ5dZqR=", sequence: 18, conditions: Self.from("*@x.example"), actions: #"{"delete": true}"#),
        ]
    }

    /// Answers the rules with both pages, and the well-known folders, `missing` among them answering 404.
    private func routeRules(_ first: [String]? = nil, last: [String]? = nil, missing: Set<String> = []) {
        let first = first ?? firstPage
        let last = last ?? lastPage
        route { request in
            if let folder = self.wellKnownFolderReply(request, missing: missing) { return folder }
            guard request.method == "GET", request.path == self.rulesPath else { return nil }
            if request.query["$skiptoken"] == "page2" { return .json(self.page(last)) }
            return .json(self.page(first, nextLink: last.isEmpty ? nil : self.nextLink))
        }
    }

    private func folderLookups() -> [Request] {
        requests.filter { $0.path.hasPrefix("/v1.0/me/mailFolders/") && $0.path != rulesPath && !$0.path.hasPrefix(rulesPath) }
    }

    private func thrown(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            XCTFail("expected an error")
            return nil
        } catch {
            return error
        }
    }

    private let accessDenied = Reply.json(#"{"error": {"code": "ErrorAccessDenied", "message": "Access is denied. Check credentials and try again."}}"#,
                                          status: 403)

    // MARK: Permission

    func testThePermissionIsReadFromTheTokensScopesWithoutARequest() async {
        let with = await makeProvider().hasRulesPermission()
        XCTAssertTrue(with)
        tokens.scopes = "https://graph.microsoft.com/MailboxSettings.ReadWrite offline_access"
        let resourceForm = await makeProvider().hasRulesPermission()
        XCTAssertTrue(resourceForm, "listed with the resource")
        tokens.scopes = "Mail.ReadWrite Mail.Send User.Read Calendars.ReadWrite"
        let without = await makeProvider().hasRulesPermission()
        XCTAssertFalse(without)
        tokens.scopes = "MailboxSettings.Read"
        let readOnly = await makeProvider().hasRulesPermission()
        XCTAssertFalse(readOnly, "reading is not saving")
        XCTAssertTrue(requests.isEmpty)
    }

    // MARK: Reading

    func testEveryPageIsReadAndOnlySenderRulesAreShown() async throws {
        routeRules()
        let listing = try await makeProvider().serverRules()

        XCTAssertEqual(listing.senderRules, [
            ServerSenderRule(serverID: "AQAAAJ5dZqA=", address: "news@letter.example", action: .archive),
            ServerSenderRule(serverID: "AQAAAJ5dZqB=", address: "deals@shop.example", action: .trash),
            ServerSenderRule(serverID: "AQAAAJ5d/qC+", address: "spam@junk.example", action: .trash),
            ServerSenderRule(serverID: "AQAAAJ5dZqD=", address: "digest@news.example", action: .archive),
        ])
        XCTAssertEqual(listing.otherCount, 14, "disabled, elsewhere, permanent, more than one condition or action, an exception")
        let pages = requests(to: rulesPath)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.last?.url.absoluteString, nextLink, "the second page is the nextLink as given")
        XCTAssertEqual(pages.first?.header("Authorization"), "Bearer token-1")
        XCTAssertEqual(folderLookups().count, GraphWellKnownFolders.names.count, "the Archive's id from the well-known folders")
        XCTAssertEqual(listing.requestCount, 2 + GraphWellKnownFolders.names.count, "every request the read sent, lookups included")

        // The folders are known now: the next read sends the pages alone.
        StubURLProtocol.clearRequests()
        let provider = makeProvider()
        _ = try await provider.serverRules()
        let again = try await provider.serverRules()
        XCTAssertEqual(again.requestCount, 2)
    }

    func testRulesThatMoveNothingNeedNoFolderLookup() async throws {
        routeRules([firstPage[1], firstPage[2]], last: [])
        let listing = try await makeProvider().serverRules()
        XCTAssertEqual(listing.senderRules.map(\.action), [.trash, .trash])
        XCTAssertEqual(listing.requestCount, 1)
        XCTAssertTrue(folderLookups().isEmpty)
    }

    /// A mailbox without an Archive folder (Outlook makes it lazily): a move is some other rule, never guessed to be one.
    func testWithoutAnArchiveFolderAMoveIsSomeOtherRule() async throws {
        routeRules([firstPage[0], firstPage[1]], last: [], missing: ["archive"])
        let listing = try await makeProvider().serverRules()
        XCTAssertEqual(listing.senderRules.map(\.serverID), ["AQAAAJ5dZqB="])
        XCTAssertEqual(listing.otherCount, 1)
        XCTAssertEqual(folderLookups().count, GraphWellKnownFolders.names.count, "looked up once, not twice")
    }

    func testAnEmptyMailboxHasNoRules() async throws {
        routeRules([], last: [])
        let listing = try await makeProvider().serverRules()
        XCTAssertEqual(listing, ServerRuleListing(senderRules: [], otherCount: 0, requestCount: 1))
    }

    func testAListingThatNeverEndsFails() async {
        route { request in
            guard request.path == self.rulesPath else { return nil }
            return .json(self.page([], nextLink: self.nextLink))
        }
        let error = await thrown { _ = try await self.makeProvider().serverRules() }
        guard case .decoding? = error as? ProviderError else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(requests(to: rulesPath).count, GraphProvider.maxRulePages)
    }

    // MARK: Creating

    private func routeCreate(existing: [String], missing: Set<String> = [], created: String = #"{"id": "AQAAAJ5dNEW="}"#) {
        route { request in
            if let folder = self.wellKnownFolderReply(request, missing: missing) { return folder }
            guard request.path == self.rulesPath else { return nil }
            switch request.method {
            case "GET": return .json(self.page(existing))
            case "POST": return .json(created, status: 201)
            default: return nil
            }
        }
    }

    func testAnArchiveIsCreatedLastEnabledAndStoppingTheRulesAfterIt() async throws {
        routeCreate(existing: firstPage)
        let id = try await makeProvider().createSenderRule(address: "promo@shop.example", action: .archive)
        XCTAssertEqual(id, "AQAAAJ5dNEW=")
        let post = try XCTUnwrap(requests.first { $0.method == "POST" })
        XCTAssertEqual(post.json() as NSDictionary, [
            "displayName": "Archive mail from promo@shop.example",
            "sequence": 7,
            "isEnabled": true,
            "conditions": ["fromAddresses": [["emailAddress": ["address": "promo@shop.example"]]]],
            "actions": ["moveToFolder": "F-ARCHIVE", "stopProcessingRules": true],
        ] as NSDictionary, "only the sender's address and the action; after the highest sequence")
        let rule = try JSONDecoder().decode(GraphMessageRule.self, from: XCTUnwrap(post.body))
        var read = rule
        read.id = id
        XCTAssertEqual(GraphProvider.senderRule(from: read, archiveFolderID: "F-ARCHIVE")?.action, .archive, "read back as it was made")
    }

    func testABlockIsADeleteNeverAPermanentOne() async throws {
        routeCreate(existing: [])
        let id = try await makeProvider().createSenderRule(address: "deals@shop.example", action: .trash)
        XCTAssertEqual(id, "AQAAAJ5dNEW=")
        let post = try XCTUnwrap(requests.first { $0.method == "POST" })
        XCTAssertEqual(post.json() as NSDictionary, [
            "displayName": "Block deals@shop.example",
            "sequence": 1,
            "isEnabled": true,
            "conditions": ["fromAddresses": [["emailAddress": ["address": "deals@shop.example"]]]],
            "actions": ["delete": true, "stopProcessingRules": true],
        ] as NSDictionary)
        XCTAssertTrue(folderLookups().isEmpty, "a block needs no folder")
    }

    /// Sent again after a lost reply, the create finds the rule the first one made and returns it rather than make a
    /// second (Exchange would keep both).
    func testAnIdenticalRuleAlreadyThereIsReturnedNotMadeTwice() async throws {
        routeCreate(existing: firstPage)
        let id = try await makeProvider().createSenderRule(address: "deals@shop.example", action: .trash)
        XCTAssertEqual(id, "AQAAAJ5dZqB=")
        XCTAssertFalse(requests.contains { $0.method == "POST" })
    }

    func testAnArchiveWithoutAnArchiveFolderIsRefusedWithoutARequest() async {
        routeCreate(existing: [], missing: ["archive"])
        let error = await thrown { _ = try await self.makeProvider().createSenderRule(address: "a@b.example", action: .archive) }
        XCTAssertEqual(error as? RuleProviderError, .refused)
        XCTAssertFalse(requests.contains { $0.method == "POST" })
    }

    func testACreatedRuleWithoutAnIDIsAReplyThatDidNotRead() async {
        routeCreate(existing: [], created: "{}")
        let error = await thrown { _ = try await self.makeProvider().createSenderRule(address: "a@b.example", action: .trash) }
        guard case .decoding? = error as? ProviderError else { return XCTFail("\(String(describing: error))") }
    }

    // MARK: Deleting

    func testADeleteNamesTheRuleWithItsIDEscaped() async throws {
        route { request in request.method == "DELETE" ? .status(204) : nil }
        try await makeProvider().deleteRule(serverID: "AQAAAJ5d/qC+")
        let delete = try XCTUnwrap(requests.first)
        XCTAssertEqual(delete.url.absoluteString,
                       "https://graph.microsoft.com/v1.0/me/mailFolders/inbox/messageRules/AQAAAJ5d%2FqC%2B",
                       "the id's slash and plus never split or change the path")
    }

    func testARuleOutlookNoLongerHasCountsAsDeleted() async throws {
        route { _ in .json(Fixtures.notFoundError, status: 404) }
        try await makeProvider().deleteRule(serverID: "AQAAAJ5dZqA=")
        XCTAssertEqual(requests.count, 1)
        try await makeProvider().deleteRule(serverID: "")
        XCTAssertEqual(requests.count, 1, "an empty id would name the collection: nothing sent")
    }

    // MARK: Refusals

    /// Exchange's 403 on the rules is the missing scope when the token lacks it; when the token holds it, the
    /// organization refuses, and asking the user to reconnect would change nothing.
    func testAccessDeniedIsTheMissingScopeOnlyWhenTheTokenLacksIt() async {
        route { _ in self.accessDenied }
        tokens.scopes = "Mail.ReadWrite Mail.Send User.Read"
        let read = await thrown { _ = try await self.makeProvider().serverRules() }
        XCTAssertEqual(read as? RuleProviderError, .permissionMissing)
        let create = await thrown { _ = try await self.makeProvider().createSenderRule(address: "a@b.example", action: .trash) }
        XCTAssertEqual(create as? RuleProviderError, .permissionMissing)
        let delete = await thrown { try await self.makeProvider().deleteRule(serverID: "AQAAAJ5dZqA=") }
        XCTAssertEqual(delete as? RuleProviderError, .permissionMissing)

        route { _ in .json(#"{"error": {"code": "AccessDenied", "message": "Access is denied."}}"#, status: 403) }
        tokens.scopes = Self.rulesScopes
        let policy = await thrown { _ = try await self.makeProvider().serverRules() }
        XCTAssertEqual(policy as? RuleProviderError, .refused)
    }

    func testTheRulesQuotaIsTheLimit() async {
        for body in [#"{"error": {"code": "ErrorRulesOverQuota", "message": "The rules are over the quota."}}"#,
                     #"{"error": {"code": "ErrorRulesSizeQuotaExceeded", "message": "Rule quota exceeded."}}"#,
                     #"{"error": {"code": "ErrorQuotaExceeded", "message": "The rule quota has been exceeded for this mailbox."}}"#] {
            route { request in
                guard request.path == self.rulesPath else { return nil }
                return request.method == "GET" ? .json(self.page([])) : .json(body, status: 400)
            }
            let error = await thrown { _ = try await self.makeProvider().createSenderRule(address: "a@b.example", action: .trash) }
            XCTAssertEqual(error as? RuleProviderError, .limitReached, body)
        }
    }

    func testAnyOtherPermanentRefusalIsARefusal() async {
        for body in [#"{"error": {"code": "ErrorInvalidRequest", "message": "The request is invalid."}}"#,
                     #"{"error": {"code": "ErrorQuotaExceeded", "message": "The mailbox is full."}}"#] {
            route { request in
                guard request.path == self.rulesPath else { return nil }
                return request.method == "GET" ? .json(self.page([])) : .json(body, status: 400)
            }
            let error = await thrown { _ = try await self.makeProvider().createSenderRule(address: "a@b.example", action: .trash) }
            XCTAssertEqual(error as? RuleProviderError, .refused, body)
        }
    }

    func testThrottlesTheServiceAndTheNetworkPassAsTheyAre() async {
        route { _ in .json(#"{"error": {"code": "ApplicationThrottled", "message": "Too many requests"}}"#, status: 429,
                           headers: ["Retry-After": "7"]) }
        let throttled = await thrown { _ = try await self.makeProvider().serverRules() }
        guard case .throttled(let after)? = throttled as? ProviderError else { return XCTFail("\(String(describing: throttled))") }
        XCTAssertEqual(after, 7)

        route { _ in .json(#"{"error": {"code": "InternalServerError", "message": "boom"}}"#, status: 500) }
        let server = await thrown { _ = try await self.makeProvider().serverRules() }
        guard case .server(500, _)? = server as? ProviderError else { return XCTFail("\(String(describing: server))") }

        route { _ in .json("{}", status: 504) }
        let gateway = await thrown { _ = try await self.makeProvider().serverRules() }
        guard case .network? = gateway as? ProviderError else { return XCTFail("\(String(describing: gateway))") }

        route { _ in .failure(.notConnectedToInternet) }
        let offline = await thrown { _ = try await self.makeProvider().serverRules() }
        guard case .network? = offline as? ProviderError else { return XCTFail("\(String(describing: offline))") }
    }
}
