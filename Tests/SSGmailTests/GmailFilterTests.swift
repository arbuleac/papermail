import Foundation
import SSCore
import XCTest
@testable import SSGmail

/// Sender rules as Gmail filters (docs/ARCHITECTURE.md, "Rules"): the permission read from the token, the one read of
/// every filter and which of them are sender rules (exactly the shapes the app makes, and nothing else), the exact bodies
/// of a create, a delete that finds the filter gone, and Gmail's refusals mapped to what the engine can act on. Every
/// request goes to the stub server.
final class GmailFilterTests: XCTestCase {
    private let server = StubServer.shared
    private let filtersPath = "/gmail/v1/users/me/settings/filters"
    private let granted = OAuthEndpoints.googleScope + " " + OAuthEndpoints.googleRulesScope

    override func setUp() {
        super.setUp()
        server.reset()
    }

    override func tearDown() {
        server.reset()
        super.tearDown()
    }

    private func provider(scopes: String? = nil) -> GmailProvider {
        TestSupport.makeProvider(tokens: FakeTokenProvider(scopes: scopes ?? granted))
    }

    /// What a call threw, whatever its type.
    private func thrown(_ body: () async throws -> Void) async -> Error? {
        do {
            try await body()
            XCTFail("expected an error")
            return nil
        } catch {
            return error
        }
    }

    // MARK: Permission

    func testThePermissionIsReadFromTheTokensScopesWithoutARequest() async {
        let with = await provider().hasRulesPermission()
        XCTAssertTrue(with)
        let mailOnly = await provider(scopes: OAuthEndpoints.googleScope + " " + OAuthEndpoints.googleCalendarScope).hasRulesPermission()
        XCTAssertFalse(mailOnly, "gmail.modify does not cover settings")
        let unknown = await TestSupport.makeProvider(tokens: FakeTokenProvider(scopes: nil)).hasRulesPermission()
        XCTAssertFalse(unknown, "a token whose scopes are unknown grants nothing")
        XCTAssertTrue(server.requests.isEmpty)
    }

    // MARK: Reading

    func testEveryFilterIsReadInOneRequestAndOnlySenderRulesAreShown() async throws {
        server.on("GET", filtersPath, .json(GmailFilterFixtures.list))
        let listing = try await provider().serverRules()

        let requests = server.requests(to: filtersPath)
        XCTAssertEqual(requests.count, 1, "filters.list has no pages")
        XCTAssertEqual(requests.first?.method, "GET")
        XCTAssertEqual(requests.first?.url.host, "gmail.googleapis.com")
        XCTAssertEqual(requests.first?.query["prettyPrint"], ["false"])
        XCTAssertEqual(requests.first?.header("Authorization"), "Bearer token-1")
        XCTAssertEqual(listing.requestCount, 1)
        XCTAssertEqual(listing.senderRules, [
            ServerSenderRule(serverID: "ANe1BmjSender1", address: "news@letter.example", action: .archive),
            ServerSenderRule(serverID: "ANe1BmjSender2", address: "deals@shop.example", action: .trash),
            ServerSenderRule(serverID: "ANe1BmjSender3", address: "spam@junk.example", action: .trash),
            ServerSenderRule(serverID: "ANe1BmjSender4", address: "deals@shop.example", action: .archive),
        ], "each filter on its own, in Gmail's order, addresses normalized: two for one sender are the store's to fold")
        XCTAssertEqual(listing.otherCount, 20, "every other filter is counted and never shown")
    }

    func testAMailboxWithoutFiltersHasNone() async throws {
        server.on("GET", filtersPath, .json(GmailFilterFixtures.none))
        let listing = try await provider().serverRules()
        XCTAssertEqual(listing, ServerRuleListing(senderRules: [], otherCount: 0, requestCount: 1))
    }

