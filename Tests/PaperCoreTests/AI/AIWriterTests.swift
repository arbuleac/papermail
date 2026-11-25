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
    /// The join outcome each milestone carried, in order.
    private var joins: [WriteJoinOutcome?] = []
    private var consented: Set<AIProviderKind> = [.claudeAPI, .codex]
    /// What the user allowed to be written, and what the writer asked about, in order.
    private var consentedWrites = Set(WriteKind.allCases)
    private var consentAsked: [WriteKind] = []
    private let field = AIFieldID(name: "quick reply")
    private let request = AIWriteRequest(kind: .reply, instructions: "fixed",
                                         transcript: "<<<CONVERSATION x>>>mail<<<END CONVERSATION x>>>",
                                         task: "Write my reply.", model: "claude-opus-5-5")

    private func makeWriter(_ provider: (any AIProvider)?) -> AIWriter {
        AIWriter(resolve: { _ in provider },
                 hasConsent: { [unowned self] kind, writing in
                     self.consentAsked.append(writing)
                     return self.consented.contains(kind) && self.consentedWrites.contains(writing)
                 },
                 milestones: { [unowned self] milestone, kind, _, join in
                     self.milestones.append("\(milestone.breadcrumbName) \(kind.rawValue)")
                     self.joins.append(join)
                 })
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
        let writer = AIWriter(resolve: { _ in resolved.increment(); return provider }, hasConsent: { _, _ in false })
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

    // MARK: Permission by what is written

    /// A request of `kind`, as `WritePrompt` would hand it over (the words do not matter here).
    private func writing(_ kind: WriteKind, wantsSubject: Bool = false, isRewrite: Bool = false) -> AIWriteRequest {
        AIWriteRequest(kind: kind, instructions: "fixed", transcript: "", task: "Write my message from this brief:\nlunch on Thursday",
                       wantsSubject: wantsSubject, isRewrite: isRewrite, fence: "1a2b3c4d")
    }

    /// Permission given for replies does not stand for a new message or a forward: the writer asks about the request's
    /// own kind and sends nothing without it.
    func testConsentIsForWhatIsWritten() async {
        consentedWrites = [.reply]
        for kind in [WriteKind.newMessage, .forward] {
            let provider = ScriptedProvider(script: [.event(.text("x")), .event(.finished(.done))])
            let resolved = Counter()
            let writer = AIWriter(resolve: { _ in resolved.increment(); return provider },
                                  hasConsent: { [unowned self] provider, writing in
                                      self.consentAsked.append(writing)
                                      return self.consented.contains(provider) && self.consentedWrites.contains(writing)
                                  })
            let (events, error) = await collect(writer.write(writing(kind), using: configuration, in: field, action: pressedWrite))
            XCTAssertEqual(events, [], "\(kind)")
            XCTAssertEqual(error, .consentRequired, "\(kind)")
            XCTAssertEqual(resolved.value, 0, "no provider is even built")
            XCTAssertEqual(provider.requests, [])
            XCTAssertFalse(writer.isWriting)
        }
        let provider = ScriptedProvider(script: [.event(.text("x")), .event(.finished(.done))])
        let (_, error) = await collect(makeWriter(provider).write(request, using: configuration, in: field, action: pressedWrite))
        XCTAssertNil(error, "the reply still writes")
        XCTAssertEqual(consentAsked, [.newMessage, .forward, .reply], "asked with each request's own kind")

        consentedWrites = [.reply, .newMessage, .forward]
        for kind in [WriteKind.newMessage, .forward] {
            let provider = ScriptedProvider(script: [.event(.text("x")), .event(.finished(.done))])
            let (_, error) = await collect(makeWriter(provider).write(writing(kind), using: configuration, in: field, action: pressedWrite))
            XCTAssertNil(error, "\(kind)")
            XCTAssertEqual(provider.requests.map(\.kind), [kind])
        }
    }

    func testTheDemoWriterNeedsNoConsentWhateverItWrites() async {
        consented = []
        consentedWrites = []
        for kind in WriteKind.allCases {
            let provider = ScriptedProvider(kind: .demo, script: [.event(.text("x")), .event(.finished(.done))])
            let (_, error) = await collect(makeWriter(provider).write(writing(kind), using: AIProviderConfiguration(kind: .demo), in: field, action: pressedWrite))
            XCTAssertNil(error, "\(kind)")
        }
        XCTAssertEqual(consentAsked, [], "nothing leaves the Mac, so nothing is asked")
    }

    // MARK: A new message's subject line

    private let answer = "Subject: Offsite in March\n\nHi Priya,\n\nCould we look at dates?"
    private let answerBody = "Hi Priya,\n\nCould we look at dates?"

    private struct Written {
        var events: [AIWriteEvent]
        var error: AIError?

        /// The text as a reader holds it: deltas appended, a whole text put in their place.
        var text: String {
            events.reduce(into: "") { text, event in
                if case .text(let more) = event { text += more }
                if case .replaceAll(let all) = event { text = all }
            }
        }

        var subjects: [String] {
            events.compactMap { if case .subject(let subject) = $0 { return subject } else { return nil } }
        }

        var replacedText: Bool {
            events.contains { if case .replaceAll = $0 { return true } else { return false } }
        }
    }

    private func write(_ events: [AIWriteEvent], as request: AIWriteRequest) async -> Written {
        let provider = ScriptedProvider(script: events.map { .event($0) })
        let (events, error) = await collect(makeWriter(provider).write(request, using: configuration, in: field, action: pressedWrite))
        return Written(events: events, error: error)
    }

    /// Deltas cut anywhere: inside the marker, inside the subject, between the two line breaks, one character at a time.
    func testTheSubjectLineIsTakenOffHoweverTheDeltasAreCut() async {
        let characters = Array(answer)
        var cuts: [[String]] = [[answer], characters.map { String($0) }]
        for index in 1..<characters.count { cuts.append([String(characters[..<index]), String(characters[index...])]) }
        for pieces in cuts {
            let written = await write(pieces.map { .text($0) } + [.finished(.done)], as: writing(.newMessage, wantsSubject: true))
            XCTAssertNil(written.error)
            XCTAssertEqual(written.text, answerBody, "\(pieces.count) pieces, the first \(pieces[0].count) long")
            XCTAssertEqual(Array(written.events.suffix(2)), [.subject("Offsite in March"), .finished(.done)],
                           "the subject comes once, just before the end")
            XCTAssertEqual(written.subjects.count, 1)
            XCTAssertFalse(written.replacedText, "the body only ever grew, so nothing shown is taken back")
            XCTAssertFalse(written.events.contains(.text("")))
        }
    }

    /// Codex sends its whole message at the end, subject line included.
    func testTheWholeTextAtOnceIsSplit() async {
        let written = await write([.replaceAll(answer), .finished(.done)], as: writing(.newMessage, wantsSubject: true))
        XCTAssertEqual(written.events, [.text(answerBody), .subject("Offsite in March"), .finished(.done)])
    }

    /// Claude Code and OpenAI can send the whole text after deltas, and it may differ: the last word is the whole text's.
    func testTheWholeTextAfterDeltasReplacesBodyAndSubject() async {
        let written = await write([.text("Subject: Offsite\n\nHi Pri"), .text("ya,"), .replaceAll("Subject: Dates in March\n\nHello Priya,"),
                                   .text(" a word more."), .finished(.done)], as: writing(.newMessage, wantsSubject: true))
        XCTAssertEqual(written.events, [.text("Hi Pri"), .text("ya,"), .replaceAll("Hello Priya,"), .text(" a word more."),
                                        .subject("Dates in March"), .finished(.done)])
        let same = await write([.text("Subject: Offsite\n\nHi"), .replaceAll("Subject: Offsite\n\nHi"), .finished(.done)],
                               as: writing(.newMessage, wantsSubject: true))
        XCTAssertEqual(same.events, [.text("Hi"), .subject("Offsite"), .finished(.done)], "the same body again changes nothing")
        let after = await write([.text("Hello there"), .replaceAll("Subject: Offsite\n\nHi"), .finished(.done)],
                                as: writing(.newMessage, wantsSubject: true))
        XCTAssertEqual(after.events, [.text("Hello there"), .replaceAll("Hi"), .subject("Offsite"), .finished(.done)])
    }

    func testAnAnswerWithoutTheLineIsAllBody() async {
        for text in ["Hi Priya,\n\nCould we look at dates?", "Betreff: Termine im März\n\nHallo Priya,", "**Subject:** Offsite\n\nHi",
                     "Subjects we could cover:\n\nBudget."] {
            let written = await write([.text(String(text.prefix(4))), .text(String(text.dropFirst(4))), .finished(.done)],
                                      as: writing(.newMessage, wantsSubject: true))
            XCTAssertNil(written.error)
            XCTAssertEqual(written.text, text, "a translated or dressed-up marker is not guessed at")
            XCTAssertEqual(written.subjects, [], "and no subject is proposed")
        }
        // Held as a possible start of the marker, then the stream ended: it was the message after all.
        let short = await write([.text("Sub")], as: writing(.newMessage, wantsSubject: true))
        XCTAssertEqual(short.events, [.text("Sub"), .finished(.done)])
    }

    func testASubjectWithNothingUnderItIsNothingWritten() async {
        for events: [AIWriteEvent] in [
            [.text("Subject: Offsite in March"), .finished(.done)],
            [.text("Subject: Offsite in March\n\n"), .finished(.done)],
            [.replaceAll("Subject: Offsite in March\n \n"), .finished(.maxTokens)],
            [.text("Hi"), .replaceAll("Subject: Offsite in March"), .finished(.done)],
        ] {
            let written = await write(events, as: writing(.newMessage, wantsSubject: true))
            XCTAssertEqual(written.error, .emptyReply, "\(events)")
            XCTAssertEqual(written.subjects, [], "no subject without a message under it")
        }
    }

    /// The user typed a subject, so none was asked for: a model that sends the line anyway does not get it into the body.
    func testALineNobodyAskedForIsDropped() async {
        let written = await write([.text("Subject: Offsite"), .text(" in March\n\nHi Priya,"), .finished(.done)], as: writing(.newMessage))
        XCTAssertEqual(written.events, [.text("Hi Priya,"), .finished(.done)])
    }

    func testRepliesForwardsAndRewritesPassExactlyAsSent() async {
        let events: [AIWriteEvent] = [.text("Sub"), .text("ject: Offsite in March\n"), .text("\nHi Priya,"),
                                      .replaceAll("Subject: Offsite in March\n\nHi Priya,"), .finished(.done)]
        var requests = [writing(.reply), writing(.forward), writing(.reply, isRewrite: true), writing(.forward, isRewrite: true),
                        writing(.newMessage, isRewrite: true)]
        // Flags that only a new message's full write may carry change nothing elsewhere.
        requests += [writing(.reply, wantsSubject: true), writing(.forward, wantsSubject: true),
                     writing(.newMessage, wantsSubject: true, isRewrite: true)]
        for request in requests {
            let written = await write(events, as: request)
            XCTAssertEqual(written.events, events, "\(request.kind) rewrite \(request.isRewrite)")
        }
    }

    // MARK: A rewrite that sent the draft around its selection

    /// “John is coming tomorrow.” with “John” selected: its after window offered.
    private let john = WriteRewriteFrame(selection: "John", gapAfter: " ", after: "is coming tomorrow", trail: ".")
    private let seamed = "Priya and Ben\n<<<AFTER 1a2b3c4d>>>are coming tomorrow<<<END AFTER 1a2b3c4d>>>"

    private func rewriting(_ frame: WriteRewriteFrame?, kind: WriteKind = .reply) -> AIWriteRequest {
        AIWriteRequest(kind: kind, instructions: "fixed", transcript: "", task: "the draft, marked", isRewrite: true,
                       fence: "1a2b3c4d", rewrite: frame)
    }

    private func neverShowsAMarker(_ written: Written, file: StaticString = #filePath, line: UInt = #line) {
        for event in written.events {
            switch event {
            case .text(let text), .replaceAll(let text):
                XCTAssertFalse(text.contains("<"), "never a marker: \(text)", file: file, line: line)
                XCTAssertFalse(text.contains("AFTER"), file: file, line: line)
            default:
                break
            }
        }
    }

    func testARewritesSeamLineNeverReachesTheReaderHoweverItArrives() async {
        let join = AIWriteEvent.join(WriteJoin(after: "are coming tomorrow"))
        // One character at a time.
        let deltas = await write(Array(seamed).map { .text(String($0)) } + [.finished(.done)], as: rewriting(john))
        XCTAssertNil(deltas.error)
        XCTAssertEqual(deltas.text, "Priya and Ben\n")
        XCTAssertEqual(Array(deltas.events.suffix(2)), [join, .finished(.done)], "the join comes once, just before the end")
        XCTAssertFalse(deltas.replacedText, "the part only grew")
        neverShowsAMarker(deltas)
        // Deltas, then the same whole text: nothing more; then a different one: one replacement.
        let same = await write([.text("Priya and "), .text("Ben\n<<<AF"), .replaceAll(seamed), .finished(.done)], as: rewriting(john))
        XCTAssertEqual(same.events, [.text("Priya and "), .text("Ben"), .text("\n"), join, .finished(.done)])
        let other = await write([.text("Priya and Ben"), .replaceAll("Priya, Ben\n<<<AFTER 1a2b3c4d>>>are coming tomorrow"
                                                                      + "<<<END AFTER 1a2b3c4d>>>"), .finished(.done)],
                                as: rewriting(john))
        XCTAssertEqual(other.events, [.text("Priya and Ben"), .replaceAll("Priya, Ben"), .text("\n"), join, .finished(.done)])
        neverShowsAMarker(other)
        // The whole text at the end, as Codex sends it.
        let whole = await write([.replaceAll(seamed), .finished(.done)], as: rewriting(john))
        XCTAssertEqual(whole.events, [.text("Priya and Ben"), .text("\n"), join, .finished(.done)],
                       "a line break the part ends on shows only once the answer has ended")
    }

    func testASeamLineAloneIsNothingWritten() async {
        let written = await write([.text("<<<AFTER 1a2b3c4d>>>are coming tomorrow<<<END AFTER 1a2b3c4d>>>"), .finished(.done)],
                                  as: rewriting(john))
        XCTAssertEqual(written.error, .emptyReply)
        XCTAssertFalse(written.events.contains(.join(WriteJoin(after: "are coming tomorrow"))))
    }

    func testAnAnswerThatCopiesTheDraftFails() async {
        let frame = WriteRewriteFrame(lead: "We met on Monday to go over the plan for the spring offsite, and everyone agreed that "
                                          + "the venue by the river is the best choice for the whole team. ",
                                      selection: "we can has the garden", trail: "")
        let copy = "We can have the garden, since everyone agreed that the venue by the river is the best choice for the whole team."
        let written = await write([.text(copy), .finished(.done)], as: rewriting(frame))
        XCTAssertEqual(written.error, .rewriteRepeated)
        let echo = await write([.text("the whole team. "), .finished(.done)], as: rewriting(frame))
        XCTAssertEqual(echo.error, .rewriteRepeated, "an answer that was the draft's end and nothing else")
        let stripped = await write([.text("the whole team. We can have the garden"), .finished(.done)], as: rewriting(frame))
        XCTAssertNil(stripped.error)
        XCTAssertEqual(stripped.text, "We can have the garden", "a restated edge is taken off before the part lands")
        XCTAssertTrue(stripped.replacedText)
    }

    /// A seam line whose markers the model wrote wrongly holds the request's code, which nothing it was given holds:
    /// it never lands in the draft, and counts as a seam line that did not pass.
    func testAMiswrittenSeamLineNeverReachesTheDraft() async {
        joins = []
        let written = await write([.text("Priya and Ben\n<<<AFTER 1a2b3c4d>>are coming tomorrow<<<END AFTER 1a2b3c4d>>"),
                                   .finished(.done)], as: rewriting(john))
        XCTAssertNil(written.error)
        XCTAssertEqual(written.text, "Priya and Ben\n")
        XCTAssertFalse(written.text.contains("1a2b3c4d"))
        neverShowsAMarker(written)
        XCTAssertEqual(joins, [nil, .refused], "a seam line came, and none passed")
        for spaced in ["<<< AFTER 1a2b3c4d >>>are coming<<< END AFTER 1a2b3c4d >>>", "<<<AFTER: 1A2B3C4D>>>are coming"] {
            let deltas = await write(Array(spaced).map { .text(String($0)) } + [.finished(.done)], as: rewriting(john))
            XCTAssertEqual(deltas.error, .emptyReply, "a miswritten seam line alone is nothing written: \(spaced)")
            neverShowsAMarker(deltas)
        }
    }

    func testAProvidersOwnJoinIsDropped() async {
        let written = await write([.join(WriteJoin(before: "x")), .text("Priya and Ben"), .finished(.done)], as: rewriting(john))
        XCTAssertEqual(written.events, [.text("Priya and Ben"), .finished(.done)])
        let whole = await write([.join(WriteJoin(before: "x")), .text("Hi"), .finished(.done)], as: writing(.reply))
        XCTAssertEqual(whole.events, [.text("Hi"), .finished(.done)])
    }

    func testTheMilestoneSaysHowTheWordsBesideTheSelectionCameOut() async {
        let both = WriteRewriteFrame(before: "40 people and", gapBefore: " ", selection: "we can has", gapAfter: "",
                                     after: ", so the March", trail: " dates work.")
        let cases: [(String, WriteRewriteFrame, WriteJoinOutcome)] = [
            ("we can have the garden", both, .none),
            ("we can have\n<<<BEFORE 1a2b3c4d>>>40 people, and<<<END BEFORE 1a2b3c4d>>>", both, .before),
            ("we can have\n<<<AFTER 1a2b3c4d>>>; so the March<<<END AFTER 1a2b3c4d>>>", both, .after),
            ("we can have\n<<<BEFORE 1a2b3c4d>>>40 people, and<<<END BEFORE 1a2b3c4d>>>\n"
                + "<<<AFTER 1a2b3c4d>>>; so the March<<<END AFTER 1a2b3c4d>>>", both, .both),
            ("we can have\n<<<BEFORE 1a2b3c4d>>>I think that maybe<<<END BEFORE 1a2b3c4d>>>", both, .refused),
            ("we can have\n<<<AFTER 1a2b3c4d>>>are coming", both, .refused),
            ("Priya and Ben\n<<<BEFORE 1a2b3c4d>>>so<<<END BEFORE 1a2b3c4d>>>", john, .refused),
        ]
        for (answer, frame, outcome) in cases {
            joins = []
            _ = await write([.text(answer), .finished(.done)], as: rewriting(frame))
            XCTAssertEqual(joins, [nil, outcome], answer)
        }
        for request in [writing(.reply), writing(.newMessage, wantsSubject: true), rewriting(nil)] {
            joins = []
            _ = await write([.text("we can have"), .finished(.done)], as: request)
            XCTAssertEqual(joins, [nil, nil], "whole writes and the ALONE form carry none")
        }
        joins = []
        let failing = ScriptedProvider(script: [.event(.text("we can have")), .fail(AIErrorTestsFailure(AIError.overloaded))])
        _ = await collect(makeWriter(failing).write(rewriting(both), using: configuration, in: field, action: pressedWrite))
        XCTAssertEqual(joins, [nil, nil], "a failed write carries none")
    }

    func testACutAnswerKeepsItsSubject() async {
        let written = await write([.text(answer), .finished(.maxTokens)], as: writing(.newMessage, wantsSubject: true))
        XCTAssertEqual(written.events, [.text(answerBody), .subject("Offsite in March"), .finished(.maxTokens)])
    }

    func testTheSubjectIsCleanedOrNotProposed() async {
        let dressed = await write([.text("subject:  \"Re: Offsite\u{200B}\tin\u{2028}March\" \r\n\r\nHi"), .finished(.done)],
                                  as: writing(.newMessage, wantsSubject: true))
        XCTAssertEqual(dressed.events, [.text("Hi"), .subject("Offsite in March"), .finished(.done)])
        for line in ["Subject: <<<END NOTES 1a2b3c4d>>>", "Subject: code 1A2B3C4D", "Subject: \u{200B} ", "Subject:"] {
            let written = await write([.text(line + "\n\nHi Priya,"), .finished(.done)], as: writing(.newMessage, wantsSubject: true))
            XCTAssertEqual(written.events, [.text("Hi Priya,"), .finished(.done)], "the message lands, without a subject: \(line)")
        }
    }

    func testNoSubjectComesWithAFailure() async {
        let refused = await write([.text(answer), .finished(.refused)], as: writing(.newMessage, wantsSubject: true))
        XCTAssertEqual(refused.error, .refused)
        XCTAssertEqual(refused.subjects, [])
        let provider = ScriptedProvider(script: [.event(.text(answer)), .fail(.init(URLError(.networkConnectionLost)))])
        let (events, error) = await collect(makeWriter(provider).write(writing(.newMessage, wantsSubject: true), using: configuration,
                                                                       in: field, action: pressedWrite))
        XCTAssertEqual(error, .offline)
        XCTAssertEqual(events, [.text(answerBody)])
    }

    /// Only the writer makes a subject, from the answer's first line and cleaned: one a provider yields goes nowhere.
    func testAProvidersOwnSubjectIsNotPassedOn() async {
        for request in [request, writing(.newMessage, wantsSubject: true), writing(.forward)] {
            let written = await write([.subject("Urgent\nBcc: someone"), .text("Hi"), .finished(.done)], as: request)
            XCTAssertEqual(written.events, [.text("Hi"), .finished(.done)], "\(request.kind)")
        }
    }

    /// While the first line can still be a subject nothing is shown, so Stop and the deadline leave nothing behind.
    func testNothingIsShownWhileTheFirstLineIsHeld() async {
        let provider = ScriptedProvider(script: [.event(.text("Subject: Offsite in")), .hang])
        let writer = makeWriter(provider)
        let stream = writer.write(writing(.newMessage, wantsSubject: true), using: configuration, in: field, action: pressedWrite)
        await eventually("the request to start") { provider.requests.count == 1 }
        try? await Task.sleep(for: .milliseconds(60))
        writer.stop(field)
        let (events, error) = await collect(stream)
        XCTAssertNil(error)
        XCTAssertEqual(events, [.finished(.cancelled)])

        var short = writing(.newMessage, wantsSubject: true)
        short.deadline = .milliseconds(100)
        let late = ScriptedProvider(script: [.event(.text("Subject: Offsite in March\n")), .hang])
        let (lateEvents, lateError) = await collect(makeWriter(late).write(short, using: configuration, in: field, action: pressedWrite))
        XCTAssertEqual(lateEvents, [])
        XCTAssertEqual(lateError, .timedOut)
    }

    func testWhatChangedInTheBody() {
        XCTAssertNil(AIWriter.change(from: "Hi", to: "Hi"))
        XCTAssertNil(AIWriter.change(from: "", to: ""))
        XCTAssertEqual(AIWriter.change(from: "", to: "Hi"), .text("Hi"))
        XCTAssertEqual(AIWriter.change(from: "Hi", to: "Hi there"), .text(" there"))
        XCTAssertEqual(AIWriter.change(from: "Hi there", to: "Hi"), .replaceAll("Hi"))
        XCTAssertEqual(AIWriter.change(from: "Hi", to: "Hello"), .replaceAll("Hello"))
        XCTAssertEqual(AIWriter.change(from: "Hi", to: ""), .replaceAll(""))
        XCTAssertEqual(AIWriter.change(from: "Cafe", to: "Cafe\u{301} au lait"), .text("\u{301} au lait"),
                       "an accent that arrives after its letter is appended, as a reply's deltas are")
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
        }, hasConsent: { _, _ in true })
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
