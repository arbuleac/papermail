import XCTest
@testable import SSCore

/// Send Later's row of the budgets in docs/ARCHITECTURE.md, with what makes it hard: a message carrying a 20 MB
/// attachment waits in the outbox, as one scheduled on Friday for Monday does all weekend. The reads made every second
/// while another send is on its way (the undo-send panel, the reply field, the Drafts observation, the runner's look) and
/// the local steps of scheduling and cancelling another message stay within 16 ms; reading or writing the large message
/// itself happens only when it is scheduled, sent or made into a draft. In a real file, since what the reads skip is the
/// message's overflow pages. The file holds the synthetic mailbox too (`PerfMailbox`, 300,000 messages), and everything is
/// measured again after a sweep to Keep mail at 1 year. Only with `SS_PERF=1`:
///
///     SS_PERF=1 swift test --filter SendLaterOutboxPerformanceTests
final class SendLaterOutboxPerformanceTests: XCTestCase {
    private static let attachmentBytes = 20 * 1_024 * 1_024

    func testALargeWaitingMessageKeepsTheOutboxWithinBudget() async throws {
        guard ProcessInfo.processInfo.environment["SS_PERF"] == "1" else {
            throw XCTSkip("set SS_PERF=1 to run the Send Later outbox benchmark")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SendLaterOutboxPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        let mailbox = PerfMailbox.make()
        _ = try PerfMailbox.load(mailbox, into: store)
        try store.upsertAccount(Fixtures.account(id: Fixtures.accountID))
        let harness = try EngineHarness(engineStore: store)
        let engine = harness.engine
        try measureOutbox(store, engine: engine, retention: "Everything")
        _ = try PerfMailbox.sweep(store, to: PerfMailbox.oneYearCutoff(mailbox))
        try measureOutbox(store, engine: engine, retention: "1 year")
        await harness.shutdown()
        try store.close()
    }

    private func measureOutbox(_ store: SQLiteMailStore, engine: MailEngine, retention: String) throws {
        func report(_ label: String, _ milliseconds: Double) { self.report("\(retention): \(label)", milliseconds) }

        var large = Fixtures.outgoing()
        large.attachments = [OutgoingAttachment(filename: "deck.pdf", mimeType: "application/pdf",
                                                data: Data(repeating: 0x5A, count: Self.attachmentBytes))]
        let monday = Date().addingTimeInterval(3 * 86_400)
        var largeID = ""
        let scheduleLarge = try measure { largeID = try engine.scheduleSend(large, at: monday, draftID: UUID()) }
        report("schedule a message with a 20 MB attachment (encoding it, once, as Send does)", scheduleLarge)

        let summaries = try median(runs: 9) { try store.pendingSendSummaries() }
        report("the outbox's summaries, the large message waiting", summaries.milliseconds)
        XCTAssertEqual(summaries.value.map(\.id), [largeID])
        XCTAssertTrue(summaries.value[0].hasFiles)
        XCTAssertLessThan(summaries.milliseconds, 16, "read every second while a send is on its way, and at every outbox change")

        let whole = try median(runs: 3) { try store.pendingSends() }
        report("the whole outbox, attachments decoded (what every reader read before summaries)", whole.milliseconds)

        let one = try median(runs: 3) { try store.pendingSend(id: largeID) }
        report("the large message, whole (to send it, or to make a draft of it when its kept draft is gone)", one.milliseconds)
        XCTAssertEqual(one.value?.message.attachments.first?.data.count, Self.attachmentBytes)

        // Another message scheduled, opened from Drafts (its schedule cancelled) and scheduled again, the large one waiting.
        var timings: (schedule: [Double], cancel: [Double]) = ([], [])
        for _ in 0..<7 {
            var id = ""
            timings.schedule.append(try measure { id = try engine.scheduleSend(Fixtures.outgoing(), at: monday, draftID: UUID()) })
            timings.cancel.append(try measure { XCTAssertTrue(try engine.cancelSend(id: id)) })
        }
        let schedule = timings.schedule.sorted()[timings.schedule.count / 2]
        let cancel = timings.cancel.sorted()[timings.cancel.count / 2]
        report("schedule an ordinary message, the large one waiting", schedule)
        report("cancel it (Cancel, or opening it from Drafts), the large one waiting", cancel)
        XCTAssertLessThan(schedule, 16, "Send Later budget: schedule")
        XCTAssertLessThan(cancel, 16, "Send Later budget: cancel, open from Drafts")

        var waiting = try XCTUnwrap(summaries.value.first)
        waiting.status = .missed
        let stateWrite = try median(runs: 5) { try store.updateSend(waiting) }
        report("a state change of the large message (the runner's claim, a missed time)", stateWrite.milliseconds)
        XCTAssertLessThan(stateWrite.milliseconds, 16, "a status change never rewrites the attachments")

        let cancelLarge = try measure { XCTAssertTrue(try engine.cancelSend(id: largeID)) }
        report("cancel the large message", cancelLarge)
        XCTAssertLessThan(cancelLarge, 16, "Send Later budget: cancel, open from Drafts")
    }

    // MARK: Timing

    private func measure(_ work: () throws -> Void) rethrows -> Double {
        let start = DispatchTime.now()
        try work()
        return Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private func median<T>(runs: Int, _ work: () throws -> T) throws -> (value: T, milliseconds: Double) {
        var last = try work()
        var timings: [Double] = []
        for _ in 0..<runs {
            timings.append(try measure { last = try work() })
        }
        return (last, timings.sorted()[runs / 2])
    }

    private func report(_ label: String, _ milliseconds: Double) {
        print("SS_PERF \(label): \(String(format: "%.1f", milliseconds)) ms")
    }
}
