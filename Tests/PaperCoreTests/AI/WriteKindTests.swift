import XCTest
@testable import PaperCore

/// What is written: its prompt version, whether an ask gives it anything to write from, and what is too long to send.
final class WriteKindTests: XCTestCase {
    func testEachKindHasItsOwnPromptVersion() {
        XCTAssertEqual(WriteKind.allCases, [.reply, .newMessage, .forward])
        XCTAssertEqual(WriteKind.reply.promptVersion, "write-reply-2")
        XCTAssertEqual(WriteKind.newMessage.promptVersion, "write-new-1")
        XCTAssertEqual(WriteKind.forward.promptVersion, "write-forward-1")
        XCTAssertEqual(Set(WriteKind.allCases.map(\.promptVersion)).count, WriteKind.allCases.count)
        XCTAssertEqual(WritePrompt.version, "write-reply-2", "the reply's prompt is the one it was")
    }

    /// A request says what it writes and its version follows: nothing a new message sends is logged as the reply's.
    func testARequestsPromptVersionFollowsItsKind() {
        for kind in WriteKind.allCases {
            let request = AIWriteRequest(kind: kind, instructions: "i", transcript: "t", task: "k")
            XCTAssertEqual(request.promptVersion, kind.promptVersion)
            XCTAssertFalse(request.wantsSubject, "a subject is asked for only by saying so")
            XCTAssertFalse(request.isRewrite)
        }
        var request = AIWriteRequest(kind: .reply, instructions: "i", transcript: "t", task: "k")
        request.kind = .forward
        XCTAssertEqual(request.promptVersion, "write-forward-1", "it cannot be set apart from the kind")
    }

    func testOnlyANewMessagesFullWriteIsReadForASubjectLine() {
        func request(_ kind: WriteKind, rewrite: Bool) -> AIWriteRequest {
            AIWriteRequest(kind: kind, instructions: "i", transcript: "", task: "k", wantsSubject: true, isRewrite: rewrite)
        }
        XCTAssertTrue(request(.newMessage, rewrite: false).readsSubjectLine)
        XCTAssertFalse(request(.newMessage, rewrite: true).readsSubjectLine)
        for kind in [WriteKind.reply, .forward] {
            XCTAssertFalse(request(kind, rewrite: false).readsSubjectLine)
            XCTAssertFalse(request(kind, rewrite: true).readsSubjectLine)
        }
    }

    func testTheUserTurnIsTheTaskAloneWhenNothingElseIsSent() {
        XCTAssertEqual(AIWriteRequest(kind: .newMessage, instructions: "i", transcript: "", task: "Write my message.").userTurn,
                       "Write my message.", "no empty lines where a conversation would be")
        XCTAssertEqual(AIWriteRequest(kind: .reply, instructions: "i", transcript: "mail", task: "Write my reply.").userTurn,
                       "mail\n\nWrite my reply.")
    }

    // MARK: Nothing to write from

    func testAReplyAndAForwardAlwaysHaveSomethingToWriteFrom() {
        for kind in [WriteKind.reply, .forward] {
            XCTAssertFalse(kind.hasNothingToWriteFrom(WriteAsk()), "\(kind): the conversation, the forwarded message")
            XCTAssertFalse(kind.hasNothingToWriteFrom(WriteAsk(instruction: "  ", draft: .notes(" "))))
        }
    }

    func testANewMessageNeedsNotesASelectionOrAnInstruction() {
        let kind = WriteKind.newMessage
        XCTAssertTrue(kind.hasNothingToWriteFrom(WriteAsk()))
        XCTAssertFalse(kind.hasNothingToWriteFrom(WriteAsk(instruction: "Invite the team to lunch")))
        XCTAssertFalse(kind.hasNothingToWriteFrom(WriteAsk(draft: .notes("lunch"))), "one word of notes is enough")
        XCTAssertFalse(kind.hasNothingToWriteFrom(WriteAsk(draft: .selection("see u thurs"))))
        XCTAssertFalse(kind.hasNothingToWriteFrom(WriteAsk(instruction: "Shorter", draft: .notes("lunch"))))
    }

    func testWhatIsEmptyOnceCleanedIsNothing() {
        let kind = WriteKind.newMessage
        for blank in ["", " ", "\n\t ", "\u{200B}", " \u{FEFF}\u{200D} \n"] {
            XCTAssertTrue(kind.hasNothingToWriteFrom(WriteAsk(instruction: blank)), "instruction “\(blank.debugDescription)”")
            XCTAssertTrue(kind.hasNothingToWriteFrom(WriteAsk(instruction: blank, draft: .notes(blank))))
            XCTAssertTrue(kind.hasNothingToWriteFrom(WriteAsk(instruction: blank, draft: .selection(blank))))
            XCTAssertFalse(kind.hasNothingToWriteFrom(WriteAsk(instruction: blank, draft: .notes("lunch"))))
            XCTAssertFalse(kind.hasNothingToWriteFrom(WriteAsk(instruction: "lunch", draft: .selection(blank))))
        }
    }

    // MARK: Too long to send

    private let long = String(repeating: "word ", count: 1_601)   // 8,004 characters once trimmed

    func testNotesAndASelectionAreRefusedWholeForEveryKind() {
        for kind in WriteKind.allCases {
            XCTAssertEqual(kind.lengthRefusal(of: WriteAsk(draft: .notes(long))), .tooLong(selection: false), "\(kind)")
            XCTAssertEqual(kind.lengthRefusal(of: WriteAsk(draft: .selection(long))), .tooLong(selection: true), "\(kind)")
            XCTAssertNil(kind.lengthRefusal(of: WriteAsk(instruction: "Shorter", draft: .notes(String(long.prefix(8_000))))))
            XCTAssertNil(kind.lengthRefusal(of: WriteAsk()))
        }
    }

    /// A new message's instruction can be the whole brief, so it is refused rather than cut; a reply's is cut as before.
    func testALongInstructionIsRefusedForTheNewKindsOnly() {
        XCTAssertEqual(WriteKind.newMessage.lengthRefusal(of: WriteAsk(instruction: long)), .instructionTooLong)
        XCTAssertEqual(WriteKind.forward.lengthRefusal(of: WriteAsk(instruction: long)), .instructionTooLong)
        XCTAssertEqual(WriteKind.newMessage.lengthRefusal(of: WriteAsk(instruction: long, draft: .notes("lunch"))), .instructionTooLong)
        XCTAssertNil(WriteKind.reply.lengthRefusal(of: WriteAsk(instruction: long)))
        XCTAssertNil(WriteKind.newMessage.lengthRefusal(of: WriteAsk(instruction: String(repeating: "a", count: 8_000))))
        XCTAssertEqual(WriteKind.newMessage.lengthRefusal(of: WriteAsk(instruction: String(repeating: "a", count: 8_001))), .instructionTooLong)
        XCTAssertNil(WriteKind.newMessage.lengthRefusal(of: WriteAsk(instruction: "  " + String(repeating: "a", count: 8_000) + "\n\u{200B}")),
                     "measured as it would be sent")
        XCTAssertEqual(WriteKind.forward.lengthRefusal(of: WriteAsk(instruction: long, draft: .selection(long))), .tooLong(selection: true),
                       "what would be replaced comes first")
        let limits = ReplyContextBuilder.Limits(maxAskCharacters: 10)
        XCTAssertEqual(WriteKind.forward.lengthRefusal(of: WriteAsk(instruction: "eleven chars"), limits: limits), .instructionTooLong)
    }
}
