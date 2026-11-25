import XCTest
@testable import PaperCore

/// The demo's canned drafts for Help Me Write: a reply, a new message with its subject, the message above a forward.
final class DemoAIRepliesTests: XCTestCase {
    private func request(_ kind: WriteKind, task: String = "Write my message.", wantsSubject: Bool = false) -> AIWriteRequest {
        AIWriteRequest(kind: kind, instructions: "i", transcript: "t", task: task, wantsSubject: wantsSubject)
    }

    func testTheSameRequestGetsTheSameReply() {
        let one = AIWriteRequest(kind: .reply, instructions: "i", transcript: "t", task: "Write my reply.")
        XCTAssertEqual(DemoAIReplies.reply(for: one), DemoAIReplies.reply(for: one))
        XCTAssertTrue(DemoAIReplies.replies.contains(DemoAIReplies.reply(for: one)))
        let asks = (0..<40).map { AIWriteRequest(kind: .reply, instructions: "i", transcript: "t", task: "ask \($0)") }
        XCTAssertGreaterThan(Set(asks.map(DemoAIReplies.reply(for:))).count, 3, "different asks, different replies")
        XCTAssertFalse(DemoAIReplies.replies.isEmpty)
    }

    func testTheDraftIsPickedByWhatIsWritten() {
        let bodies = DemoAIReplies.newMessages.map(\.body)
        for index in 0..<40 {
            let task = "ask \(index)"
            XCTAssertTrue(DemoAIReplies.replies.contains(DemoAIReplies.draft(for: request(.reply, task: task)).body))
            XCTAssertTrue(bodies.contains(DemoAIReplies.draft(for: request(.newMessage, task: task)).body))
            XCTAssertTrue(DemoAIReplies.forwardMessages.contains(DemoAIReplies.draft(for: request(.forward, task: task)).body))
            XCTAssertEqual(DemoAIReplies.draft(for: request(.forward, task: task)), DemoAIReplies.draft(for: request(.forward, task: task)),
                           "the same on every run")
            XCTAssertEqual(DemoAIReplies.reply(for: request(.newMessage, task: task)), DemoAIReplies.draft(for: request(.newMessage, task: task)).body)
        }
        for kind in [WriteKind.newMessage, .forward] {
            let drafts = (0..<40).map { DemoAIReplies.draft(for: request(kind, task: "ask \($0)")).body }
            XCTAssertGreaterThan(Set(drafts).count, 3, "\(kind): different asks, different drafts")
        }
        XCTAssertTrue(Set(DemoAIReplies.replies).isDisjoint(with: bodies))
        XCTAssertTrue(Set(DemoAIReplies.forwardMessages).isDisjoint(with: bodies))
    }

    /// The fence code is new on every request, so it plays no part in the pick: the same notes, written twice, get the
    /// same draft (a render must not change from run to run), for every kind.
    func testTheFenceCodeDoesNotChangeThePick() throws {
        let claude = AIProviderConfiguration(kind: .claudeAPI)
        let fences = ["1a2b3c4d", "9f8e7d6c", "00000000", "abcdef12", "5e5e5e5e"]
        let inputs = [
            ComposeWriteInputs(subject: "Offsite", to: [EmailAddress(name: "Priya Shah", address: "priya@example.test")],
                               wantsSubject: true),
            ComposeWriteInputs(subject: "Fwd: Contract",
                               forwarded: ComposeWriteInputs.Forwarded(text: "The venue sent the contract.", author: "Ben Carter")),
        ]
        for input in inputs {
            for ask in [WriteAsk(draft: .notes("fyi before thursday")), WriteAsk(instruction: "ask for dates in march")] {
                let requests = try fences.map { try XCTUnwrap(input.request(for: ask, configuration: claude, fence: $0)) }
                XCTAssertEqual(Set(requests.map(\.userTurn)).count, fences.count, "each request carries its own fence")
                XCTAssertEqual(Set(requests.map(DemoAIReplies.draft(for:))).count, 1, "\(input.kind): one draft whatever the fence")
            }
        }
        let reply = ReplyContext(subject: "Offsite", messages: [], ask: WriteAsk(draft: .notes("tue 10 works")))
        let replies = fences.map { WritePrompt.request(for: reply, appendsSignature: false, configuration: claude, fence: $0) }
        XCTAssertEqual(Set(replies.map(\.task)).count, fences.count)
        XCTAssertEqual(Set(replies.map(DemoAIReplies.reply(for:))).count, 1)
    }

    func testASubjectComesOnlyWhenTheRequestAskedForOne() {
        for index in 0..<12 {
            let task = "ask \(index)"
            let asked = DemoAIReplies.draft(for: request(.newMessage, task: task, wantsSubject: true))
            let plain = DemoAIReplies.draft(for: request(.newMessage, task: task))
            XCTAssertNotNil(asked.subject)
            XCTAssertNil(plain.subject)
            XCTAssertNil(plain.subjectLine)
            XCTAssertEqual(plain.answer, plain.body)
            XCTAssertEqual(asked.body, plain.body, "the same message either way")
            XCTAssertEqual(asked.subjectLine, "Subject: \(asked.subject ?? "")\n\n")
            XCTAssertEqual(asked.answer, (asked.subjectLine ?? "") + asked.body)
            // The demo's answer is taken apart by the code a provider's is, and its subject comes through unchanged.
            let split = WriteSubjectLine.split(asked.answer, final: true)
            XCTAssertEqual(split.body, asked.body)
            XCTAssertEqual(split.subject.flatMap { WriteSubjectLine.cleaned($0, fence: "1a2b3c4d") }, asked.subject)
        }
        // Flags a reply or a forward cannot carry bring no subject.
        XCTAssertNil(DemoAIReplies.draft(for: request(.reply, wantsSubject: true)).subject)
        XCTAssertNil(DemoAIReplies.draft(for: request(.forward, wantsSubject: true)).subject)
    }

    func testEveryCannedNewMessageHasASubjectAndABody() {
        XCTAssertGreaterThanOrEqual(DemoAIReplies.newMessages.count, 4)
        XCTAssertGreaterThanOrEqual(DemoAIReplies.forwardMessages.count, 4)
        for draft in DemoAIReplies.newMessages {
            XCTAssertEqual(draft.subject.flatMap { WriteSubjectLine.cleaned($0, fence: "") }, draft.subject, "fit for the field as it is")
            XCTAssertFalse(draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertEqual(draft.body, draft.body.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertFalse(draft.body.lowercased().hasPrefix("subject:"))
            XCTAssertFalse(draft.body.contains("@"), "made-up drafts name no one and no address")
        }
        XCTAssertEqual(Set(DemoAIReplies.newMessages.compactMap(\.subject)).count, DemoAIReplies.newMessages.count)
        for message in DemoAIReplies.forwardMessages {
            XCTAssertEqual(message, message.trimmingCharacters(in: .whitespacesAndNewlines))
            XCTAssertFalse(message.lowercased().hasPrefix("subject:"))
            // The same draft goes above any forward: it says nothing of files the message below it may not carry, nor
            // of when that message came.
            XCTAssertFalse(message.lowercased().contains("attach"), message)
            XCTAssertFalse(message.lowercased().contains("today"), message)
        }
    }
}
