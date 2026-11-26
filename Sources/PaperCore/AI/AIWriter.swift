import Foundation
import os

/// The service the UI calls for Help Me Write; the UI never calls a provider. Owned by `AppEnvironment`, one per window
/// graph. It resolves the configured provider, refuses without the permission given in Settings › AI for what is being
/// written, runs one write per field, enforces the deadline, takes a new message's subject line off its answer, turns
/// Stop into a clean end, and maps every failure to an `AIError`.
///
/// It reaches beyond this Mac only for an `AIUserAction` (spec §3b): `write` and `check` take one, `localHealth` needs
/// none because it looks at this Mac alone.
///
/// Reading the stream: zero or more `.text` / `.replaceAll` / `.usage`, at most one `.subject` (a new message whose
/// request asked for one) or `.join` (a rewrite in the DRAFT form whose seam lines passed), then exactly one `.finished(.done | .maxTokens | .cancelled)`, or one thrown `AIError`
/// (refusals, empty replies and timeouts included). `.finished(.cancelled)` comes only from `stop(_:)`, `stopAll()` and a
/// write asked for after `shutDown()`. Cancelling the consuming task also ends the write, silently.
///
/// Nothing is sent before `write` is called and the stream is iterated. Content is never logged: the log carries the
/// provider kind, the prompt version and character counts, at debug level.
@MainActor
public final class AIWriter {
    /// Builds the provider for a configuration: `AIProviderFactory.provider(for:)` in the app, the demo writer in demo
    /// mode and tests. Nil means it cannot be built here (`AIError.unavailable`).
    public typealias Resolve = @Sendable (AIProviderConfiguration) -> (any AIProvider)?
    /// Whether the user allowed this provider to be sent what this kind of write sends (AppSettings): permission is by
    /// what is written, since a new message and a forward send what the sheet people first agreed to never named.
    /// Checked again here, with the request's own kind, so no path can send without it.
    public typealias Consent = @MainActor (AIProviderKind, WriteKind) -> Bool
    /// Where milestones go: the app's crash-report breadcrumbs and analytics, with the field the write is in, so the app
    /// can tell its writes apart, and for a finished rewrite in the DRAFT form how the words beside it came out (nil for
    /// every other milestone and write), known here as the write ends rather than raced from the session's commit.
    public typealias Milestones = @MainActor (AIWriteMilestone, AIProviderKind, AIFieldID, WriteJoinOutcome?) -> Void

    private static let logger = Logger(subsystem: AppIdentity.bundleIdentifier, category: "ai")
    nonisolated private static let signposter = OSSignposter(subsystem: AppIdentity.bundleIdentifier, category: "ai")

    @MainActor private final class Run {
        // Main-actor state like the writer's own; only the gate is touched from the provider's task.
        let gate: AIStreamGate
        let kind: AIProviderKind
        let field: AIFieldID
        let signpost: OSSignpostIntervalState
        var task: Task<Void, Never>?

        init(gate: AIStreamGate, kind: AIProviderKind, field: AIFieldID, signpost: OSSignpostIntervalState) {
            self.gate = gate
            self.kind = kind
            self.field = field
            self.signpost = signpost
        }
    }

    private let resolve: Resolve
    private let hasConsent: Consent
    private let milestones: Milestones
    private var runs: [AIFieldID: Run] = [:]
    /// The checks under way (Settings' Check, a key saved with Return), so `shutDown()` can end them.
    private var checks: [UUID: Task<AIHealth, Never>] = [:]
    /// Set by `shutDown()`: the environment is going away, and no write or check starts after it.
    public private(set) var isShutDown = false

    public init(resolve: @escaping Resolve, hasConsent: @escaping Consent, milestones: @escaping Milestones = { _, _, _, _ in }) {
        self.resolve = resolve
        self.hasConsent = hasConsent
        self.milestones = milestones
    }

    /// Whether a write is running in `field`: ⌘J and Write are disabled while it is.
    public func isWriting(in field: AIFieldID) -> Bool {
        runs[field] != nil
    }

    /// Whether any write is running.
    public var isWriting: Bool { !runs.isEmpty }

