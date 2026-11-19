import Foundation
import SSCore
import XCTest
@testable import SSGraph

/// A Graph mailbox of 200 folders (roadmap Q4.3): Inbox › Clients › nineteen clients › nine years each, three more
/// folders at the top and the six system folders, every id and delta token as long as Exchange makes them. From a new
/// account, how many polls the folder walk takes and what each sends; then ten minutes of polls every 5 s, as while the
/// app is active, each timed through the provider's own work (the replies come from the stub at once), with the size of
/// the cursor the engine stores after each and that write's time. Only with `SS_PERF=1`:
///
///     SS_PERF=1 swift test -c release --filter GraphFolderPerformanceTests
final class GraphFolderPerformanceTests: GraphTestCase {
    private let clients = 19
    private let years = 9

    /// An id shaped like Exchange's: about 120 characters of base64.
    private func folderID(_ name: String) -> String {
        "AAMkAGI2THVSAAA-\(name)-" + String(repeating: "AQMkADAwATM0MDAAMS1iNjE2LTljZWYtMDACLTAwCgAuAAAD", count: 2).prefix(100)
    }

    private func deltaLink(_ folder: String, _ round: Int) -> String {
        "https://graph.microsoft.com/v1.0/me/mailFolders/\(folder)/messages/delta?$deltatoken="
            + String(repeating: "LztZwWjo5IivWBhyxw5rACKxf7mPm0oW6JZZ7fvKxYPS_67JnEYmfQQMPccy6FRun0DWJF5775dvuEvFI", count: 3) + "-\(round)"
    }

    private var tree: [String: [String]] {
        let clientsFolder = folderID("clients")
        let clientIDs = (1...clients).map { folderID(String(format: "client%02d", $0)) }
        var tree: [String: [String]] = [
            "": Array(Fixtures.folderIDs.values).sorted() + ["receipts", "travel", "newsletters"].map(folderID),
            "F-INBOX": [clientsFolder],
            clientsFolder: clientIDs,
        ]
        for (index, client) in clientIDs.enumerated() {
            tree[client] = (2018..<(2018 + years)).map { folderID(String(format: "c%02d-%d", index + 1, $0)) }
        }
        return tree
    }

    func testTwoHundredFoldersFromANewAccountAndThenTenMinutesOfPolls() async throws {
        guard ProcessInfo.processInfo.environment["SS_PERF"] == "1" else {
            throw XCTSkip("set SS_PERF=1 to run the 200-folder Graph benchmark")
        }
        let tree = self.tree
        let all = Set(tree.values.joined())
        XCTAssertEqual(all.count, 200, "two hundred folders")
        route { request in
            if let reply = self.wellKnownFolderReply(request) { return reply }
            if request.method == "GET", request.path == "/v1.0/me/messages" { return .json(Fixtures.list([])) }
            let prefix = "/v1.0/me/mailFolders/", children = "/childFolders", delta = "/messages/delta"
            if request.method == "GET", request.path == "/v1.0/me/mailFolders" || (request.path.hasPrefix(prefix) && request.path.hasSuffix(children)) {
                let parent = request.path == "/v1.0/me/mailFolders" ? "" : String(request.path.dropFirst(prefix.count).dropLast(children.count))
                guard let folders = tree[parent] else { return nil }
                let items = folders.map { #"{"id":"\#($0)","childFolderCount":\#(tree[$0]?.count ?? 0)}"# }
                return .json(Fixtures.list(items))
            }
            if request.method == "GET", request.path.hasPrefix(prefix), request.path.hasSuffix(delta) {
                let folder = String(request.path.dropFirst(prefix.count).dropLast(delta.count))
                let round = Int(request.query["$deltatoken"]?.split(separator: "-").last ?? "0") ?? 0
                return .json(Fixtures.list([], deltaLink: self.deltaLink(folder, round + 1)))
            }
            return nil
        }
        let clock = StepClock(now)
        let provider = makeProvider(clock: clock)

        // A new account: the first page of the mailbox, then polls every 5 s until the walk has found every folder and
        // every folder has its first delta link.
        let head = try await provider.bootstrap(page: nil, limit: 50)
        var cursor = try XCTUnwrap(head.changeCursor)
        var walkCalls = 0
        var walkRequests: [Int] = [head.requestCount ?? 0]
        var walkTimes: [Double] = []
        while true {
            let state = try GraphCursor.decode(cursor)
            let seeded = state.folders.values.allSatisfy { $0 != nil }
            if state.walk == nil, Set(state.folders.keys) == all, seeded { break }
            clock.advance(by: 5)
            let start = DispatchTime.now()
            let page = try await provider.changes(since: cursor, limit: 50)
            walkTimes.append(milliseconds(since: start))
            walkRequests.append(page.requestCount ?? 0)
            cursor = page.cursor
            walkCalls += 1
            XCTAssertLessThan(walkCalls, 400, "the walk and the first rounds end")
            if walkCalls >= 400 { break }
        }
        report("from a new account to every folder walked and seeded: \(walkCalls) polls (\(walkCalls * 5) s at 5 s)", Double(walkCalls))
        report("a poll during the walk and the first rounds, requests, most", Double(walkRequests.max() ?? 0))
        report("a poll during the walk and the first rounds, the provider's time, median", percentile(walkTimes, 0.5))
        report("a poll during the walk and the first rounds, the provider's time, max", walkTimes.max() ?? 0)

        // Ten minutes of polls every 5 s over the 200 quiet folders: the system folders each time, the others on full visits.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GraphFolderPerformanceTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        try store.upsertAccount(Account(id: accountID, kind: .microsoft, email: "robin@example.com", displayName: "Robin",
                                        addedAt: now, inkSlot: 0))
        var times: [Double] = []
        var counts: [Int] = []
        var writes: [Double] = []
        var size = 0
        for _ in 0..<120 {
            clock.advance(by: 5)
            let start = DispatchTime.now()
            let page = try await provider.changes(since: cursor, limit: 50)
            times.append(milliseconds(since: start))
            counts.append(page.requestCount ?? 0)
            cursor = page.cursor
            size = max(size, cursor.utf8.count)
            let write = DispatchTime.now()
            try store.setSyncCursor(cursor, for: accountID)
            writes.append(milliseconds(since: write))
        }
        report("a poll of 200 quiet folders, the provider's time, median", percentile(times, 0.5))
        report("a poll of 200 quiet folders, the provider's time, p95", percentile(times, 0.95))
        report("a poll of 200 quiet folders, requests, most", Double(counts.max() ?? 0))
        report("ten minutes of polls, requests in all", Double(counts.reduce(0, +)))
        report("the cursor the engine stores after each poll, KB", Double(size) / 1_024)
        report("the cursor's store write, median", percentile(writes, 0.5))
        try store.close()
        XCTAssertLessThanOrEqual(counts.max() ?? 0, 33, "a quiet poll is never a heavy page")
        XCTAssertLessThan(percentile(times, 0.95), 50, "a poll's own work stays far below the 5 s it has")
    }

    private func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }

    private func report(_ label: String, _ value: Double) {
        print("SS_PERF graph \(label): \(String(format: "%.2f", value))")
    }
}
