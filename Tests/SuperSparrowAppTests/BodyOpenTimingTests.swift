import Foundation
import SSCore
import XCTest
@testable import SuperSparrowApp

/// Opening a conversation whose bodies are not stored, while the first download is busy fetching bodies, through the
/// real reader and engine over a provider whose server takes 120 ms a body and serves four at once. Prints the local
/// shares of each open (the click to the request leaving; the answer to the body on screen), the wait at the server,
/// and how many background requests went out in between, then the medians. Gated with the other timings (`SS_PERF=1`):
/// the numbers move with whatever else the Mac is doing.
@MainActor
final class BodyOpenTimingTests: XCTestCase {
    func testOpeningConversationsWithoutBodiesWhileTheBackfillIsBusy() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SS_PERF"] == "1", "set SS_PERF=1 to time opens")
        let fixture = try BodyOpenFixture(conversations: 7)
        defer { fixture.close() }
        fixture.engine.start()
        // The backfill is under way: bodies are being fetched in the background.
        XCTAssertNotNil(BodyOpenFixture.spin(until: { fixture.provider.calls.count >= 6 }, timeout: 20), "the backfill began")

        var timings: [BodyOpenTiming] = []
        var arrivals: [ConversationID: TimeInterval] = [:]
        fixture.reader.onBodyArrived = { conversation in
            if arrivals[conversation] == nil { arrivals[conversation] = QueuedServerProvider.now() }
        }
        var handedToPage: [TimeInterval] = []
        for conversation in fixture.conversations {
            let newest = fixture.newest(of: conversation)
            // Settle between opens, as a reader does between messages; the backfill keeps working meanwhile.
            BodyOpenFixture.spin(until: { false }, timeout: 0.4)
            let clicked = QueuedServerProvider.now()
            fixture.reader.show(conversation)
            guard let rendered = BodyOpenFixture.spin(until: { fixture.shows(newest, of: conversation) }, timeout: 30),
                  let call = fixture.provider.call(for: newest.providerID), let served = call.served, let answered = call.answered else {
                XCTFail("the newest message of \(conversation.providerID) was shown")
                continue
            }
            let background = fixture.provider.calls.filter {
                $0.id.hasPrefix("bg-") && $0.requested > clicked && $0.requested < answered
            }.count
            timings.append(BodyOpenTiming(clicked: clicked, requested: call.requested, served: served, answered: answered,
                                          rendered: rendered, backgroundSentMeanwhile: background))
            // The reader hears of the body after it has handed the page its update: the engine's share and the main
            // thread's payload, against the page's own work after it.
            if let arrived = arrivals[conversation] { handedToPage.append(arrived - answered) }
        }
        // The first open pays for the web view's first render; the medians leave nothing out but read the rest.
        for (index, timing) in timings.enumerated() {
            print("""
                open \(index): click→request \(BodyOpenTiming.milliseconds(timing.clickToRequest)), \
                wait at server \(BodyOpenTiming.milliseconds(timing.waitAtServer)), \
                answer→rendered \(BodyOpenTiming.milliseconds(timing.answerToRendered)), \
                click→rendered \(BodyOpenTiming.milliseconds(timing.clickToRendered)), \
                background requests meanwhile \(timing.backgroundSentMeanwhile)
                """)
        }
        let median = BodyOpenTiming.median
        print("""
            BodyOpen medians over \(timings.count) opens: click→request \(BodyOpenTiming.milliseconds(median(timings.map(\.clickToRequest)))), \
            wait at server \(BodyOpenTiming.milliseconds(median(timings.map(\.waitAtServer)))), \
            answer→rendered \(BodyOpenTiming.milliseconds(median(timings.map(\.answerToRendered)))), \
            click→rendered \(BodyOpenTiming.milliseconds(median(timings.map(\.clickToRendered)))), \
            background requests meanwhile \(median(timings.map { Double($0.backgroundSentMeanwhile) })); \
            answer→update handed to the page \(BodyOpenTiming.milliseconds(median(handedToPage)))
            """)
    }
}
