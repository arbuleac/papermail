import Foundation
import SSCore
import XCTest
@testable import SSGraph

/// Shared wiring: a provider over the stub session with a frozen or hand-stepped clock, plus routing helpers for
/// the folder lookups almost every call starts with.
class GraphTestCase: XCTestCase {
    typealias Request = StubURLProtocol.Request
    typealias Reply = StubURLProtocol.Reply

    let accountID = AccountID("acct-graph-1")
    /// 2026-11-01T10:00:00Z
    let now = Date(timeIntervalSince1970: 1_793_527_200)
    let nowString = "2026-11-01T10:00:00Z"
    var tokens = StubTokenProvider()
    /// The waits an apply took before sending failed parts again; recorded, never slept, so a test runs at once.
    let applyWaits = WaitRecorder()

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        tokens = StubTokenProvider()
        applyWaits.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func makeProvider(now: Date? = nil, sendLimits: GraphSendLimits = .graph) -> GraphProvider {
        let frozen = now ?? self.now
        let waits = applyWaits
        return GraphProvider(accountID: accountID, tokens: tokens, session: StubURLProtocol.makeSession(), clock: { frozen },
                             sendLimits: sendLimits, applyRetryWait: { waits.record($0) })
    }

    func makeProvider(clock: StepClock) -> GraphProvider {
        let waits = applyWaits
        return GraphProvider(accountID: accountID, tokens: tokens, session: StubURLProtocol.makeSession(), clock: { clock.now },
                             applyRetryWait: { waits.record($0) })
    }

    var requests: [Request] { StubURLProtocol.requests }

    func requests(to path: String) -> [Request] {
        requests.filter { $0.path == path }
    }

    /// Installs `handler`; a nil result falls through to a loud 599 so unrouted calls fail the test visibly.
    func route(_ handler: @escaping (Request) -> Reply?) {
        StubURLProtocol.install { request in
            handler(request) ?? .json(#"{"error":{"code":"Unrouted","message":"unexpected request"}}"#, status: 599)
        }
    }

    func wellKnownFolderReply(_ request: Request, missing: Set<String> = []) -> Reply? {
        let prefix = "/v1.0/me/mailFolders/"
        guard request.method == "GET", request.path.hasPrefix(prefix) else { return nil }
        let name = String(request.path.dropFirst(prefix.count))
        guard !name.contains("/"), GraphWellKnownFolders.names.contains(name) else { return nil }
        guard !missing.contains(name), let id = Fixtures.folderIDs[name] else {
            return .json(Fixtures.notFoundError, status: 404)
        }
        return .json(Fixtures.folder(id))
    }

    func folderListReply(_ request: Request) -> Reply? {
        guard request.method == "GET" else { return nil }
        switch request.path {
        case "/v1.0/me/mailFolders": return .json(Fixtures.folderList)
        case "/v1.0/me/mailFolders/F-PROJECTS/childFolders": return .json(Fixtures.childFolders)
        default: return nil
        }
    }

    /// Answers `$batch` with one reply per inner request, chosen by the inner request's url.
    func batchReply(_ request: Request, status: Int = 200, item: (String, String) -> Fixtures.BatchItem) -> Reply? {
        guard request.method == "POST", request.path == "/v1.0/$batch" else { return nil }
        let inner = request.json()["requests"] as? [[String: Any]] ?? []
        let items = inner.map { item($0["id"] as? String ?? "", $0["url"] as? String ?? "") }
        return .json(Fixtures.batch(items), status: status)
    }

    func innerBatchRequests() -> [[String: Any]] {
        requests(to: "/v1.0/$batch").flatMap { $0.json()["requests"] as? [[String: Any]] ?? [] }
    }

    func expectProviderError<T>(
        _ body: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line,
        matches: (ProviderError) -> Bool
    ) async {
        do {
            _ = try await body()
            XCTFail("expected a ProviderError", file: file, line: line)
        } catch let error as ProviderError {
            XCTAssertTrue(matches(error), "unexpected ProviderError \(error)", file: file, line: line)
        } catch {
            XCTFail("unexpected error \(error)", file: file, line: line)
        }
    }

    func cursor(
        folders: [String: String?],
        nextLinks: [String: String] = [:],
        resolvedAt: String? = nil,
        fullVisitAt: String? = nil
    ) throws -> String {
        try GraphCursor(
            folders: folders,
            nextLinks: nextLinks,
            wellKnown: Fixtures.folderIDs,
            since: nowString,
            foldersResolvedAt: resolvedAt ?? nowString,
            fullVisitAt: fullVisitAt
        ).encoded()
    }
}
