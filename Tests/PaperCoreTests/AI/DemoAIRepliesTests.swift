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
