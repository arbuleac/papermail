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

    /// A selection's rewrite has its own prompt per kind, and the request names it (§5.56).
    func testEachKindHasItsOwnRewritePromptVersion() {
        XCTAssertEqual(WriteKind.reply.rewritePromptVersion, "rewrite-reply-1")
        XCTAssertEqual(WriteKind.newMessage.rewritePromptVersion, "rewrite-new-1")
        XCTAssertEqual(WriteKind.forward.rewritePromptVersion, "rewrite-forward-1")
        let versions = WriteKind.allCases.flatMap { [$0.promptVersion, $0.rewritePromptVersion] }
        XCTAssertEqual(Set(versions).count, versions.count)
        for kind in WriteKind.allCases {
            let rewrite = AIWriteRequest(kind: kind, instructions: "i", transcript: "t", task: "k", isRewrite: true)
            XCTAssertEqual(rewrite.promptVersion, kind.rewritePromptVersion)
            XCTAssertFalse(rewrite.readsRewriteAnswer, "a rewrite that sent no draft around it passes as it comes")
            var drafted = rewrite
            drafted.rewrite = WriteRewriteFrame(selection: "x")
            XCTAssertTrue(drafted.readsRewriteAnswer)
        }
    }

    /// The reply's prompt is as it was: people's permission was given for what it sends, so its words do not change
    /// without a new version (`PromptChecksum`).
    func testTheReplysWordsAreTheOnesTheyWere() {
        XCTAssertEqual([true, false].map { PromptChecksum.of(WritePrompt.instructions(appendsSignature: $0)) },
                       PromptChecksum.reply, "the words of write-reply-2 changed")
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

    /// A picture in the body is its attachment character, which holds no words: notes or a selection of pictures alone
    /// are nothing to write from in a new message, and a picture with words beside it is still notes. A reply's ask is
    /// read as it always was.
    func testPicturesAloneAreNothingToWriteFromInANewMessage() {
        let kind = WriteKind.newMessage
        for pictures in ["\u{FFFC}", "\u{FFFC}\u{FFFC}", "\n\u{FFFC} \n\u{FFFC}\n", " \u{200B}\u{FFFC}"] {
            XCTAssertTrue(kind.hasNothingToWriteFrom(WriteAsk(draft: .notes(pictures))), pictures.debugDescription)
            XCTAssertTrue(kind.hasNothingToWriteFrom(WriteAsk(draft: .selection(pictures))), pictures.debugDescription)
            XCTAssertFalse(kind.hasNothingToWriteFrom(WriteAsk(instruction: "Say hi", draft: .notes(pictures))), "an instruction is a brief")
        }
        XCTAssertFalse(kind.hasNothingToWriteFrom(WriteAsk(draft: .notes("lunch \u{FFFC}"))), "words beside a picture are notes")
        XCTAssertFalse(kind.hasNothingToWriteFrom(WriteAsk(draft: .notes("\u{FFFC}\nsee above"))))
        XCTAssertEqual(WriteAsk(instruction: "\u{FFFC}", draft: .notes("a\u{FFFC}b")).withoutPictures,
                       WriteAsk(instruction: "\u{FFFC}", draft: .notes("ab")), "only the notes or the selection hold pictures")
        XCTAssertEqual(WriteAsk(draft: .selection("\u{FFFC}x")).withoutPictures, WriteAsk(draft: .selection("x")))
        XCTAssertEqual(WriteAsk().withoutPictures, WriteAsk())
        // Each attachment character goes, also one a mark joins, which a search by what the user sees would miss; and
        // invisible marks beside pictures say nothing either.
        XCTAssertEqual(WriteAsk(draft: .notes("\u{FFFC}\u{FE0F}")).withoutPictures, WriteAsk(draft: .notes("\u{FE0F}")))
        for marked in ["\u{FFFC}\u{FE0F}", "\u{FEFF}\u{FFFC}", "\u{200F}\u{FFFC}\u{200F}", "\u{E0041}\u{FFFC}", "\u{2060}"] {
            XCTAssertTrue(kind.hasNothingToWriteFrom(WriteAsk(draft: .notes(marked))), marked.debugDescription)
        }
        XCTAssertFalse(kind.hasNothingToWriteFrom(WriteAsk(draft: .notes("\u{FFFC}\u{0301}"))), "a mark that is seen is something")
        for other in [WriteKind.reply, .forward] {
            XCTAssertFalse(other.hasNothingToWriteFrom(WriteAsk(draft: .notes("\u{FFFC}"))), "\(other)")
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
