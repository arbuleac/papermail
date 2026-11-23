import XCTest
@testable import PaperCore

/// Always Archive Mail from This Sender reads the sender's mail in every Inbox on the click (`inboxMessages(from:)`,
/// docs/ARCHITECTURE.md "Rules" and "Performance budgets"): 16 ms at the median and 50 ms at worst on the synthetic
/// mailbox (`PerfMailbox`, 300,000 messages in three accounts, 156,574 of them in the Inbox) in a real file, for its
/// busiest sender (753 messages in the Inbox), the same address in capitals, the sender with the fewest, an address with
/// none, and a newsletter with 20,000 messages, 5,000 of them in the Inbox, whose local part is too common to narrow by and
/// whose read costs what it returns. Reported: the walk of the Inbox an address the index cannot fold takes (Cherokee
/// capitals), the rule's whole step for the busiest sender and for the newsletter (the
/// read, the summaries before and after, the transaction with its archive in every account) and its undo, beyond the
/// 16 ms of a key's few conversations, and held: the outbox writing such an operation again before each attempt, which
/// the user's next action would wait behind, never in proportion to its targets.
/// Loading the mailbox takes a while, so it only runs with `PAPER_PERF=1`:
///
///     PAPER_PERF=1 swift test -c release -Xswiftc -enable-testing --filter SenderInboxPerformanceTests
///
/// It holds the budget in a debug build too (`PAPER_PERF=1 swift test --filter SenderInboxPerformanceTests`), but for the
/// newsletter, whose 5,000 messages take twice as long to decode unoptimized: that one is held in release builds alone.
/// `PAPER_PERF_MESSAGES` sets another size.
final class SenderInboxPerformanceTests: XCTestCase {
    private let runs = 21

