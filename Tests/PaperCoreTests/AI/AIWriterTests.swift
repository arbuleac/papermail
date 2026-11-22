import XCTest
@testable import PaperCore

/// The service the UI calls: consent, one write per field, Stop, the deadline, and what reaches the UI.
@MainActor
final class AIWriterTests: XCTestCase {
    /// A provider that plays a script and records what it was asked and whether it was cancelled.
    final class ScriptedProvider: AIProvider, @unchecked Sendable {
        enum Step: Sendable {
            case event(AIWriteEvent)
            case pause(Duration)
            case fail(AIErrorTestsFailure)
            case hang
        }

        let kind: AIProviderKind
        let script: [Step]
        let healthAnswer: AIHealth
        private let lock = NSLock()
        private var recorded: [AIWriteRequest] = []
        private var cancelled = 0
        private var calledOnMain: [Bool] = []

        init(kind: AIProviderKind = .claudeAPI, script: [Step], health: AIHealth = .ready(detail: "Ready")) {
            self.kind = kind
            self.script = script
            self.healthAnswer = health
        }

        var requests: [AIWriteRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
        var cancellations: Int { lock.lock(); defer { lock.unlock() }; return cancelled }
        var writesOnMainThread: [Bool] { lock.lock(); defer { lock.unlock() }; return calledOnMain }

        /// The user actions each call came with.
        var actions: [AIUserAction.Kind] { lock.lock(); defer { lock.unlock() }; return recordedActions }
        private var recordedActions: [AIUserAction.Kind] = []

        func localHealth() -> AIHealth { healthAnswer }
        func check(_ action: AIUserAction) async -> AIHealth {
            lock.lock(); recordedActions.append(action.kind); lock.unlock()
            return .needsSetup(reason: "Checked")
        }

        func write(_ request: AIWriteRequest, action: AIUserAction) -> AsyncThrowingStream<AIWriteEvent, Error> {
            lock.lock()
            recordedActions.append(action.kind)
            recorded.append(request)
            calledOnMain.append(Thread.isMainThread)
            lock.unlock()
            let script = script
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for step in script {
                        switch step {
                        case .event(let event): continuation.yield(event)
                        case .pause(let duration): try? await Task.sleep(for: duration)
                        case .fail(let failure): continuation.finish(throwing: failure.error); return
                        case .hang: try? await Task.sleep(for: .seconds(3_600))
                        }
                        if Task.isCancelled { return }
                    }
                    continuation.finish()
                }
                continuation.onTermination = { [weak self] termination in
                    task.cancel()
                    if case .cancelled = termination, let self {
                        self.lock.lock(); self.cancelled += 1; self.lock.unlock()
                    }
                }
            }
        }
    }

    private var milestones: [String] = []
    private var consented: Set<AIProviderKind> = [.claudeAPI, .codex]
    private let field = AIFieldID(name: "quick reply")
    private let request = AIWriteRequest(instructions: "fixed", transcript: "<<<CONVERSATION x>>>mail<<<END CONVERSATION x>>>",
                                         task: "Write my reply.", model: "claude-opus-5-5")

    private func makeWriter(_ provider: (any AIProvider)?) -> AIWriter {
        AIWriter(resolve: { _ in provider }, hasConsent: { [unowned self] in self.consented.contains($0) },
                 milestones: { [unowned self] milestone, kind, _ in self.milestones.append("\(milestone.breadcrumbName) \(kind.rawValue)") })
    }

    private func collect(_ stream: AsyncThrowingStream<AIWriteEvent, Error>) async -> ([AIWriteEvent], AIError?) {
        var events: [AIWriteEvent] = []
        do {
            for try await event in stream { events.append(event) }
            return (events, nil)
        } catch {
            XCTAssertTrue(error is AIError, "the UI only ever sees AIError, got \(type(of: error))")
            return (events, error as? AIError)
        }
    }

    private func eventually(_ what: String, timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
        let clock = ContinuousClock()
        let end = clock.now + timeout
        while !condition() {
            if clock.now > end { return XCTFail("timed out waiting for \(what)") }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    private let configuration = AIProviderConfiguration(kind: .claudeAPI)

    // MARK: Writing

    func testTextStreamsThenFinishes() async {
        let provider = ScriptedProvider(script: [
            .event(.text("Thanks, ")), .pause(.milliseconds(5)), .event(.text("Thursday works.")),
            .event(.usage(AIUsage(inputTokens: 700, outputTokens: 13))), .event(.finished(.done)),
        ])
        let writer = makeWriter(provider)
        let stream = writer.write(request, using: configuration, in: field, action: pressedWrite)
        XCTAssertTrue(writer.isWriting(in: field))
        XCTAssertTrue(writer.isWriting)
        let (events, error) = await collect(stream)
        XCTAssertNil(error)
        XCTAssertEqual(events, [.text("Thanks, "), .text("Thursday works."), .usage(AIUsage(inputTokens: 700, outputTokens: 13)),
                                .finished(.done)])
        await eventually("the field to be free") { !writer.isWriting(in: field) }
        XCTAssertEqual(provider.requests, [request], "exactly what WritePrompt built, once")
        XCTAssertEqual(provider.writesOnMainThread, [false], "the provider starts its request off the main thread")
        await eventually("milestones") { milestones.count == 2 }
        XCTAssertEqual(milestones, ["write started claudeAPI", "write finished claudeAPI"])
    }

    func testReplaceAllIsPassedOnAndCounts() async {
        let provider = ScriptedProvider(kind: .codex, script: [.event(.replaceAll("Thanks, Thursday works.")), .event(.finished(.done))])
        let (events, error) = await collect(makeWriter(provider).write(request, using: AIProviderConfiguration(kind: .codex), in: field, action: pressedWrite))
        XCTAssertNil(error)
        XCTAssertEqual(events, [.replaceAll("Thanks, Thursday works."), .finished(.done)])
    }

    func testAStreamThatEndsWithoutSayingSoEndedNormally() async {
        let (events, error) = await collect(makeWriter(ScriptedProvider(script: [.event(.text("Hi"))])).write(request, using: configuration, in: field, action: pressedWrite))
        XCTAssertNil(error)
        XCTAssertEqual(events, [.text("Hi"), .finished(.done)])
    }

    func testNothingFollowsTheEnd() async {
        let provider = ScriptedProvider(script: [.event(.text("a")), .event(.finished(.done)), .event(.text("b"))])
        let (events, _) = await collect(makeWriter(provider).write(request, using: configuration, in: field, action: pressedWrite))
        XCTAssertEqual(events, [.text("a"), .finished(.done)])
    }

    func testEmptyDeltasAreDropped() async {
        let provider = ScriptedProvider(script: [.event(.text("")), .event(.text("x")), .event(.finished(.done))])
        let (events, _) = await collect(makeWriter(provider).write(request, using: configuration, in: field, action: pressedWrite))
        XCTAssertEqual(events, [.text("x"), .finished(.done)])
    }

    func testACutReplyKeepsItsText() async {
        let provider = ScriptedProvider(script: [.event(.text("Hi")), .event(.finished(.maxTokens))])
        let (events, error) = await collect(makeWriter(provider).write(request, using: configuration, in: field, action: pressedWrite))
        XCTAssertNil(error)
        XCTAssertEqual(events, [.text("Hi"), .finished(.maxTokens)])
    }

    // MARK: Failures

    func testARefusalIsAnError() async {
        let provider = ScriptedProvider(script: [.event(.text("I")), .event(.finished(.refused))])
        let (events, error) = await collect(makeWriter(provider).write(request, using: configuration, in: field, action: pressedWrite))
        XCTAssertEqual(events, [.text("I")])
        XCTAssertEqual(error, .refused)
        await eventually("milestones") { milestones.count == 2 }
        XCTAssertEqual(milestones.last, "write failed claudeAPI")
    }

    func testNothingWrittenIsAnError() async {
        for script: [ScriptedProvider.Step] in [
            [.event(.finished(.done))],
            [.event(.text("  \n")), .event(.finished(.done))],
            [.event(.usage(AIUsage(outputTokens: 4_000))), .event(.finished(.maxTokens))],
            [.event(.replaceAll("Hi")), .event(.replaceAll(" ")), .event(.finished(.done))],
        ] {
            let (_, error) = await collect(makeWriter(ScriptedProvider(script: script)).write(request, using: configuration, in: field, action: pressedWrite))
            XCTAssertEqual(error, .emptyReply, "\(script)")
        }
    }

    func testProviderFailuresAreMappedAndCarryNoText() async {
        let leaking = NSError(domain: "provider", code: 1, userInfo: [NSLocalizedDescriptionKey: request.transcript])
        let cases: [(AIErrorTestsFailure, AIError)] = [
            (.init(leaking), .badResponse(code: 0)),
            (.init(URLError(.notConnectedToInternet)), .offline),
            (.init(AIError.planLimit), .planLimit),
        ]
        for (failure, expected) in cases {
            let provider = ScriptedProvider(script: [.event(.text("partial")), .fail(failure)])
            let (events, error) = await collect(makeWriter(provider).write(request, using: configuration, in: field, action: pressedWrite))
            XCTAssertEqual(events, [.text("partial")])
            XCTAssertEqual(error, expected)
            XCTAssertFalse(String(describing: error).contains("mail"))
        }
        let selfCancelled = ScriptedProvider(script: [.event(.text("x")), .event(.finished(.cancelled))])
        let (_, error) = await collect(makeWriter(selfCancelled).write(request, using: configuration, in: field, action: pressedWrite))
        XCTAssertEqual(error, .cancelled, "a provider that stops on its own was not stopped by the user")
    }

    func testTheDeadlineEndsAHangingWrite() async {
        let provider = ScriptedProvider(script: [.event(.text("Hel")), .hang])
        var short = request
        short.deadline = .milliseconds(100)
        let writer = makeWriter(provider)
        let (events, error) = await collect(writer.write(short, using: configuration, in: field, action: pressedWrite))
        XCTAssertEqual(events, [.text("Hel")])
        XCTAssertEqual(error, .timedOut)
        await eventually("the provider to be cancelled") { provider.cancellations == 1 }
        await eventually("the field to be free") { !writer.isWriting(in: field) }
    }

    // MARK: Gates

    func testNothingIsSentWithoutConsent() async {
        consented = []
        let provider = ScriptedProvider(script: [.event(.text("x"))])
        let resolved = Counter()
        let writer = AIWriter(resolve: { _ in resolved.increment(); return provider }, hasConsent: { _ in false })
        let (events, error) = await collect(writer.write(request, using: configuration, in: field, action: pressedWrite))
        XCTAssertEqual(events, [])
        XCTAssertEqual(error, .consentRequired)
        XCTAssertEqual(resolved.value, 0, "no provider is even built")
        XCTAssertEqual(provider.requests, [])
        XCTAssertFalse(writer.isWriting)
    }

    func testConsentIsPerProvider() async {
        let provider = ScriptedProvider(kind: .openAIAPI, script: [.event(.text("x"))])
        let (_, error) = await collect(makeWriter(provider).write(request, using: AIProviderConfiguration(kind: .openAIAPI), in: field, action: pressedWrite))
        XCTAssertEqual(error, .consentRequired)
        XCTAssertEqual(provider.requests, [])
    }

    func testTheDemoWriterNeedsNoConsent() async {
        consented = []
        let provider = ScriptedProvider(kind: .demo, script: [.event(.text("x")), .event(.finished(.done))])
        let (_, error) = await collect(makeWriter(provider).write(request, using: AIProviderConfiguration(kind: .demo), in: field, action: pressedWrite))
        XCTAssertNil(error)
    }

    func testNoProviderMeansUnavailable() async {
        let writer = makeWriter(nil)
        let (_, error) = await collect(writer.write(request, using: configuration, in: field, action: pressedWrite))
        XCTAssertEqual(error, .unavailable)
        XCTAssertEqual(milestones, [])
        let health = await writer.localHealth(of: configuration)
        XCTAssertEqual(health, .unavailable(reason: "Claude isn't available right now"))
    }

    func testOneWriteAtATimePerField() async {
        let hanging = ScriptedProvider(script: [.hang])
        let writer = makeWriter(hanging)
        let first = writer.write(request, using: configuration, in: field, action: pressedWrite)
        let (_, busy) = await collect(writer.write(request, using: configuration, in: field, action: pressedWrite))
        XCTAssertEqual(busy, .busy)
        XCTAssertTrue(writer.isWriting(in: field), "the refused second write leaves the first alone")
        XCTAssertFalse(writer.isWriting(in: AIFieldID(name: "composer")))
        let other = writer.write(request, using: configuration, in: AIFieldID(name: "composer"), action: pressedWrite)
        XCTAssertTrue(writer.isWriting(in: AIFieldID(name: "composer")), "another field writes at the same time")
        writer.stopAll()
        XCTAssertFalse(writer.isWriting)
        let (firstEvents, _) = await collect(first)
        let (otherEvents, _) = await collect(other)
        XCTAssertEqual(firstEvents, [.finished(.cancelled)])
        XCTAssertEqual(otherEvents, [.finished(.cancelled)])
    }

    // MARK: Stopping

    func testStopEndsTheStreamCleanlyAndFreesTheField() async {
        let provider = ScriptedProvider(script: [.event(.text("Hel")), .hang])
        let writer = makeWriter(provider)
        let stream = writer.write(request, using: configuration, in: field, action: pressedWrite)
        var iterator = stream.makeAsyncIterator()
        let first = try? await iterator.next()
        XCTAssertEqual(first, .text("Hel"))
        writer.stop(field)
        XCTAssertFalse(writer.isWriting(in: field), "free at once, before the provider has wound down")
        let next = try? await iterator.next()
        XCTAssertEqual(next, .finished(.cancelled))
        let end = try? await iterator.next()
        XCTAssertNil(end ?? nil)
        await eventually("the provider to be cancelled") { provider.cancellations == 1 }
        XCTAssertEqual(milestones, ["write started claudeAPI", "write stopped claudeAPI"])

        let again = ScriptedProvider(script: [.event(.text("x")), .event(.finished(.done))])
        let (events, error) = await collect(self.makeWriter(again).write(request, using: configuration, in: field, action: pressedWrite))
        XCTAssertNil(error)
        XCTAssertEqual(events.last, .finished(.done))
        writer.stop(field)  // nothing running: nothing happens
    }

    /// A write asked for after the environment shut down (a card still building its context as the app quit) sends
    /// nothing and ends as a stop from outside does, so the card puts the field back.
    func testNothingIsWrittenAfterShutDown() async {
        let running = ScriptedProvider(script: [.event(.text("Hel")), .hang])
        let later = ScriptedProvider(script: [.event(.text("x")), .event(.finished(.done))])
        let resolved = Counter()
        let writer = AIWriter(resolve: { _ in
            resolved.increment()
            return resolved.value == 1 ? running : later
        }, hasConsent: { _ in true })
        let first = writer.write(request, using: configuration, in: field, action: pressedWrite)
        writer.shutDown()
        XCTAssertTrue(writer.isShutDown)
        let (firstEvents, _) = await collect(first)
        XCTAssertEqual(firstEvents.last, .finished(.cancelled), "the running write stops")
        let (events, error) = await collect(writer.write(request, using: configuration, in: AIFieldID(name: "composer"), action: pressedWrite))
        XCTAssertNil(error)
        XCTAssertEqual(events, [.finished(.cancelled)])
        XCTAssertEqual(resolved.value, 1, "no provider is built for a write after the shut-down")
        XCTAssertEqual(later.requests, [], "and nothing is sent")
        XCTAssertFalse(writer.isWriting)
    }

    func testCancellingTheReaderCancelsTheProvider() async {
        let provider = ScriptedProvider(script: [.event(.text("Hel")), .hang])
        let writer = makeWriter(provider)
        let stream = writer.write(request, using: configuration, in: field, action: pressedWrite)
        let reader = Task { await self.collect(stream) }
        await eventually("the request to start") { provider.requests.count == 1 }
        reader.cancel()
        _ = await reader.value
        await eventually("the provider to be cancelled") { provider.cancellations == 1 }
        await eventually("the field to be free") { !writer.isWriting(in: field) }
        await eventually("milestones") { milestones.count == 2 }
        XCTAssertEqual(milestones.last, "write stopped claudeAPI")
    }

    // MARK: Health

    func testHealthIsLocalAndCheckCarriesTheUsersAction() async {
        let provider = ScriptedProvider(script: [], health: .ready(detail: "Ready · Claude Opus 5.5"))
        let writer = makeWriter(provider)
        let health = writer.localHealth(of: configuration)
        XCTAssertEqual(health, .ready(detail: "Ready · Claude Opus 5.5"))
        XCTAssertEqual(provider.actions, [], "local health asks for no action and makes no contact")
        let check = await writer.check(configuration, action: pressedCheck)
        XCTAssertEqual(check, .needsSetup(reason: "Checked"))
        XCTAssertEqual(provider.actions, [.check])
        _ = await collect(writer.write(request, using: configuration, in: field, action: pressedWrite))
        XCTAssertEqual(provider.actions, [.check, .write], "the write carries the Write that asked for it")
    }

    func testCheckDefaultsToLocalHealth() async {
        struct Plain: AIProvider {
            let kind = AIProviderKind.claudeCode
            func localHealth() -> AIHealth { .needsSetup(reason: "Claude Code is signed out. Run claude in Terminal.") }
            func write(_ request: AIWriteRequest, action: AIUserAction) -> AsyncThrowingStream<AIWriteEvent, Error> {
                AsyncThrowingStream { $0.finish() }
            }
        }
        let check = await Plain().check(pressedCheck)
        XCTAssertEqual(check, .needsSetup(reason: "Claude Code is signed out. Run claude in Terminal."))
        XCTAssertEqual(Plain().destination, .anthropic)
    }
}

/// A Sendable wrapper for an error a script throws.
struct AIErrorTestsFailure: @unchecked Sendable {
    let error: Error
    init(_ error: Error) { self.error = error }
}
