import Foundation
import PaperCore
import XCTest
@testable import PaperApp

/// The real reader over the real engine, opening conversations whose bodies the store does not have yet
/// (docs/ARCHITECTURE.md, "Opening a message"): the message it opens on is asked for first and alone, the folded rest
/// after it, a message the user turns to jumps the queue, and the backfill sends nothing while the reader waits. The
/// provider's server takes a while per body and serves four at once, as a mailbox does; nothing reaches the network.
@MainActor
final class ReaderBodyPriorityTests: XCTestCase {
    private var fixture: BodyOpenFixture?

    override func tearDown() {
        fixture?.close()
        fixture = nil
        super.tearDown()
    }

    private func makeFixture(backlog: Int = 0, latency: TimeInterval = 0.05) throws -> BodyOpenFixture {
        let fixture = try BodyOpenFixture(backlog: backlog, conversations: 2, messagesEach: 6, latency: latency)
        self.fixture = fixture
        return fixture
    }

    private func ids(of conversation: ConversationID, in fixture: BodyOpenFixture) -> [String] {
        ((try? fixture.store.messages(in: conversation)) ?? []).sorted { $0.date < $1.date }.map(\.id.providerID)
    }

    func testTheNewestBodyIsAskedForFirstAndTheFoldedOnesFollowItTwoAtATime() throws {
        let fixture = try makeFixture()
        let conversation = fixture.conversations[0]
        let messages = ids(of: conversation, in: fixture)
        let newest = fixture.newest(of: conversation)
        fixture.reader.show(conversation)
        XCTAssertNotNil(BodyOpenFixture.spin(until: { fixture.shows(newest, of: conversation) }, timeout: 10), "the newest is shown")
        XCTAssertNotNil(BodyOpenFixture.spin(until: {
            messages.allSatisfy { fixture.reader.pool.current?.renderedInputs?.hasBody(MessageID(accountID: newest.accountID, providerID: $0)) == true }
        }, timeout: 10), "and then every folded body")

        let calls = fixture.provider.calls
        XCTAssertEqual(calls.first?.id, newest.providerID, "the message the reader opens on goes first")
        XCTAssertEqual(calls.first?.priority, .foreground)
        let newestAnswered = try XCTUnwrap(calls.first?.answered)
        let folded = calls.dropFirst()
        XCTAssertEqual(Set(folded.map(\.id)), Set(messages.dropLast()), "each folded body once")
        XCTAssertTrue(folded.allSatisfy { $0.requested >= newestAnswered }, "none of them shared the provider with it")
        XCTAssertLessThanOrEqual(fixture.provider.maxConcurrent { $0 != newest.providerID }, 2, "two at a time")
    }

    func testAMessageTheUserTurnsToJumpsAheadOfTheOtherFoldedBodies() throws {
        let fixture = try makeFixture()
        let conversation = fixture.conversations[0]
        let messages = ids(of: conversation, in: fixture)
        let newest = fixture.newest(of: conversation)
        fixture.provider.hold([newest.providerID])
        fixture.reader.show(conversation)
        XCTAssertNotNil(BodyOpenFixture.spin(until: { fixture.provider.calls.count == 1 }, timeout: 10))
        BodyOpenFixture.spin(until: { false }, timeout: 0.2)
        XCTAssertEqual(fixture.provider.calls.map(\.id), [newest.providerID], "the folded bodies wait for the newest")

        // A click on the second message's card (the shell's `select`) makes it the target.
        let turnedTo = MessageID(accountID: newest.accountID, providerID: messages[1])
        fixture.reader.setTarget(turnedTo)
        XCTAssertNotNil(BodyOpenFixture.spin(until: { fixture.shows(turnedTo, of: conversation) }, timeout: 10),
                        "its body arrives and shows while the newest is still on its way")
        XCTAssertEqual(fixture.provider.calls.map(\.id), [newest.providerID, turnedTo.providerID], "ahead of the other folded ones")

        fixture.provider.release(newest.providerID)
        XCTAssertNotNil(BodyOpenFixture.spin(until: { fixture.provider.calls.count == messages.count }, timeout: 10))
        XCTAssertEqual(fixture.provider.calls.map(\.id).filter { $0 == turnedTo.providerID }.count, 1, "fetched once")
    }

    /// A neighbour's bodies the pre-render asked for wait behind the shown conversation's opened body. Shown in its turn,
    /// that neighbour's newest goes at once, even while the other opened body is still on its way.
    func testShowingAPrerenderedConversationPutsItsNewestBodyFirst() throws {
        let fixture = try makeFixture()
        let first = fixture.conversations[0]
        let second = fixture.conversations[1]
        let firstNewest = fixture.newest(of: first)
        let secondNewest = fixture.newest(of: second)
        fixture.provider.hold([firstNewest.providerID])
        fixture.reader.show(first)
        XCTAssertNotNil(BodyOpenFixture.spin(until: { fixture.provider.calls.count == 1 }, timeout: 10))
        fixture.reader.prerender([second])
        XCTAssertNotNil(BodyOpenFixture.spin(until: { fixture.reader.pool.slot(rendering: second) != nil }, timeout: 10),
                        "the neighbour is pre-rendered")
        BodyOpenFixture.spin(until: { false }, timeout: 0.3)
        XCTAssertEqual(fixture.provider.calls.map(\.id), [firstNewest.providerID], "its bodies wait behind the opened one")

        fixture.reader.show(second)
        XCTAssertNotNil(BodyOpenFixture.spin(until: { fixture.shows(secondNewest, of: second) }, timeout: 10),
                        "shown, its newest body arrives")
        XCTAssertEqual(fixture.provider.calls.map(\.id), [firstNewest.providerID, secondNewest.providerID],
                       "ahead of the rest, while the first conversation's is still on its way")
        XCTAssertNil(fixture.provider.call(for: firstNewest.providerID)?.answered)
        fixture.provider.release(firstNewest.providerID)
        XCTAssertNotNil(BodyOpenFixture.spin(until: { fixture.provider.calls.count == 12 }, timeout: 10), "then every other body")
    }

    func testTheBackfillSendsNothingWhileTheReaderWaitsForABody() throws {
        let fixture = try makeFixture(backlog: 300, latency: 0.1)
        fixture.engine.start()
        XCTAssertNotNil(BodyOpenFixture.spin(until: { fixture.provider.calls.count >= 6 }, timeout: 20), "the backfill is fetching bodies")
        for conversation in fixture.conversations {
            let newest = fixture.newest(of: conversation)
            fixture.reader.show(conversation)
            XCTAssertNotNil(BodyOpenFixture.spin(until: { fixture.shows(newest, of: conversation) }, timeout: 20))
            let opened = try XCTUnwrap(fixture.provider.call(for: newest.providerID))
            let answered = try XCTUnwrap(opened.answered)
            let meanwhile = fixture.provider.calls.filter { $0.id.hasPrefix("bg-") && $0.requested > opened.requested && $0.requested < answered }
            XCTAssertEqual(meanwhile.map(\.id), [], "no background body went out while the opened one was on its way")
            XCTAssertNotNil(opened.served)
            XCTAssertEqual(try XCTUnwrap(opened.served) - opened.requested, 0, accuracy: 0.05,
                           "the server took it at once: the backfill let nothing through between this open and the last")
        }
    }
}
