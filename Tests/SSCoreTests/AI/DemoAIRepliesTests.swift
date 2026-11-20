import XCTest
@testable import SSCore

/// The demo's canned replies for Help Me Write.
final class DemoAIRepliesTests: XCTestCase {
    func testTheSameRequestGetsTheSameReply() {
        let one = AIWriteRequest(instructions: "i", transcript: "t", task: "Write my reply.")
        XCTAssertEqual(DemoAIReplies.reply(for: one), DemoAIReplies.reply(for: one))
        XCTAssertTrue(DemoAIReplies.replies.contains(DemoAIReplies.reply(for: one)))
        let asks = (0..<40).map { AIWriteRequest(instructions: "i", transcript: "t", task: "ask \($0)") }
        XCTAssertGreaterThan(Set(asks.map(DemoAIReplies.reply(for:))).count, 3, "different asks, different replies")
        XCTAssertFalse(DemoAIReplies.replies.isEmpty)
    }
}