    func testTheSendersInboxMailIsFoundWithinTheBudget() throws {
        guard ProcessInfo.processInfo.environment["PAPER_PERF"] == "1" else {
            throw XCTSkip("set PAPER_PERF=1 to run the synthetic-mailbox sender benchmark")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SenderInboxPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        let mailbox = PerfMailbox.make()
        _ = try PerfMailbox.load(mailbox, into: store)

        let inbox = mailbox.messages.filter(\.isInInbox)
        var bySender: [String: Int] = [:]
        for message in inbox { if let from = message.from { bySender[SenderRule.normalizedAddress(from.address), default: 0] += 1 } }
        let ranked = bySender.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        let busiest = try XCTUnwrap(ranked.first)
        let few = try XCTUnwrap(ranked.last)
        print("PAPER_PERF mailbox: \(mailbox.messages.count) messages, \(inbox.count) in the Inbox, \(bySender.count) senders")

        for (label, address, expected) in [
            ("busiest sender", busiest.key, busiest.value),
            ("busiest sender in capitals", busiest.key.uppercased(), busiest.value),
            ("the sender with the fewest", few.key, few.value),
            ("a sender of none", "nobody@nowhere.example", 0),
        ] {
            let found = try measure(label) { try store.inboxMessages(from: address) }
            XCTAssertEqual(found.count, expected, label)
        }
        // An address the index cannot fold as Foundation lowercases it (Cherokee, written in what Unicode 8 made capitals)
        // walks the Inbox: reported, not held, since only letters whose case Unicode settled after 6.1 come this way.
        let walked = try timings { try store.inboxMessages(from: "ᏣᎳᎩ@example.com") }
        PerfMailbox.report("inboxMessages(from:) walking the Inbox, for an address the index cannot fold (median)", walked.median)
        PerfMailbox.report("inboxMessages(from:) walking the Inbox, for an address the index cannot fold (max)", walked.max)

        // A newsletter with 20,000 messages across the accounts, 5,000 of them in the Inbox, each its own conversation.
        let letter = EmailAddress(name: "Weekly Letter", address: "news@letter.example")
        let issues = (0..<20_000).map { index -> MessageMetadata in
            let account = mailbox.accounts[index % mailbox.accounts.count]
            return MessageMetadata(id: MessageID(accountID: account.id, providerID: "letter-\(index)"),
                                   conversationID: ConversationID(accountID: account.id, providerID: "letter-\(index)"),
                                   subject: "Issue \(index)", snippet: "This week", from: letter, to: [EmailAddress(address: account.email)],
                                   date: mailbox.options.now.addingTimeInterval(-Double(index) * 3_600), roles: index % 4 == 0 ? [.inbox] : [],
                                   isRead: true, isStarred: false, hasAttachments: false)
        }
        for batch in stride(from: 0, to: issues.count, by: PerfMailbox.batchSize) {
            try store.upsertMessages(Array(issues[batch..<min(batch + PerfMailbox.batchSize, issues.count)]))
        }
        // Decoding 5,000 messages is what this read costs, about twice as long unoptimized: held in release builds alone.
        XCTAssertEqual(try measure("a newsletter of 20,000", inDebug: false) { try store.inboxMessages(from: letter.address) }.count, 5_000)

        // The rule's whole step, as the window takes it, and its undo. Reported: an archive of hundreds or thousands of
        // conversations at once, which the 16 ms of a key's few does not cover.
        let own = Dictionary(uniqueKeysWithValues: mailbox.accounts.map { ($0.id, $0.email) })
        let accountID = try XCTUnwrap(mailbox.accounts.first).id
        for (label, sender) in [("the busiest sender", busiest.key), ("the newsletter", letter.address)] {
            var sweep: SenderRuleSweep?
            var archived: [ConversationID] = []
            let set = try PerfMailbox.milliseconds {
                let found = try store.inboxMessages(from: sender)
                let made = SenderRuleSweep(.archive, address: sender, setFrom: try XCTUnwrap(found.first).conversationID,
                                           conversationMessages: [], inboxMessages: found, ownAddresses: own)
                sweep = made
                _ = try store.summaries(of: made.conversations)
                let operations = MailActionRecord.Step(change: .archive, targets: made.record?.targets ?? [])
                try store.setSenderRule(.archive, for: sender, accountID: accountID,
                                        enqueueing: operations.operationsPerAccount(at: Date()), at: Date())
                archived = made.archived(after: try store.summaries(of: made.conversations))
            }
            let taken = try XCTUnwrap(sweep)
            PerfMailbox.report("Always Archive set for \(label): \(taken.record?.targets.count ?? 0) messages, \(archived.count) "
                               + "conversations out of the Inbox, \(taken.accounts.count) accounts, reads and write", set)
            XCTAssertEqual(try store.inboxMessages(from: sender), [], "every Inbox emptied of \(label)")

            // The outbox writes the biggest operation again before its first attempt: never in proportion to its targets.
            var operation = try XCTUnwrap(try store.pendingOperations(accountID: accountID, limit: 10).last)
            operation.status = .uncertain
            operation.attempts = 1
            operation.nextAttemptAt = Date().addingTimeInterval(60)
            let writeAhead = try PerfMailbox.milliseconds { try store.updateOperation(operation) }
            PerfMailbox.report("the outbox's write-ahead of \(label)'s \(operation.targets.count) targets", writeAhead)
            XCTAssertLessThan(writeAhead, 16, "the write-ahead of \(label)'s operation")

            let undo = try PerfMailbox.milliseconds {
                let back = MailActionRecord.Step(change: .moveToInbox, targets: taken.record?.targets ?? [])
                try store.setSenderRule(nil, for: sender, accountID: accountID, enqueueing: back.operationsPerAccount(at: Date()), at: Date())
            }
            PerfMailbox.report("Always Archive undone for \(label)", undo)
        }
        try store.close()
    }

    /// The median and the slowest of `runs` reads after one warm-up, reported and held to the budget.
    @discardableResult
    private func measure(_ label: String, inDebug: Bool = true, _ read: () throws -> [MessageMetadata]) throws -> [MessageMetadata] {
        let result = try timings(read)
        PerfMailbox.report("inboxMessages(from:) for \(label), \(result.value.count) messages (median)", result.median)
        PerfMailbox.report("inboxMessages(from:) for \(label), \(result.value.count) messages (max)", result.max)
        #if DEBUG
        guard inDebug else { return result.value }
        #endif
        XCTAssertLessThan(result.median, 16, "median for \(label)")
        XCTAssertLessThan(result.max, 50, "slowest for \(label)")
        return result.value
    }

    private func timings<T>(_ work: () throws -> T) throws -> (value: T, median: Double, max: Double) {
        var last = try work()
        var times: [Double] = []
        for _ in 0..<runs { times.append(try PerfMailbox.milliseconds { last = try work() }) }
        return (last, PerfMailbox.percentile(times, 0.5), times.max() ?? 0)
    }
}

private extension MailActionRecord.Step {
    /// One operation per account, as the engine makes them (`MailEngine.setSenderRule`).
    func operationsPerAccount(at now: Date) -> [PaperCore.Operation] {
        Dictionary(grouping: targets, by: \.accountID).sorted { $0.key.rawValue < $1.key.rawValue }
            .map { PaperCore.Operation(accountID: $0.key, change: change, targets: $0.value, createdAt: now) }
    }
}