    /// Recognition is exact: one `from` address and nothing else; archive is the Inbox label removed alone; block is the
    /// Trash label added alone, the Inbox removed or not; never a forward.
    func testRecognitionTakesOnlyTheShapesTheAppMakes() throws {
        func rule(_ criteria: String, _ action: String) throws -> ServerSenderRule? {
            let json = #"{"id": "F1", "criteria": \#(criteria), "action": \#(action)}"#
            return GmailProvider.senderRule(from: try JSONDecoder().decode(GmailFilterResource.self, from: Data(json.utf8)))
        }
        let from = #"{"from": "a@b.example"}"#
        XCTAssertEqual(try rule(from, #"{"removeLabelIds": ["INBOX"]}"#)?.action, .archive)
        XCTAssertEqual(try rule(from, #"{"addLabelIds": ["TRASH"]}"#)?.action, .trash)
        XCTAssertEqual(try rule(from, #"{"addLabelIds": ["TRASH"], "removeLabelIds": ["INBOX"]}"#)?.action, .trash)
        XCTAssertEqual(try rule(#"{"from": "a@b.example", "excludeChats": true}"#, #"{"removeLabelIds": ["INBOX"]}"#)?.action, .archive)
        XCTAssertEqual(try rule(#"{"from": "a@b.example", "sizeComparison": "unspecified"}"#, #"{"removeLabelIds": ["INBOX"]}"#)?.action,
                       .archive, "a comparison with no size says nothing")
        for (criteria, action) in [
            (from, #"{"removeLabelIds": ["INBOX", "UNREAD"]}"#),
            (from, #"{"removeLabelIds": ["INBOX"], "addLabelIds": ["IMPORTANT"]}"#),
            (from, #"{"addLabelIds": ["TRASH"], "removeLabelIds": ["UNREAD"]}"#),
            (from, #"{"addLabelIds": ["TRASH", "Label_3"]}"#),
            (from, #"{"addLabelIds": ["TRASH"], "forward": "x@y.example"}"#),
            (from, #"{"removeLabelIds": "INBOX"}"#),
            (from, #"{"removeLabelIds": ["INBOX"], "markImportant": true}"#),
            (from, "{}"),
            (#"{"from": "a@b.example", "to": "me@x.example"}"#, #"{"removeLabelIds": ["INBOX"]}"#),
            (#"{"from": "a@b.example", "subject": "x"}"#, #"{"removeLabelIds": ["INBOX"]}"#),
            (#"{"from": "a@b.example", "query": "x"}"#, #"{"removeLabelIds": ["INBOX"]}"#),
            (#"{"from": "a@b.example", "negatedQuery": "x"}"#, #"{"removeLabelIds": ["INBOX"]}"#),
            (#"{"from": "a@b.example", "hasAttachment": true}"#, #"{"removeLabelIds": ["INBOX"]}"#),
            (#"{"from": "a@b.example", "size": 1000}"#, #"{"removeLabelIds": ["INBOX"]}"#),
            (#"{"from": "a@b.example OR c@d.example"}"#, #"{"removeLabelIds": ["INBOX"]}"#),
            (#"{"from": "\"a@b.example\""}"#, #"{"removeLabelIds": ["INBOX"]}"#),
            (#"{"from": "b.example"}"#, #"{"removeLabelIds": ["INBOX"]}"#),
            (#"{"from": ""}"#, #"{"removeLabelIds": ["INBOX"]}"#),
            (#"{"to": "a@b.example"}"#, #"{"removeLabelIds": ["INBOX"]}"#),
        ] {
            XCTAssertNil(try rule(criteria, action), "\(criteria) \(action)")
        }
    }

    // MARK: Creating

    func testAnArchiveIsCreatedAsExactlyTheShapeReadBack() async throws {
        server.on("POST", filtersPath, .json(GmailFilterFixtures.created("ANe1BmjNew0001", from: "news@letter.example", archive: true)))
        let id = try await provider().createSenderRule(address: "news@letter.example", action: .archive)
        XCTAssertEqual(id, "ANe1BmjNew0001")
        let request = try XCTUnwrap(server.requests(to: filtersPath).first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.header("Content-Type"), "application/json; charset=UTF-8")
        XCTAssertEqual(request.jsonBody as NSDictionary,
                       ["criteria": ["from": "news@letter.example"], "action": ["removeLabelIds": ["INBOX"]]] as NSDictionary,
                       "only the sender's address and the action leave this Mac")
        let body = try JSONDecoder().decode(GmailFilterResource.self, from: request.body)
        XCTAssertEqual(GmailProvider.senderRule(from: GmailFilterResource(id: "x", criteria: body.criteria, action: body.action))?.action,
                       .archive)
    }

    func testABlockIsCreatedAsExactlyTheShapeReadBack() async throws {
        server.on("POST", filtersPath, .json(GmailFilterFixtures.created("ANe1BmjNew0002", from: "deals@shop.example", archive: false)))
        let id = try await provider().createSenderRule(address: "deals@shop.example", action: .trash)
        XCTAssertEqual(id, "ANe1BmjNew0002")
        let request = try XCTUnwrap(server.requests(to: filtersPath).first)
        XCTAssertEqual(request.jsonBody as NSDictionary,
                       ["criteria": ["from": "deals@shop.example"], "action": ["addLabelIds": ["TRASH"]]] as NSDictionary)
    }

    /// Sent again after a lost reply, the create meets Gmail's refusal of a duplicate: the filter already there is the
    /// rule, and its id comes back.
    func testACreateGmailCallsADuplicateReturnsTheFilterAlreadyThere() async throws {
        server.on("POST", filtersPath, .json(GmailFilterFixtures.alreadyExists, status: 400))
        server.on("GET", filtersPath, .json(GmailFilterFixtures.list))
        let id = try await provider().createSenderRule(address: "deals@shop.example", action: .trash)
        XCTAssertEqual(id, "ANe1BmjSender2")
        XCTAssertEqual(server.requests.map(\.method), ["POST", "GET"])
    }

    func testADuplicateGmailCannotFindIsARefusal() async throws {
        server.on("POST", filtersPath, .json(GmailFilterFixtures.alreadyExists, status: 400))
        server.on("GET", filtersPath, .json(GmailFilterFixtures.none))
        let error = await thrown { _ = try await self.provider().createSenderRule(address: "x@y.example", action: .archive) }
        XCTAssertEqual(error as? RuleProviderError, .refused)
    }

    /// Gmail reads a filter's `from` in its search grammar: a sender address that grammar reads as more than one plain
    /// address (a leading `-` negates it, and a block would then take every other sender's mail; braces make a group, a
    /// bare name matches far more) is never sent, and one the read would not show again as this rule (so it would vanish
    /// from Senders while Gmail kept running it) neither. The create is refused before any request.
    func testAnAddressGmailWouldReadAsMoreThanOneSenderIsRefusedWithoutARequest() async {
        server.on("POST", filtersPath, .json(GmailFilterFixtures.created("ANe1BmjNew0003", from: "x", archive: false)))
        for address in ["-promo@spam.example", "{a@x.example}", "MAILER-DAEMON", "a@x.example OR b@x.example", "\"x\"@y.example",
                        "*@spam.example", ""] {
            let error = await thrown { _ = try await self.provider().createSenderRule(address: address, action: .trash) }
            XCTAssertEqual(error as? RuleProviderError, .refused, address)
        }
        XCTAssertTrue(server.requests.isEmpty, "nothing sent")
    }

    func testACreatedFilterWithoutAnIDIsAReplyThatDidNotRead() async throws {
        server.on("POST", filtersPath, .json("{}"))
        let error = await thrown { _ = try await self.provider().createSenderRule(address: "x@y.example", action: .archive) }
        guard case .decoding? = error as? ProviderError else { return XCTFail("\(String(describing: error))") }
    }

    // MARK: Deleting

    func testADeleteNamesTheFilter() async throws {
        server.on("DELETE", filtersPath + "/ANe1BmjSender1", .empty(status: 204))
        try await provider().deleteRule(serverID: "ANe1BmjSender1")
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.method, "DELETE")
        XCTAssertEqual(request.path, filtersPath + "/ANe1BmjSender1")
    }

    func testAFilterGmailNoLongerHasCountsAsDeleted() async throws {
        server.on("DELETE", filtersPath + "/gone", .json(GmailFilterFixtures.notFound, status: 404))
        try await provider().deleteRule(serverID: "gone")
        XCTAssertEqual(server.requests.count, 1)
        try await provider().deleteRule(serverID: "")
        XCTAssertEqual(server.requests.count, 1, "an empty id would name the collection: nothing sent")
    }

    // MARK: Refusals

    func testATokenWithoutTheSettingsScopeIsAMissingPermission() async {
        for body in [GmailFilterFixtures.scopeInsufficient, GmailFilterFixtures.scopeInsufficientDetailsOnly] {
            server.reset()
            server.on("GET", filtersPath, .json(body, status: 403))
            let error = await thrown { _ = try await self.provider().serverRules() }
            XCTAssertEqual(error as? RuleProviderError, .permissionMissing)
        }
        server.reset()
        server.on("POST", filtersPath, .json(GmailFilterFixtures.scopeInsufficient, status: 403))
        let create = await thrown { _ = try await self.provider().createSenderRule(address: "a@b.example", action: .trash) }
        XCTAssertEqual(create as? RuleProviderError, .permissionMissing)
        server.reset()
        server.on("DELETE", filtersPath + "/F1", .json(GmailFilterFixtures.scopeInsufficient, status: 403))
        let delete = await thrown { try await self.provider().deleteRule(serverID: "F1") }
        XCTAssertEqual(delete as? RuleProviderError, .permissionMissing)
    }

    func testTheCapOnFiltersIsTheLimit() async {
        server.on("POST", filtersPath, .json(GmailFilterFixtures.tooManyFilters, status: 400))
        let error = await thrown { _ = try await self.provider().createSenderRule(address: "a@b.example", action: .trash) }
        XCTAssertEqual(error as? RuleProviderError, .limitReached)
    }

    func testAnyOtherPermanentRefusalIsARefusal() async {
        for (status, body) in [(400, GmailFilterFixtures.invalidCriteria), (403, GmailFilterFixtures.forbidden),
                               (412, #"{"error": {"code": 412, "message": "Precondition failed"}}"#)] {
            server.reset()
            server.on("POST", filtersPath, .json(body, status: status))
            let error = await thrown { _ = try await self.provider().createSenderRule(address: "a@b.example", action: .archive) }
            XCTAssertEqual(error as? RuleProviderError, .refused, "HTTP \(status)")
        }
    }

    /// Throttles, Google's quotas included, are waited out by the lane, never taken for a refusal.
    func testThrottlesAreThrottles() async {
        for (status, body) in [(403, GmailFilterFixtures.rateLimit), (403, GmailFilterFixtures.dailyLimit),
                               (429, GmailFilterFixtures.tooManyRequests)] {
            server.reset()
            server.on("GET", filtersPath, .json(body, status: status))
            let error = await thrown { _ = try await self.provider().serverRules() }
            guard case .throttled? = error as? ProviderError else { return XCTFail("HTTP \(status): \(String(describing: error))") }
        }
    }

    func testTheServiceTheNetworkAndTheTokenAreTheSharedMappings() async {
        server.on("GET", filtersPath, .json(GmailFilterFixtures.backendError, status: 500))
        let backend = await thrown { _ = try await self.provider().serverRules() }
        guard case .server(500, _)? = backend as? ProviderError else { return XCTFail("\(String(describing: backend))") }

        server.reset()
        server.on("GET", filtersPath, .json("{}", status: 503))
        let unavailable = await thrown { _ = try await self.provider().serverRules() }
        guard case .network? = unavailable as? ProviderError else { return XCTFail("\(String(describing: unavailable))") }

        server.reset()
        server.on("GET", filtersPath, .json(#"{"error": {"code": 401, "message": "Invalid Credentials"}}"#, status: 401))
        let tokens = FakeTokenProvider(scopes: granted)
        let refused = await thrown { _ = try await TestSupport.makeProvider(tokens: tokens).serverRules() }
        guard case .unauthorized? = refused as? ProviderError else { return XCTFail("\(String(describing: refused))") }
        XCTAssertEqual(server.requests.count, 2, "one retry with a fresh token")
        XCTAssertEqual(tokens.invalidations, 2)
    }
}
