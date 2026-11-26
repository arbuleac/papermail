import XCTest
import PaperCore

/// An event's related mail (`MailStoring.invitationMessages(for:)`, docs/ARCHITECTURE.md "Performance budgets"): the
/// event's title looked up in the subjects through the full-text index, the newest 40 matches outside drafts and spam
/// taken, and up to 12 invitations among them read for the UID. It runs off the main thread when a card opens. Measured
/// on a seeded mailbox of 50,000 messages with their bodies (`SyntheticMailbox`, two accounts) in a real file, for: a
/// title thousands of subjects share whose invitation is among the newest; the same with no invitation at all, which sorts
/// every match and reads none; a rare title; and a series whose twelve revisions are all read. Only with `PAPER_PERF=1`:
///
///     PAPER_PERF=1 swift test --filter RelatedInvitationPerformanceTests
final class RelatedInvitationPerformanceTests: XCTestCase {
    private let runs = 21

    func testTheRelatedMailIsFoundWithinTheBudget() throws {
        guard ProcessInfo.processInfo.environment["PAPER_PERF"] == "1" else {
            throw XCTSkip("set PAPER_PERF=1 to run the related-mail benchmark")
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RelatedInvitationPerformanceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SQLiteMailStore(path: directory.appendingPathComponent("mail.sqlite").path)
        defer { try? store.close() }
        let mailbox = SyntheticMailbox(messageCount: 50_000)
        let loaded = try PerfMailbox.load(mailbox, into: store)
        print("PAPER_PERF related mail: 50,000 messages loaded in \(Int(loaded.load + loaded.hydrate)) ms")
        let account = try XCTUnwrap(mailbox.accounts.first).id
        let now = Date()

        // A weekly meeting whose subject thousands of messages share: its three revisions are among the newest.
        let common = "Design review notes"
        let sharing = mailbox.messages(for: account).filter { $0.subject.contains(common) }.count
        XCTAssertGreaterThan(sharing, 1_000, "a title thousands of subjects share")
        for (index, sent) in [3, 2, 1].enumerated() {
            try seedInvitation(store, account: account, providerID: "design-\(index)", subject: "Invitation: \(common)",
                               uid: "design@example.com", date: now.addingTimeInterval(Double(-sent) * 86_400))
        }
        // A rare title with one invitation, and a series of twelve revisions, each read.
        try seedInvitation(store, account: account, providerID: "cleanup", subject: "Invitation: Neighbourhood clean-up",
                           uid: "cleanup@example.com", date: now.addingTimeInterval(-86_400))
        for index in 0..<12 {
            try seedInvitation(store, account: account, providerID: "pottery-\(index)", subject: "Updated invitation: Pottery class",
                               uid: "pottery@example.com", date: now.addingTimeInterval(Double(-index) * 3_600))
        }

        let cases: [(label: String, event: CalendarEvent, found: Int)] = [
            ("a title \(sharing) subjects share, its invitation among the newest", event(common, uid: "design@example.com", account), 3),
            ("the same title, no invitation anywhere", event(common, uid: "nobody@example.com", account), 0),
            ("a rare title", event("Neighbourhood clean-up", uid: "cleanup@example.com", account), 1),
            ("a series of twelve revisions, all read", event("Pottery class", uid: "pottery@example.com", account), 12),
        ]
        for item in cases {
            var timings: [Double] = []
            var found = 0
            for _ in 0..<runs {
                let start = DispatchTime.now()
                found = try store.invitationMessages(for: item.event).count
                timings.append(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
            }
            timings.sort()
            let median = timings[runs / 2], worst = timings[runs - 1]
            print("PAPER_PERF related mail, \(item.label): median \(format(median)) ms, worst \(format(worst)) ms, \(found) found")
            XCTAssertEqual(found, item.found, item.label)
            // Debug, M4 Pro, 26 November 2026 (see docs/ARCHITECTURE.md, "Performance budgets").
            XCTAssertLessThan(median, 20, "related-mail budget at the median: \(item.label)")
            XCTAssertLessThan(worst, 50, "related-mail budget at worst: \(item.label)")
        }
    }

    // MARK: Fixtures

    private func event(_ title: String, uid: String, _ account: AccountID) -> CalendarEvent {
        let start = Date().addingTimeInterval(86_400)
        return CalendarEvent(id: CalendarEvent.localID(accountID: account, providerID: "evt-\(uid)"), accountID: account,
                             providerID: "evt-\(uid)", title: title, start: start, end: start.addingTimeInterval(3_600),
                             response: .needsAction, invitationUID: uid)
    }

    private func seedInvitation(_ store: SQLiteMailStore, account: AccountID, providerID: String, subject: String, uid: String,
                                date: Date) throws {
        let id = MessageID(accountID: account, providerID: providerID)
        try store.upsertMessages([MessageMetadata(
            id: id, conversationID: ConversationID(accountID: account, providerID: "c-" + providerID), subject: subject, snippet: "",
            from: EmailAddress(name: "Ben Carter", address: "ben@example.com"), to: [], date: MailboxClock.aligned(date), roles: [.inbox],
            isRead: true, isStarred: false, hasAttachments: false)])
        let invitation = CalendarInvitation(method: .request, uid: uid, title: subject, start: date.addingTimeInterval(86_400),
                                            end: date.addingTimeInterval(90_000),
                                            organizer: CalendarInvitation.Person(name: "Ben Carter", address: "ben@example.com"))
        try store.saveBody(StoredBody(body: MessageBody(html: "<p>Invitation</p>", text: nil), renderedHTML: "<p>Invitation</p>",
                                      plainText: "Invitation", invitation: invitation), for: id)
    }

    private func format(_ value: Double) -> String { String(format: "%.2f", value) }
}