    /// Starts a write into `field` for the user's `action`. Errors arrive through the stream, never thrown here: `busy`
    /// when the field is already writing, `consentRequired` before the user turned `configuration.kind` on in Settings ›
    /// AI for what `request` writes, `unavailable` when no provider can be built.
    public func write(_ request: AIWriteRequest, using configuration: AIProviderConfiguration, in field: AIFieldID,
                      action: AIUserAction) -> AsyncThrowingStream<AIWriteEvent, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: AIWriteEvent.self, throwing: Error.self)
        let gate = AIStreamGate(continuation)
        let kind = configuration.kind
        // A write asked for after the environment went away (one still building its context as the app quit) sends
        // nothing: it ends as a stop from outside would.
        guard !isShutDown else {
            gate.close(.finished(.cancelled))
            return stream
        }
        guard runs[field] == nil else {
            gate.close(.failed(.busy))
            return stream
        }
        // The demo writer sends nothing anywhere, so it needs no permission.
        guard kind == .demo || hasConsent(kind, request.kind) else {
            gate.close(.failed(.consentRequired))
            return stream
        }
        guard let provider = resolve(configuration) else {
            gate.close(.failed(.unavailable))
            return stream
        }

        let run = Run(gate: gate, kind: kind, field: field, signpost: Self.signposter.beginInterval("ai.write"))
        runs[field] = run
        Self.logger.debug("Write started: \(kind.rawValue, privacy: .public), prompt \(request.promptVersion, privacy: .public), \(request.transcript.count, privacy: .public)+\(request.task.count, privacy: .public) characters")
        milestones(.started, kind, field, nil)

        continuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { @MainActor [weak self] in self?.consumerLeft(run, field: field) }
        }
        // The task keeps the writer until the write's bookkeeping is done (at most the deadline), so a writer the
        // caller let go of still reports how its last write ended.
        run.task = Task.detached(priority: .userInitiated) {
            // Only a new message's full write may begin with a subject line, and only a rewrite that sent the draft
            // around its selection may end with seam lines; every other answer passes as it comes.
            let reader: Reader?
            if request.readsSubjectLine {
                reader = .subject(SubjectLine(isWanted: request.wantsSubject, fence: request.fence))
            } else if request.readsRewriteAnswer, let frame = request.rewrite {
                reader = .rewrite(frame, fence: request.fence)
            } else {
                reader = nil
            }
            let (ending, join) = await Self.relay(provider.write(request, action: action), deadline: request.deadline,
                                                  reader: reader, into: gate)
            let closedHere = gate.close(ending)
            await self.complete(run, field: field, ending: ending, join: join, closedHere: closedHere)
        }
        return stream
    }

    /// Stops the write in `field`: its stream yields `.finished(.cancelled)` and ends, the provider's request is
    /// cancelled (the process ends), and the field is free at once for a new write.
    public func stop(_ field: AIFieldID) {
        guard let run = runs.removeValue(forKey: field) else { return }
        run.task?.cancel()
        if run.gate.close(.finished(.cancelled)) {
            end(run, .stopped)
        }
    }

    /// Stops every write, as when the window graph goes away.
    public func stopAll() {
        for field in Array(runs.keys) { stop(field) }
    }

    /// Stops every write and check and refuses every later one: the environment is going away (quit, Leave Demo), and a
    /// write still on its way to `write` (its context being built) or a check must not start once its CLIs have been
    /// ended. Quitting is never a reason to reach a provider (spec §3b).
    public func shutDown() {
        isShutDown = true
        stopAll()
        for check in checks.values { check.cancel() }
        checks = [:]
    }

    /// The provider's health from this Mac alone (no network, no process): Settings › AI's status line as it opens and
    /// whether the reply's text shows Help me write's marks.
    public func localHealth(of configuration: AIProviderConfiguration) -> AIHealth {
        guard let provider = resolve(configuration) else {
            return .unavailable(reason: AIError.unavailable.message(for: configuration.kind))
        }
        return provider.localHealth()
    }

    /// Settings' Check button, or a key just saved: the provider's deeper check (an API key's authenticated GET, a CLI's
    /// version and sign-in), for the user's `action`.
    /// After `shutDown()` it answers from this Mac alone and sends nothing; `shutDown()` cancels one under way.
    public func check(_ configuration: AIProviderConfiguration, action: AIUserAction) async -> AIHealth {
        guard !isShutDown else { return localHealth(of: configuration) }
        guard let provider = resolve(configuration) else {
            return .unavailable(reason: AIError.unavailable.message(for: configuration.kind))
        }
        let id = UUID()
        let task = Task { await provider.check(action) }
        checks[id] = task
        defer { checks[id] = nil }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Whether a check is under way (tests).
    public var isChecking: Bool { !checks.isEmpty }

    // MARK: Running

    /// How a new message's answer is read for its first line (`WriteSubjectLine`).
    private struct SubjectLine: Sendable {
        /// The request asked for a subject: the line's words go on as `.subject`. Otherwise the line is only dropped.
        var isWanted: Bool
        var fence: String
    }

    /// How an answer is read before the reader gets it: for a new message's subject line, or for a rewrite's part and
    /// seam lines (`WriteRewriteAnswer`), against what the request sent.
    private enum Reader: Sendable {
        case subject(SubjectLine)
        case rewrite(WriteRewriteFrame, fence: String)
    }

    /// Copies the provider's events into `gate` until it finishes, fails, or the deadline passes, whichever is first.
    /// Losing the race cancels the provider's stream, which cancels its request.
    ///
    /// With a `reader`, the raw answer is kept (appended on `.text`, replaced on `.replaceAll`), read again each time
    /// more of it comes, and what changed in what the reader gets is passed on: for a new message's full write the
    /// message without its `Subject:` line, held back while the first line can still be one; for a rewrite in the DRAFT
    /// form the part without its seam lines, held back from a marker's first “<”. Without one, every event passes
    /// exactly as the provider sent it. The second value is how the words beside a rewritten selection came out, for a
    /// rewrite in the DRAFT form that finished; nil otherwise.
    nonisolated private static func relay(_ events: AsyncThrowingStream<AIWriteEvent, Error>, deadline: Duration,
                                          reader: Reader?, into gate: AIStreamGate) async -> (AIStreamGate.Ending, WriteJoinOutcome?) {
        do {
            return try await withThrowingTaskGroup(of: (AIStreamGate.Ending, WriteJoinOutcome?).self) { group in
                group.addTask {
                    var wroteSomething = false
                    /// The provider's whole answer so far, subject or seam lines included, and what the reader has of it.
                    var raw = ""
                    var shown = ""
                    /// Passes on what changed between what the reader has and `now`.
                    func show(_ now: String) {
                        if let change = Self.change(from: shown, to: now) { gate.yield(change) }
                        shown = now
                    }
                    /// Reads the answer so far, while it streams.
                    func read() {
                        switch reader {
                        case .subject?:
                            show(WriteSubjectLine.split(raw, final: false).body)
                        case .rewrite(_, let fence)?:
                            show(WriteRewriteAnswer.split(raw, final: false, fence: fence).part)
                        case nil:
                            break
                        }
                    }
                    /// The provider is done: what is still held is settled, and what goes with the draft (a subject, the
                    /// words beside a rewritten part) goes on just before the end, only with something written.
                    func end(_ stop: AIStop) -> (AIStreamGate.Ending, WriteJoinOutcome?) {
                        switch reader {
                        case nil:
                            return (Self.ending(for: stop, wroteSomething: wroteSomething), nil)
                        case .subject(let subject)?:
                            let split = WriteSubjectLine.split(raw, final: true)
                            show(split.body)
                            let result = Self.ending(for: stop, wroteSomething: split.body.contains { !$0.isWhitespace })
                            if case .finished = result, subject.isWanted,
                               let line = split.subject.flatMap({ WriteSubjectLine.cleaned($0, fence: subject.fence) }) {
                                gate.yield(.subject(line))
                            }
                            return (result, nil)
                        case .rewrite(let frame, let fence)?:
                            return endRewrite(stop, frame: frame, fence: fence)
                        }
                    }
                    /// A rewrite's answer, read whole: its part less what it restates of the draft, refused when it
                    /// copies the draft, then the seam lines that pass the checks.
                    func endRewrite(_ stop: AIStop, frame: WriteRewriteFrame, fence: String) -> (AIStreamGate.Ending, WriteJoinOutcome?) {
                        guard stop == .done || stop == .maxTokens else {
                            return (Self.ending(for: stop, wroteSomething: shown.contains { !$0.isWhitespace }), nil)
                        }
                        let signpost = Self.signposter.beginInterval("ai.rewriteRead")
                        let split = WriteRewriteAnswer.split(raw, final: true, fence: fence)
                        var part = split.part
                        if part.contains(where: { !$0.isWhitespace }) {
                            guard let stripped = WriteRewriteAnswer.stripEchoes(part, frame: frame),
                                  !WriteRewriteAnswer.repeatsDraft(stripped, frame: frame, instruction: frame.instruction) else {
                                Self.signposter.endInterval("ai.rewriteRead", signpost)
                                return (.failed(.rewriteRepeated), nil)
                            }
                            part = stripped
                        }
                        Self.signposter.endInterval("ai.rewriteRead", signpost)
                        show(part)
                        let result = Self.ending(for: stop, wroteSomething: part.contains { !$0.isWhitespace })
                        guard case .finished = result else { return (result, nil) }
                        let join = WriteJoin(before: split.before.flatMap { WriteJoin.accept($0, replacing: frame.before, fence: fence) },
                                             after: split.after.flatMap { WriteJoin.accept($0, replacing: frame.after, fence: fence) })
                        let outcome: WriteJoinOutcome
                        switch (join.before != nil, join.after != nil) {
                        case (true, true): outcome = .both
                        case (true, false): outcome = .before
                        case (false, true): outcome = .after
                        case (false, false): outcome = split.cameWithSeamLines ? .refused : .none
                        }
                        if join.before != nil || join.after != nil { gate.yield(.join(join)) }
                        return (result, outcome)
                    }
                    for try await event in events {
                        switch event {
                        case .text(let text):
                            guard !text.isEmpty else { continue }
                            if reader != nil {
                                raw += text
                                read()
                            } else {
                                if !wroteSomething { wroteSomething = text.contains { !$0.isWhitespace } }
                                gate.yield(event)
                            }
                        case .replaceAll(let text):
                            if reader != nil {
                                raw = text
                                read()
                            } else {
                                wroteSomething = text.contains { !$0.isWhitespace }
                                gate.yield(event)
                            }
                        case .usage:
                            gate.yield(event)
                        case .subject, .join:
                            // Only this writer makes them, from the answer itself: a provider's are not passed on.
                            continue
                        case .finished(let stop):
                            return end(stop)
                        }
                    }
                    try Task.checkCancellation()
                    // A stream that ends without saying so ended normally.
                    return end(.done)
                }
                group.addTask {
                    try await Task.sleep(for: deadline)
                    throw AIError.timedOut
                }
                guard let first = try await group.next() else { return (.failed(.cancelled), nil) }
                group.cancelAll()
                return first
            }
        } catch {
            return (.failed(AIError.from(error)), nil)
        }
    }

    /// What turns the body the reader has (`old`) into `new`: nothing when they are the same, the new end when the
    /// body only grew, the whole body otherwise (the provider replaced its text).
    nonisolated static func change(from old: String, to new: String) -> AIWriteEvent? {
        guard new != old else { return nil }
        // Compared as bytes: an accent that arrives after its letter is a new end too, and `String.hasPrefix`, which
        // compares whole characters, would not take the letter alone for the start of the two together.
        let had = old.utf8
        let has = new.utf8
        guard has.count > had.count, has.starts(with: had) else { return .replaceAll(new) }
        return .text(String(decoding: has.dropFirst(had.count), as: UTF8.self))
    }

    nonisolated private static func ending(for stop: AIStop, wroteSomething: Bool) -> AIStreamGate.Ending {
        switch stop {
        case .done, .maxTokens: return wroteSomething ? .finished(stop) : .failed(.emptyReply)
        case .refused: return .failed(.refused)
        case .cancelled: return .failed(.cancelled)
        }
    }

    private func complete(_ run: Run, field: AIFieldID, ending: AIStreamGate.Ending, join: WriteJoinOutcome?,
                          closedHere: Bool) {
        if runs[field] === run { runs[field] = nil }
        guard closedHere else { return }
        switch ending {
        case .finished:
            end(run, .finished, join: join)
        case .failed(let error):
            Self.logger.info("Write failed: \(run.kind.rawValue, privacy: .public), \(error.description, privacy: .public)")
            end(run, .failed)
        case .abandoned:
            end(run, .stopped)
        }
    }

    private func consumerLeft(_ run: Run, field: AIFieldID) {
        guard runs[field] === run else { return }
        runs[field] = nil
        run.task?.cancel()
        if run.gate.close(.abandoned) { end(run, .stopped) }
    }

    private func end(_ run: Run, _ milestone: AIWriteMilestone, join: WriteJoinOutcome? = nil) {
        Self.signposter.endInterval("ai.write", run.signpost)
        Self.logger.debug("Write ended: \(run.kind.rawValue, privacy: .public), \(String(describing: milestone), privacy: .public)")
        milestones(milestone, run.kind, run.field, join)
    }
}
